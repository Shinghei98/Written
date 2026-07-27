import SwiftUI

/// The distillation screen: a tree the user grows by connecting apps.
///
/// Each connected modality becomes a branch, and the branch's shape carries how
/// varied that part of their footprint is — see `TreeMetrics` and
/// `TreeSkeleton`. Connecting waters the tree and it redraws itself outward.
struct GrowProfileView: View {
    /// Owned by `HomeView`, not by this screen: the dashboard reads the same
    /// records, and the two have to be looking at one distillation.
    @ObservedObject var viewModel: DistillViewModel

    /// "View profile" — `HomeView` slides this screen away to the dashboard.
    var onViewProfile: () -> Void = {}

    @State private var growth: Double = 0
    @State private var isWatering = false
    @State private var hasDrawnOnce = false
    @State private var isPickingSource = false

    /// The tree currently on screen, which lags the view model's by one
    /// watering: the new shape must not appear until the can has poured, or the
    /// tree visibly grows before anything waters it.
    @State private var displayedSkeleton = TreeSkeleton.make(from: .empty, seed: DistillViewModel.treeSeed)
    @State private var treeOpacity: Double = 1

    /// How far up its climb the stem is, mirroring `SeedlingView`'s own value so
    /// the badge pinned to the leaves rises with them rather than jumping when
    /// the stage changes.
    @State private var leafLift: CGFloat = 0

    /// Set once, when the first pair of leaves has opened. The badge stays put
    /// after that — it moves with the leaves, but it doesn't re-enter.
    @State private var hasBadgeArrived = false

    /// The same per shoot, keyed by its id: each waits for its own last leaflet
    /// to finish opening.
    @State private var hasShootBadgeArrived: [Int: Bool] = [:]

    /// The source being distilled, captured when the work starts. Read from
    /// `nextModality` as it goes it would change to the *following* source the
    /// moment the records land, and the banner would rename itself while it was
    /// still fading out.
    @State private var distillingModality: Modality?
    @State private var distillProgress: Double = 0
    @State private var progressWalk: Task<Void, Never>?

    /// How the head moves along the bar: one pace between dots, and a wait on
    /// the dot it reaches.
    private static let progressStep: Double = 1.0
    private static let progressDwell: Double = 0.45

    /// Height held for the bars at the foot of the screen, filled or not.
    ///
    /// The tallest the stack gets is every modality but the last connected —
    /// two slim bars at 44 and the 76pt invitation — plus "View profile", which
    /// is there at every stage, and the gaps. Reserving it is what keeps the
    /// garden the same size from the first stage to the last.
    private static let promptsReserve: CGFloat = 44 * 2 + 76 + 48 + 8 * 3

    /// The banner and the watering can share a lifetime: both are the cover for
    /// the wait, so they arrive and leave together.
    private var isCovering: Bool { isWatering }

    var body: some View {
        ZStack {
            GardenPalette.parchment.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Spacer(minLength: 8)
                garden
                Spacer(minLength: 8)
                prompts
                    // Room for the tallest the stack ever gets — two connected
                    // bars and an invitation — held whether or not it is filled.
                    //
                    // The garden takes what is left, so without this the space
                    // below it shrinks with every bar added, the square shrinks
                    // to fit, and the plant slides and scales as the user
                    // connects. It should stand still and only grow.
                    .frame(minHeight: Self.promptsReserve, alignment: .bottom)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
        }
        .preferredColorScheme(.light)
        // Fires once on appear, then again whenever a distillation changes the
        // shape of the tree.
        .task(id: viewModel.treeState) {
            await growTree()
        }
        // The can goes on the moment the user connects, not when the records
        // come back, so it covers the whole wait — OAuth sheet included.
        .onChange(of: viewModel.isDistilling) { running in
            if running {
                distillingModality = viewModel.treeState.nextModality
                isWatering = true
                distillProgress = 0
                progressWalk?.cancel()
                // Nothing reports real progress — the distillers are one opaque
                // await each — so the head walks dot to dot at one pace and
                // then holds, rather than easing asymptotically toward the end.
                // Creeping implies knowledge of how far along the work is;
                // stopping on a dot says only "still going", which is true. The
                // last stretch is kept for the work actually finishing.
                progressWalk = Task {
                    for stop in 1...(StepProgressBar.stops - 2) {
                        try? await Task.sleep(nanoseconds: UInt64(Self.progressDwell * 1_000_000_000))
                        if Task.isCancelled { return }
                        withAnimation(.linear(duration: Self.progressStep)) {
                            distillProgress = Double(stop) / Double(StepProgressBar.stops - 1)
                        }
                        try? await Task.sleep(nanoseconds: UInt64(Self.progressStep * 1_000_000_000))
                        if Task.isCancelled { return }
                    }
                }
            } else {
                progressWalk?.cancel()
                // The same pace to the end, so the last stretch doesn't read as
                // a different bar.
                withAnimation(.linear(duration: Self.progressStep * 0.8)) { distillProgress = 1 }
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(WateringCanOverlay.exitDuration * 1_000_000_000))
                    isWatering = false
                    // Held until the cross-fade has finished, or the banner
                    // loses its title on the way out.
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    distillingModality = nil
                    distillProgress = 0
                }
            }
        }
        .sheet(isPresented: $isPickingSource) {
            SourcePickerSheet(
                modality: viewModel.treeState.nextModality ?? .music,
                viewModel: viewModel,
                onClose: { isPickingSource = false }
            )
            .presentationDetents([.height(280)])
        }
        .fileExporter(
            isPresented: $viewModel.isExporterPresented,
            document: viewModel.exportDocument,
            contentType: .commaSeparatedText,
            defaultFilename: CSVExporter.suggestedFilename()
        ) { result in
            viewModel.handleExportResult(result)
        }
    }

    // MARK: - Sections

    /// The headline block, and the banner that stands in for it while a source
    /// is being distilled. Cross-faded rather than swapped: the two say the
    /// same thing about the same screen, and a hard cut reads as navigation.
    private var header: some View {
        ZStack(alignment: .topLeading) {
            titleBlock
                .opacity(isCovering ? 0 : 1)

            if let modality = distillingModality {
                DistillingBanner(modality: modality, progress: distillProgress)
                    .opacity(isCovering ? 1 : 0)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: isCovering)
        .overlay(alignment: .topTrailing) {
            // Out with the title: the banner is centred across the full width
            // and would otherwise read through them.
            headerButtons
                .opacity(isCovering ? 0 : 1)
                .allowsHitTesting(!isCovering)
                .animation(.easeInOut(duration: 0.35), value: isCovering)
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Grow your profile")
                .font(BrandFont.title(46))
                .foregroundStyle(GardenPalette.ink)
                .lineSpacing(-2)
                .fixedSize(horizontal: false, vertical: true)
                // Room for the buttons sitting over the top-right corner.
                .padding(.trailing, 96)

            // Held to a narrower column than the headline so it breaks after
            // "into", the way the template does.
            Text("Every connection nourishes it into something unique about you")
                .font(.system(size: 16))
                .foregroundStyle(GardenPalette.muted)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 268, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headerButtons: some View {
        HStack(spacing: 0) {
#if DEBUG
            // TEMPORARY — debug builds only. Steps the plant through its
            // stages so the growing animation can be tested without an
            // account: bare soil, shoot, then each generated branch, then
            // back to bare soil. Delete this along with
            // `advancePreviewStage()` when it has served its purpose.
            Button(action: viewModel.advancePreviewStage) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                    Text("\(viewModel.treeState.branches.count)/\(DistillViewModel.previewStages)")
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                }
                .foregroundStyle(GardenPalette.gold)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .overlay {
                    Capsule().strokeBorder(GardenPalette.gold.opacity(0.4), lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Advance growth stage")
#endif

            // The CSV export the distillation pipeline still depends on,
            // kept out of the way rather than removed.
            Button(action: viewModel.prepareExport) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(viewModel.hasRecords ? GardenPalette.muted : GardenPalette.muted.opacity(0.35))
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.hasRecords)
            .accessibilityLabel("Export distilled records")
        }
    }

    private var garden: some View {
        ZStack {
            TreeView(skeleton: displayedSkeleton, growth: growth)
                .opacity(treeOpacity)

            GeometryReader { geometry in
                // Clear of the badge, which now sits at ~0.83 × 0.36 beside the
                // right-hand leaf.
                SparkleView(size: 13, delay: 0.0)
                    .position(x: geometry.size.width * 0.87, y: geometry.size.height * 0.14)
                SparkleView(size: 9, delay: 1.2)
                    .position(x: geometry.size.width * 0.12, y: geometry.size.height * 0.44)

                // Pinned to the right-hand leaf rather than to the screen, so
                // it keeps its place against the plant as the stem lifts them.
                // One badge per part of the plant, each keeping its own icon:
                // music belongs to the pair of leaves it grew, so it stays a
                // music note once connected rather than turning into whatever
                // is offered next.
                if displayedSkeleton.illustrated != nil {
                    ModalityBadge(modality: .music)
                        .position(cotyledonBadge(in: CGRect(origin: .zero, size: geometry.size)))
                        // Arrives once the plant has finished opening, not with
                        // it: the seedling is the thing to look at first, and
                        // the badge is an invitation to what comes next.
                        .scaleEffect(hasBadgeArrived ? 1 : 0.72)
                        .opacity(hasBadgeArrived ? 1 : 0)
                }

                // One per shoot, in the order the modalities unlock — each
                // beside the growth it belongs to, and only once that shoot has
                // finished unfolding.
                if let stage = displayedSkeleton.illustrated {
                    ForEach(SeedlingArt.shoots(by: stage.extended)) { shoot in
                        if let modality = shootModality(shoot) {
                            ModalityBadge(modality: modality)
                                .position(shootBadge(shoot, in: CGRect(origin: .zero, size: geometry.size)))
                                .scaleEffect(hasShootBadgeArrived[shoot.id] == true ? 1 : 0.72)
                                .opacity(hasShootBadgeArrived[shoot.id] == true ? 1 : 0)
                        }
                    }
                }
            }

            if isWatering {
                WateringCanOverlay(isRunning: viewModel.isDistilling)
            }
        }
        // Square, so the tree keeps its proportions and the badge and sparkles
        // stay where they were placed relative to it. Left to fill a tall frame
        // it would sink to the bottom with a hole above it.
        //
        // Not made taller to give the later stages room, either: `.fit` honours
        // the ratio by *shrinking* when the vertical space is short, and the
        // whole plant came out smaller. The crown grows into the gap between
        // the illustration's canvas and the top of this square instead —
        // nothing clips it, since the drawing is bottom-aligned.
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity)
    }

    /// The bars at the foot of the screen: one for every source already
    /// connected, and the invitation to the next one underneath them.
    ///
    /// They stack rather than replace each other. Connecting pushes the finished
    /// bar up and slides the next one in from below, so the screen keeps a
    /// record of what the plant was grown from instead of forgetting each step
    /// as it completes.
    private var prompts: some View {
        VStack(spacing: 8) {
            ForEach(viewModel.treeState.connectedModalities) { modality in
                ConnectedBar(modality: modality, sources: viewModel.connectedSources(for: modality))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let next = viewModel.treeState.nextModality {
                promptCard(for: next)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(next)
            }

            viewProfile
        }
        .animation(.spring(response: 0.6, dampingFraction: 0.85), value: viewModel.treeState)
    }

    /// The way out of the growing screen, under the bars.
    ///
    /// Shown from the start and dimmed, not hidden until it works: it says what
    /// the connecting is *for*, and a button that appears out of nowhere on the
    /// first connection would push the whole stack — and with it the plant — as
    /// it arrived. It comes alive once the first app has been connected, since
    /// until then there is no distillation for a profile to be built from.
    private var viewProfile: some View {
        let isReady = !viewModel.treeState.connectedModalities.isEmpty

        return Button(action: onViewProfile) {
            Text("View profile")
        }
        // Sized to its label rather than filling the row: the bars above are
        // the screen's business and this is the way out of it, so it reads as
        // a lighter thing than they are.
        .buttonStyle(
            PressShrinkButtonStyle(
                fill: GardenPalette.card,
                foreground: GardenPalette.ink,
                border: GardenPalette.gold.opacity(isReady ? 0.35 : 0.15),
                expands: false,
                font: .system(size: 16, weight: .semibold),
                horizontalPadding: 26,
                minHeight: 48
            )
        )
        // The style doesn't dim on its own, so `disabled` alone would leave a
        // button that looks live and does nothing — same reasoning as the
        // unavailable modality's button above.
        .opacity(isReady ? 1 : 0.45)
        .disabled(!isReady)
    }

    private func promptCard(for next: Modality) -> some View {
        let first = viewModel.treeState.isSeedling

        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(first ? "Ready to grow?" : "Ready for more?")
                    .lineLimit(1)
                    // Beside a button as wide as "Connect Lifestyle" the line
                    // can still run out of bar; shrink rather than truncate, or
                    // the question mark is the first thing to go.
                    .minimumScaleFactor(0.75)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(GardenPalette.ink)

                // One `Text`, not two in a stack: `minimumScaleFactor` applies
                // per view, so a stack shrinks each half on its own and drops
                // words out of the first — "Continue… Lifestyle." — instead of
                // scaling the line. Concatenated, it scales as one and keeps
                // the modality's name in gold.
                (
                    Text(first ? "Start with " : "Continue with ")
                        .foregroundColor(GardenPalette.muted)
                    + Text(next.label + ".")
                        .foregroundColor(GardenPalette.gold)
                )
                .font(.system(size: 15))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
            .layoutPriority(1)

            Spacer(minLength: 0)

            Button(action: { connect(next) }) {
                HStack(spacing: 8) {
                    if viewModel.isDistilling {
                        ProgressView()
                            .tint(GardenPalette.card)
                    } else {
                        Image(systemName: next.systemImage)
                            .font(.system(size: 15))
                    }
                    Text("Connect \(next.label)")
                        .lineLimit(1)
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(
                PressShrinkButtonStyle(
                    fill: GardenPalette.gold,
                    foreground: GardenPalette.card,
                    expands: false,
                    font: .system(size: 15, weight: .semibold),
                    horizontalPadding: 14,
                    minHeight: 48
                )
            )
            // Nothing reads Apple Health yet, so its bar takes its turn with the
            // button dimmed rather than the flow ending a step early. The style
            // doesn't dim on its own, so `disabled` alone would leave a button
            // that looks live and does nothing.
            .opacity(next.isAvailable ? 1 : 0.5)
            .disabled(viewModel.isDistilling || !next.isAvailable)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(GardenPalette.card, in: RoundedRectangle(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(GardenPalette.ink.opacity(0.06), lineWidth: 1)
        }
    }

    /// Beside the tip of the right-hand cotyledon, offset out and a little down
    /// so the badge clears the blade instead of sitting on it. The generated
    /// tree has no cotyledons, so it keeps the old fixed spot.
    private func cotyledonBadge(in rect: CGRect) -> CGPoint {
        guard displayedSkeleton.illustrated != nil else {
            return CGPoint(x: rect.width * 0.74, y: rect.height * 0.58)
        }
        let tip = SeedlingArt.cotyledonTip(mirrored: true, extended: leafLift)
        return TreeGeometry.illustration(
            CGPoint(x: tip.x + 0.074, y: tip.y + 0.082),
            in: rect
        )
    }

    /// Just outside a shoot's cluster, level with it and on the shoot's own
    /// side of the stem.
    private func shootBadge(_ shoot: SeedlingArt.Shoot, in rect: CGRect) -> CGPoint {
        let extent = SeedlingArt.shootExtent(of: shoot, extended: leafLift)
        let outward: CGFloat = shoot.reach.width < 0 ? -0.082 : 0.082
        return TreeGeometry.illustration(
            CGPoint(x: extent.x + outward, y: extent.y + 0.010),
            in: rect
        )
    }

    /// The source a shoot stands for: the cotyledons are music, so the shoots
    /// carry the ones after it, in the order they unlock. A shoot with nothing
    /// left to offer carries nothing.
    private func shootModality(_ shoot: SeedlingArt.Shoot) -> Modality? {
        let all = Modality.allCases
        let index = shoot.id + 1
        return index < all.count ? all[index] : nil
    }

    // MARK: - Behaviour

    private func connect(_ modality: Modality) {
        // Music has two possible apps, so it asks; anything with a single source
        // just goes.
        if modality.sources.count > 1 {
            isPickingSource = true
        } else if let source = modality.sources.first {
            viewModel.distill(source: source)
        }
    }

    private func growTree() async {
        let next = viewModel.skeleton
        // Between illustrated stages the plant grows in place — `SeedlingView`
        // lengthens the stem and unfolds the shoot off the drawing that is
        // already on screen. Dissolving it first would throw away the one thing
        // that makes it read as *their* plant growing.
        let growsInPlace = displayedSkeleton.illustrated != nil && next.illustrated != nil

        if hasDrawnOnce {
            // The old plant stays put while the can pours over it. The records
            // land a moment before the distillation is marked finished, so wait
            // that out rather than letting the plant change under the can.
            while viewModel.isDistilling {
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
            try? await Task.sleep(nanoseconds: UInt64(WateringCanOverlay.exitDuration * 1_000_000_000))
        }
        if hasDrawnOnce && !growsInPlace {
            // Dissolve the old shape under the last of the drops rather than
            // letting it vanish between frames.
            withAnimation(.easeIn(duration: 0.28)) { treeOpacity = 0 }
            try? await Task.sleep(nanoseconds: 280_000_000)
        }
        hasDrawnOnce = true

        displayedSkeleton = next
        treeOpacity = 1

        if !hasBadgeArrived {
            Task {
                try? await Task.sleep(nanoseconds: UInt64(SeedlingView.leavesOpenAt * 1_000_000_000))
                withAnimation(.spring(response: 0.55, dampingFraction: 0.66)) {
                    hasBadgeArrived = true
                }
            }
        }
        if let stage = next.illustrated {
            // Shoots this stage doesn't have yet forget they ever arrived, or
            // stepping back and forward again pops their badges straight in.
            let grown = Set(SeedlingArt.shoots(by: stage.extended).map(\.id))
            hasShootBadgeArrived = hasShootBadgeArrived.filter { grown.contains($0.key) }

            for shoot in SeedlingArt.shoots(by: stage.extended) where hasShootBadgeArrived[shoot.id] != true {
                // Only the shoot grown by *this* stage waits; older ones are
                // already open, so their badges come straight in.
                let wait = shoot.stage == stage ? SeedlingView.shootOpenAt(shoot) : 0
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    withAnimation(.spring(response: 0.55, dampingFraction: 0.66)) {
                        hasShootBadgeArrived[shoot.id] = true
                    }
                }
            }
        }
        // In step with the stem: `SeedlingView` starts its climb the moment the
        // stage reaches it, and the badge is hung off the leaf it lifts.
        let lift = next.illustrated?.extended ?? 1
        if growsInPlace {
            withAnimation(SeedlingView.extensionAnimation) { leafLift = lift }
        } else {
            leafLift = lift
        }
        guard !growsInPlace else {
            // `growth` drives the generated tree's outward draw, which this
            // stage doesn't use; resetting it would blank the next one's first
            // frame if the user connects again.
            growth = 1
            return
        }

        growth = 0
        withAnimation(.easeOut(duration: 1.8)) { growth = 1 }
    }
}

/// The mark of a connected app, in the app's own colours.
///
/// Drawn rather than shipped as artwork: there are no brand assets in the
/// bundle, and at this size a few arcs and a triangle read as the logo. If the
/// real marks are ever added, this is the one place that changes.
struct AppMark: View {
    let source: String
    var diameter: CGFloat = 26

    var body: some View {
        switch source {
        case "spotify": spotify
        case "youtube": youtube
        case "apple_music": appleMusic
        default: unknown
        }
    }

    private var spotify: some View {
        ZStack {
            Circle().fill(Color(red: 0.114, green: 0.725, blue: 0.329))
            // The three waves, widest at the top.
            ForEach(0..<3, id: \.self) { ring in
                SpotifyWave(ring: ring)
                    .stroke(.white, style: StrokeStyle(lineWidth: diameter * 0.075, lineCap: .round))
            }
        }
        .frame(width: diameter, height: diameter)
    }

    private var youtube: some View {
        ZStack {
            RoundedRectangle(cornerRadius: diameter * 0.28)
                .fill(Color(red: 1.0, green: 0.0, blue: 0.0))
                .frame(width: diameter, height: diameter * 0.72)
            PlayTriangle()
                .fill(.white)
                .frame(width: diameter * 0.22, height: diameter * 0.26)
        }
        .frame(width: diameter, height: diameter)
    }

    private var appleMusic: some View {
        ZStack {
            RoundedRectangle(cornerRadius: diameter * 0.26)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.98, green: 0.31, blue: 0.45), Color(red: 0.98, green: 0.14, blue: 0.24)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            Image(systemName: "music.note")
                .font(.system(size: diameter * 0.48, weight: .medium))
                .foregroundStyle(.white)
        }
        .frame(width: diameter, height: diameter)
    }

    private var unknown: some View {
        Circle()
            .fill(GardenPalette.gold.opacity(0.12))
            .frame(width: diameter, height: diameter)
    }
}

/// One of Spotify's three arcs.
private struct SpotifyWave: Shape {
    let ring: Int

    func path(in rect: CGRect) -> Path {
        let d = min(rect.width, rect.height)
        // Struck from below the middle so the arcs bulge upward, tightening as
        // they rise — which is the shape of the mark.
        let centre = CGPoint(x: rect.midX, y: rect.midY + d * 0.30)
        let radius = d * (0.46 - CGFloat(ring) * 0.13)
        let spread: Double = 46 - Double(ring) * 4

        var path = Path()
        path.addArc(
            center: centre,
            radius: radius,
            startAngle: .degrees(180 + spread),
            endAngle: .degrees(360 - spread),
            clockwise: false
        )
        return path
    }
}

private struct PlayTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// A branch already grown: what it was grown from, and the apps that fed it.
///
/// Slimmer than the prompt bar it replaces — it is a record, not an invitation,
/// and several of them stack up as the plant fills out.
struct ConnectedBar: View {
    let modality: Modality
    /// The apps of this modality that actually returned records. Both of music's
    /// can be connected, and then both marks show.
    let sources: [String]

    var body: some View {
        HStack(spacing: 10) {
            Text("Connected to \(modality.label)")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(GardenPalette.ink)
                .lineLimit(1)

            HStack(spacing: 6) {
                ForEach(sources, id: \.self) { source in
                    AppMark(source: source)
                        .accessibilityLabel(Modality.displayName(forSource: source))
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(GardenPalette.gold)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(GardenPalette.card.opacity(0.7), in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(GardenPalette.gold.opacity(0.22), lineWidth: 1)
        }
    }
}

/// Stands in for the headline while a source is being distilled: what is
/// happening, said twice — once in the app's terms and once in the plant's —
/// and how far along it is.
struct DistillingBanner: View {
    let modality: Modality
    let progress: Double

    var body: some View {
        VStack(spacing: 8) {
            Text("Distilling \(modality.label)…")
                .font(BrandFont.title(30))
                .foregroundStyle(GardenPalette.ink)

            Text("Watering with \(modality.label)")
                .font(.system(size: 15))
                .foregroundStyle(GardenPalette.muted)

            StepProgressBar(progress: progress)
                .frame(width: 196, height: 12)
                .padding(.top, 6)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
    }
}

/// A line with stops along it and a knob at the head, as in the reference.
private struct StepProgressBar: View {
    let progress: Double
    /// Dots along the track. The head walks between them at one pace, so this
    /// is also how the wait is paced — see `GrowProfileView`.
    static let stops = 4
    private var steps: Int { Self.stops }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let middle = geometry.size.height / 2
            let head = min(max(progress, 0), 1) * width

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(GardenPalette.ink.opacity(0.12))
                    .frame(height: 2)

                Capsule()
                    .fill(GardenPalette.ink)
                    .frame(width: head, height: 2)

                ForEach(0..<steps, id: \.self) { step in
                    let at = width * CGFloat(step) / CGFloat(steps - 1)
                    Circle()
                        .fill(at <= head + 0.5 ? GardenPalette.ink : GardenPalette.ink.opacity(0.16))
                        .frame(width: 5, height: 5)
                        .position(x: at, y: middle)
                }

                Circle()
                    .fill(GardenPalette.ink)
                    .frame(width: 9, height: 9)
                    .position(x: head, y: middle)
            }
        }
    }
}

/// The floating badge beside the shoot: the branch on offer next.
struct ModalityBadge: View {
    let modality: Modality

    /// One size for every badge, whichever part of the plant it marks. They are
    /// a set — a row of sources the user is working through — and sizing each
    /// to the leaf beside it made them read as a hierarchy instead.
    private let diameter: CGFloat = 48

    @State private var isRaised = false

    var body: some View {
        Image(systemName: modality.systemImage)
            .font(.system(size: diameter * 0.32))
            .foregroundStyle(GardenPalette.gold)
            .frame(width: diameter, height: diameter)
            .background(GardenPalette.gold.opacity(0.07), in: Circle())
            .overlay {
                Circle().strokeBorder(GardenPalette.gold.opacity(0.35), lineWidth: 1)
            }
            .offset(y: isRaised ? -6 : 6)
            .onAppear {
                withAnimation(.easeInOut(duration: 2.6).repeatForever()) { isRaised = true }
            }
    }
}

/// Which app should feed this branch. Only shown for modalities with more than
/// one possible source — music today.
struct SourcePickerSheet: View {
    let modality: Modality
    @ObservedObject var viewModel: DistillViewModel
    var onClose: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            Text("Connect \(modality.label)")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(GardenPalette.ink)
                .padding(.top, 22)
                .padding(.bottom, 4)

            Text("Either one grows the branch. Both grow it further.")
                .font(.system(size: 14))
                .foregroundStyle(GardenPalette.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.bottom, 18)

            ForEach(modality.sources, id: \.self) { source in
                Button {
                    viewModel.distill(source: source)
                    onClose()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: source == "spotify" ? "waveform" : "music.note")
                            .font(.system(size: 17))
                            .foregroundStyle(GardenPalette.gold)
                            .frame(width: 28)

                        Text(Modality.displayName(forSource: source))
                            .font(.system(size: 17))
                            .foregroundStyle(GardenPalette.ink)

                        Spacer()

                        if case .done(let count) = viewModel.status(for: source) {
                            Text("\(count)")
                                .font(.system(size: 14))
                                .foregroundStyle(GardenPalette.muted)
                        }

                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(GardenPalette.muted)
                    }
                    .padding(.horizontal, 22)
                    .frame(height: 56)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Divider().padding(.leading, 62)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GardenPalette.parchment)
        .preferredColorScheme(.light)
    }
}

#Preview {
    GrowProfileView(viewModel: DistillViewModel())
}
