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

    @Environment(\.scenePhase) private var scenePhase

    /// Back to sign-in. Only the debug button in the header calls it today.

    @State private var growth: Double = 0
    @State private var isWatering = false
    @State private var hasDrawnOnce = false
    /// Which modality the source picker is open for, `nil` when it is closed.
    ///
    /// One piece of state rather than a boolean beside a modality: setting both
    /// together raced the sheet's own content capture, so `-pick media` opened
    /// on music. `.sheet(item:)` reads the modality *from* the thing that
    /// presents it, and cannot disagree with itself.
    @State private var pickedModality: Modality?

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
    /// Reserving it is what keeps the garden the same size from the first stage
    /// to the last.
    ///
    /// Derived from the number of modalities rather than written out, because
    /// it went stale the moment a fourth was added: at `44 * 2` it held room for
    /// two bars, a fourth overflowed it, and the garden gave up the difference —
    /// the plant scaling down and sliding as the user connected, which is
    /// exactly what this constant exists to prevent.
    ///
    /// The tallest the stack ever gets is one short of every bar plus the
    /// invitation to the last one, plus the Dashboard button: all four connected
    /// is *shorter*, since the invitation is gone by then.
    private static let promptsReserve: CGFloat = 44 * 2 + 76 + 48 + 8 * 3

    /// The height the bars are allowed, whatever the count.
    ///
    /// Two bars and the gap between them, which is exactly what `promptsReserve`
    /// budgeted before a fourth modality existed — so the garden keeps the size
    /// and position it has always had, and a new source can never push it.
    ///
    /// Deriving the reserve from the modality count instead, as an earlier pass
    /// did, holds the plant still *relative to itself* but moves it from where
    /// it was: every stage loses the same 52 points, including the ones drawn
    /// long before any of this. The bars are what should give, not the plant.
    private static let barRow: CGFloat = 44 + 8

    /// How far the stack is allowed to *draw* above the reserve.
    ///
    /// The reserve is a layout figure and has to stay where it is or the garden
    /// changes size — that is the whole point of the constant above. But it was
    /// also acting as the visible height, so the stack faded out 96 points off
    /// its own bottom and left a band of empty parchment between the last bar
    /// and the soil. With three sources connected the first bar had gone
    /// entirely, well before it was anywhere near the plant.
    ///
    /// One more row's pitch. Drawn, not reserved: the outer frame is still
    /// `promptsReserve`, so this cannot move the garden or shrink the plant.
    /// That is the trade this height was chosen under — the rows were given the
    /// empty parchment above them and nothing else, rather than the plant being
    /// shrunk to fit more of them.
    private static let promptsOverdraw: CGFloat = barRow

    /// The fade at the top of the stack, in points rather than as a fraction of
    /// the window — a fraction would have grown with the overdraw and turned a
    /// soft edge into a long dissolve over half the visible rows.
    private static let barsFade: CGFloat = 26

    /// Where a refused permission is actually turned back on, per source.
    ///
    /// `x-apple-health://` is a public scheme and opens the Health app, which
    /// owns the read toggles under Profile › Apps › Written. It is not an exact
    /// deep link — nothing sanctioned is — but it lands in the app that holds
    /// the switch, which Settings › Written does not. The `prefs:root=` URLs
    /// that would land exactly are private API and a documented rejection
    /// reason, so they are not an option.
    ///
    /// Falls back to Settings if Health cannot be opened, which is what happens
    /// on an iPad or anywhere Health is not installed.
    private static func openPermissions(for modality: Modality) -> () -> Void {
        {
            let health = URL(string: "x-apple-health://")
            if modality.opensHealthApp, let health, UIApplication.shared.canOpenURL(health) {
                UIApplication.shared.open(health)
                return
            }
            if let settings = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(settings)
            }
        }
    }

    /// Bumped when the app comes back to the front, so a permission changed
    /// while it was away is re-read. See `promptCard`.
    @State private var permissionTick = 0

    /// What the stack is drawn and scrolled inside, once the arrow's strip and
    /// the tab bar's clearance are taken out.
    private static let promptsDrawn: CGFloat =
        promptsReserve - MainTabBar.overlayHeight + promptsOverdraw

    /// The banner and the watering can share a lifetime: both are the cover for
    /// the wait, so they arrive and leave together.
    private var isCovering: Bool { isWatering }

    var body: some View {
        // No full-screen background of its own. What is underneath this page is
        // the dashboard — `HomeView` mounts it below in the same stack — so
        // anything filling the screen here would cover the very thing the drag
        // is uncovering. The page's own `PageShape` is the only fill.
        ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                header
                Spacer(minLength: 8)
                garden
                Spacer(minLength: 8)
                prompts
                    // Room for the tallest the stack ever gets, held whether or
                    // not it is filled.
                    //
                    // The garden takes what is left, so without this the space
                    // below it shrinks with every bar added, the square shrinks
                    // to fit, and the plant slides and scales as the user
                    // connects. It should stand still and only grow.
                    // A fixed height, not a minimum. With `minHeight` the stack
                    // could still outgrow the reserve — and did, by 4 points at
                    // one stage, which moved the plant. Capping the bars means
                    // the content can never exceed this, so the garden's size is
                    // now the same by construction rather than by arithmetic
                    // that has to be redone every time a modality is added.
                    .frame(
                        height: Self.promptsReserve - MainTabBar.overlayHeight,
                        alignment: .bottom
                    )
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    // The tab bar floats over this strip. Taken *out* of the
                    // reserve above rather than added under it, so the heights
                    // still sum to what they always did and the plant does not
                    // move.
                    //
                    // The arrow that used to sit here is gone with the pull-up:
                    // the dashboard is a tab now, so there is nothing under this
                    // page to advertise. Its 28 points go back to the rows.
                    Color.clear.frame(height: MainTabBar.overlayHeight)
                }
                // Plain parchment now. The rounded edge and shadow were there
                // to make this read as a sheet lying over the dashboard, and
                // with the pull-up gone there is nothing underneath for it to
                // be a sheet over.
                .background(GardenPalette.parchment.ignoresSafeArea(edges: .bottom))
            }
        .preferredColorScheme(.light)
        // Coming back from Settings or Health with a permission just granted.
        // The status is read synchronously while building the card and nothing
        // publishes a change, so without this the warning outlives the problem.
        .onChange(of: scenePhase) { phase in
            guard phase == .active else { return }
            permissionTick += 1
        }
        // Fires once on appear, then again whenever a distillation changes the
        // shape of the tree.
        .task(id: viewModel.treeState) {
            await growTree()
        }
#if DEBUG
        // `-distill 1` / `-connect <source>` on the launch line; see `DebugLaunch`.
        .onAppear {
            let delay = UInt64(DebugLaunch.distillDelay * 1_000_000_000)
            if DebugLaunch.playsDistillation, DebugLaunch.firesOnce("distill") {
                Task {
                    try? await Task.sleep(nanoseconds: delay)
                    viewModel.advancePreviewStage()
                }
            }
            if let source = DebugLaunch.connectSource, DebugLaunch.firesOnce("connect") {
                Task {
                    try? await Task.sleep(nanoseconds: delay)
                    viewModel.distill(source: source)
                }
            }
            if let modality = DebugLaunch.pickTarget, DebugLaunch.firesOnce("pick") {
                Task {
                    try? await Task.sleep(nanoseconds: delay)
                    pickedModality = modality
                }
            }
        }
#endif
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
        .sheet(item: $pickedModality) { modality in
            // Built once so the detent and the content agree on how many rows
            // there are — asking the sheet for 280pt regardless left a
            // single-app modality in a half-empty card.
            let sheet = SourcePickerSheet(
                modality: modality,
                viewModel: viewModel,
                onClose: { pickedModality = nil }
            )
            sheet.presentationDetents([.height(sheet.detentHeight)])
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
        // Two rows, not one: a third control in the top row runs into "Grow
        // your", and widening the headline's trailing inset to clear it breaks
        // the title onto three lines. The second row sits beside "profile",
        // which is short.
        // The debug "Sign in" button that used to sit here is gone: sign-out is
        // a real feature now, on the dashboard. Two exits clearing different
        // amounts of state is how they drift, and this one cleared only the
        // session — leaving the previous account's OAuth connections behind.
        VStack(alignment: .trailing, spacing: 8) {
            topButtons
        }
    }

    private var topButtons: some View {
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
                    ModalityBadge(modality: .music, progress: badgeProgress(.music))
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
                            ModalityBadge(modality: modality, progress: badgeProgress(modality))
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
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
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

                    // Something to scroll *to*. Anchoring on the last real row
                    // would follow whichever view that happens to be, and it
                    // changes as sources connect.
                    Color.clear.frame(height: 1).id(Self.promptsFoot)
                }
                .frame(maxWidth: .infinity)
                // A short stack sits at the bottom of the viewport rather than
                // the top, so the invitation and the Dashboard button stay put
                // and the rows fill upward into the space above them — which is
                // where they were before any of this scrolled.
                .frame(minHeight: Self.promptsDrawn, alignment: .bottom)
            }
            // Drawn over the taller window and faded at its top, then handed to
            // the layout at the reserve. Two frames, in that order: the scroll
            // view clips to the first, so it overhangs the reserve upward and
            // the garden below is still measured against a height that has not
            // changed. This is what buys the extra rows without the plant
            // moving — at four connected the invitation is gone, leaving 232
            // points of rows, which is 4.46 of the 52-point pitch.
            // No bounce while the content fits, which today it always does — the
            // stack tops out at 232 points against a 260-point viewport. Left
            // bouncing, it ran *at the same time* as the page drag on top of it
            // (they are simultaneous gestures), so the rows sprang around under
            // a page that was itself moving. Scrolling still works the moment
            // there is something to scroll.
            .modifier(NoIdleBounce())
            .frame(height: Self.promptsDrawn)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: Self.barsFade / Self.promptsDrawn),
                        .init(color: .black, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(height: Self.promptsReserve, alignment: .bottom)
            .onAppear { proxy.scrollTo(Self.promptsFoot, anchor: .bottom) }
            // A new connection lands at the bottom; without this it arrives
            // below the fold on a stack that has started scrolling, so the one
            // thing the user just did is the one thing they cannot see.
            .onChange(of: viewModel.treeState) { _ in
                withAnimation(.spring(response: 0.6, dampingFraction: 0.85)) {
                    proxy.scrollTo(Self.promptsFoot, anchor: .bottom)
                }
            }
        }
        .animation(.spring(response: 0.6, dampingFraction: 0.85), value: viewModel.treeState)
    }

    /// The foot of the scrolling stack, which is where it should sit whenever
    /// the set of connections changes.
    private static let promptsFoot = "prompts-foot"

    private func promptCard(for next: Modality) -> some View {
        let first = viewModel.treeState.isSeedling
        // What went wrong last time, or — where it can be known without asking —
        // what will go wrong this time. The same card, message and button serve
        // both: a permission that is off is the same problem whether it is
        // discovered before the attempt or after it.
        //
        // Read for the dependency, not the value. `blockedMessage` calls
        // `EKEventStore.authorizationStatus` synchronously and nothing publishes
        // a change, so SwiftUI has no reason to rebuild this card when the user
        // comes back from Settings — the warning would outlive the problem.
        // Touching a `@State` that moves on `scenePhase` gives it one.
        _ = permissionTick
        let failure = viewModel.failureMessage(for: next) ?? viewModel.blockedMessage(for: next)

        // Tighter than it looks like it needs to be, and deliberately: at 14pt
        // spacing the widest button — "Connect Lifestyle" — squeezed the text
        // column until `minimumScaleFactor` engaged, so that one bar rendered
        // its question a size smaller than music's and media's. The room comes
        // back from here and from the button's own padding.
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    // No `minimumScaleFactor` here or on the line below, and that
                    // is the point: it let these two report a smaller minimum
                    // width, so a wide button — "Connect Lifestyle" — was
                    // satisfied by shrinking the question instead of compressing
                    // itself, and that one bar rendered a size down from music's
                    // and media's. With no give here, the button is what yields.
                    Text(failure == nil ? (first ? "Ready to grow?" : "Ready for more?")
                                        : "That didn't work")
                        .lineLimit(1)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(failure == nil ? GardenPalette.ink : Self.errorRed)

                    // One `Text`, not two in a stack: `minimumScaleFactor`
                    // applies per view, so a stack shrinks each half on its own
                    // and drops words out of the first — "Continue… Lifestyle."
                    // — instead of scaling the line. Concatenated, it scales as
                    // one and keeps the modality's name in gold.
                    (
                        Text(first ? "Start with " : "Continue with ")
                            .foregroundColor(GardenPalette.muted)
                        + Text(next.label + ".")
                            .foregroundColor(GardenPalette.gold)
                    )
                    .font(.system(size: 15))
                    .lineLimit(1)
                }
                .layoutPriority(1)

                Spacer(minLength: 0)

                Button(action: { connect(next) }) {
                    HStack(spacing: 6) {
                        if viewModel.isDistilling {
                            ProgressView()
                                .tint(GardenPalette.card)
                        } else {
                            Image(systemName: next.systemImage)
                                .font(.system(size: 15))
                        }
                        // After a failure the ask is no longer "connect this",
                        // it is "that didn't work, go again" — and the shorter
                        // label leaves the message below more room.
                        Text(failure == nil ? "Connect \(next.label)" : "Try again")
                            .lineLimit(1)
                            // If anything has to give on the longest modality
                            // name, it is this label and not the headline beside
                            // it: the three bars are read as a series, and a
                            // question that changes size between them looks like
                            // a mistake. A button that is a hair narrower does
                            // not.
                            .minimumScaleFactor(0.72)
                    }
                }
                .buttonStyle(
                    PressShrinkButtonStyle(
                        fill: GardenPalette.gold,
                        foreground: GardenPalette.card,
                        expands: false,
                        font: .system(size: 15, weight: .semibold),
                        horizontalPadding: 10,
                        minHeight: 48
                    )
                )
                // Nothing reads Apple Health yet, so its bar takes its turn with
                // the button dimmed rather than the flow ending a step early. The
                // style doesn't dim on its own, so `disabled` alone would leave a
                // button that looks live and does nothing.
                .opacity(next.isAvailable ? 1 : 0.5)
                .disabled(viewModel.isDistilling || !next.isAvailable)
            }

            // Why the last attempt came to nothing. Full width rather than in
            // the column beside the button: these messages name a Settings path,
            // and a path that wraps to four lines in a 180pt column is one
            // nobody follows.
            //
            // It grows the card, which nudges the garden up — accepted here
            // where it isn't for the connected bars, because a failure is an
            // exception rather than a step of the flow, and reserving the room
            // permanently would cost the plant that height at every stage.
            if let failure {
                VStack(alignment: .leading, spacing: 8) {
                    Text(failure)
                        .font(.system(size: 13))
                        .foregroundStyle(GardenPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    // The way out, not just a description of the problem.
                    //
                    // Every permission this app asks for can be refused in a
                    // place the app cannot reach, and saying so while making the
                    // reader find that place themselves is the difference
                    // between a dead end and a fix.
                    //
                    // Where that place is differs by source, which is the part
                    // this got wrong for a while. `openSettingsURLString` lands
                    // on Written's own Settings page, and the Calendars switch
                    // *is* there — one tap. Health is not on that page at all:
                    // it lives under Privacy & Security, or in the Health app
                    // under Profile › Apps. So the message named one place and
                    // the button went to another.
                    Button(action: Self.openPermissions(for: next)) {
                        HStack(spacing: 5) {
                            Image(systemName: next.opensHealthApp ? "heart" : "gearshape")
                                .font(.system(size: 12, weight: .semibold))
                            Text(next.opensHealthApp ? "Open Health" : "Open Settings")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(GardenPalette.gold)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .overlay {
                            Capsule().strokeBorder(GardenPalette.gold.opacity(0.4), lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        // Tighter than the connected bars above it: this row carries two
        // lines of text and the widest button, and the width has to come from
        // somewhere that isn't the type size.
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .background(GardenPalette.card, in: RoundedRectangle(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(
                    failure == nil ? GardenPalette.ink.opacity(0.06) : Self.errorRed.opacity(0.35),
                    lineWidth: 1
                )
        }
        .animation(.easeOut(duration: 0.25), value: failure)
    }

    /// The same red the birthday sheet rejects with, so a failure looks the same
    /// wherever it appears.
    private static let errorRed = Color(red: 0.72, green: 0.20, blue: 0.16)

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

        // The topmost shoot carries its badge *above* rather than beside it:
        // this is the newest growth, drawn with a bud at its tip, and a badge
        // over the bud says what that bud is for.
        //
        // Full outward travel, not less. Tucking it in toward the stem — which
        // seemed right, since there is no neighbouring badge to clear — put it
        // squarely on the cotyledon blade, because the cotyledons reach further
        // out at this height than the shoot does.
        //
        // Dropped from -0.082 to -0.028. At -0.082 the badge cleared the big
        // upper-left blade by 24px of a 144px badge, which is close enough to
        // read as sitting on it. The blade runs down-and-right through here, so
        // travelling down is what opens the gap — about half a pixel of
        // clearance per pixel of travel — and this lands ~55px clear while
        // staying well above the badge below it.
        if shoot.id == Self.boughShootID {
            return TreeGeometry.illustration(
                CGPoint(x: extent.x + outward * 1.15, y: extent.y - 0.028),
                in: rect
            )
        }

        return TreeGeometry.illustration(
            CGPoint(x: extent.x + outward, y: extent.y + 0.010),
            in: rect
        )
    }

    /// The third and last shoot, added at `.bough`. Named rather than written
    /// as `2` at the one place it is used, because it is a fact about the
    /// drawing rather than an arbitrary index.
    private static let boughShootID = 2

    /// The source a shoot stands for: the cotyledons are music, so the shoots
    /// carry the ones after it, in the order they unlock. A shoot with nothing
    /// left to offer carries nothing.
    /// How far round its rim a badge's ring has gone.
    ///
    /// The running distillation is checked first: `treeState` gains the modality
    /// the moment its records land, but the progress value is still walking its
    /// last stretch to 1 while the banner fades out. Reading the connected state
    /// first would snap that stretch shut.
    private func badgeProgress(_ modality: Modality) -> Double {
        if distillingModality == modality { return distillProgress }
        return viewModel.treeState.branches[modality] != nil ? 1 : 0
    }

    private func shootModality(_ shoot: SeedlingArt.Shoot) -> Modality? {
        let all = Modality.allCases
        let index = shoot.id + 1
        return index < all.count ? all[index] : nil
    }

    // MARK: - Behaviour

    /// Always the picker, even for a modality with one app.
    ///
    /// It used to shortcut straight to the distiller when there was only one
    /// source, which made the three buttons behave differently from each other
    /// — Music asked, Media and Lifestyle jumped. Naming the app before sending
    /// someone to a system permission sheet is the more honest order, and it is
    /// also where "no apps available on this device" can be said at all.
    private func connect(_ modality: Modality) {
        pickedModality = modality
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

/// Stops a scroll view bouncing when its content already fits.
///
/// `scrollBounceBehavior` is iOS 16.4 and this project ships to 16.0, so it is
/// wrapped rather than applied directly. On anything older the bounce stays,
/// which is the behaviour that was there before.
struct NoIdleBounce: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.4, *) {
            content.scrollBounceBehavior(.basedOnSize)
        } else {
            content
        }
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
        case "youtube": youtube
        case "apple_music": appleMusic
        case "health": health
        case "apple_calendar": calendar
        default: unknown
        }
    }

    /// Apple Health's mark: a white tile with the pink-to-red heart.
    private var health: some View {
        ZStack {
            RoundedRectangle(cornerRadius: diameter * 0.26)
                .fill(.white)
                .overlay {
                    RoundedRectangle(cornerRadius: diameter * 0.26)
                        .strokeBorder(GardenPalette.ink.opacity(0.10), lineWidth: 1)
                }
            Image(systemName: "heart.fill")
                .font(.system(size: diameter * 0.52))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color(red: 0.98, green: 0.31, blue: 0.45), Color(red: 0.92, green: 0.10, blue: 0.24)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .frame(width: diameter, height: diameter)
    }

    /// Apple Calendar's mark: a white tile with a red header and today's date,
    /// which is what the real icon shows.
    private var calendar: some View {
        ZStack {
            RoundedRectangle(cornerRadius: diameter * 0.26)
                .fill(.white)
                .overlay {
                    RoundedRectangle(cornerRadius: diameter * 0.26)
                        .strokeBorder(GardenPalette.ink.opacity(0.10), lineWidth: 1)
                }
            VStack(spacing: 0) {
                Text(Self.weekday)
                    .font(.system(size: diameter * 0.20, weight: .semibold))
                    .foregroundStyle(Color(red: 0.98, green: 0.23, blue: 0.19))
                Text(Self.day)
                    .font(.system(size: diameter * 0.40, weight: .regular))
                    .foregroundStyle(GardenPalette.ink)
            }
        }
        .frame(width: diameter, height: diameter)
    }

    /// Read once per launch rather than per render: this is drawn inside a
    /// `body`, and formatting a date there would redo the work on every scroll
    /// tick for a value that changes at most once a day.
    private static let weekday = Date().formatted(.dateTime.weekday(.abbreviated)).uppercased()
    private static let day = Date().formatted(.dateTime.day())

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

    /// How far round the rim this source has got: 0 before it is connected, the
    /// distillation's own progress while it runs, and 1 for good afterwards.
    /// Fed by the same value as the banner's bar, so the ring steps and waits in
    /// step with it rather than keeping its own time.
    var progress: Double = 0

    /// One size for every badge, whichever part of the plant it marks. They are
    /// a set — a row of sources the user is working through — and sizing each
    /// to the leaf beside it made them read as a hierarchy instead.
    private let diameter: CGFloat = 48
    private let ringWidth: CGFloat = 3

    /// One flat gold, not a gradient: any variation around the rim reads as a
    /// glint travelling as the badge bobs, which is the shimmer this is meant to
    /// be free of. Brighter and more saturated than `GardenPalette.gold`, which
    /// is a muted khaki — right for text on parchment, dull as a ring.
    private static let ringGold = Color(red: 0.831, green: 0.667, blue: 0.212)

    @State private var isRaised = false

    var body: some View {
        Image(systemName: modality.systemImage)
            .font(.system(size: diameter * 0.32))
            .foregroundStyle(GardenPalette.gold)
            .frame(width: diameter, height: diameter)
            .background(GardenPalette.gold.opacity(0.07), in: Circle())
            .overlay {
                // The unfilled track: already there as the badge's edge, so the
                // ring has something to run along from the start.
                Circle().strokeBorder(GardenPalette.gold.opacity(0.35), lineWidth: 1)
            }
            .overlay { ring }
            .offset(y: isRaised ? -6 : 6)
            .onAppear {
                withAnimation(.easeInOut(duration: 2.6).repeatForever()) { isRaised = true }
            }
    }

    /// The gold arc along the badge's edge.
    private var ring: some View {
        Circle()
            .trim(from: 0, to: min(max(progress, 0), 1))
            .stroke(Self.ringGold, style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
            // `trim` starts at 3 o'clock; the rim fills from 12, clockwise.
            .rotationEffect(.degrees(-90))
            // Half the stroke would otherwise hang outside the badge.
            .padding(ringWidth / 2)
    }
}

/// Which app should feed this branch.
///
/// Shown for every modality, including the ones with a single app: three
/// buttons on the same screen should behave the same way, and naming the app
/// before a system permission sheet appears is the more honest order.
struct SourcePickerSheet: View {
    let modality: Modality
    @ObservedObject var viewModel: DistillViewModel
    var onClose: () -> Void = {}

    /// Only what this device can actually offer — see `SourceAvailability`,
    /// which hides the two Apple frameworks where they cannot work rather than
    /// hiding whatever app happens not to be installed.
    private var sources: [String] { SourceAvailability.sources(for: modality) }

    /// The height the sheet asks for: the header, plus a row each.
    ///
    /// Computed rather than fixed at 280, which was sized for music's two rows
    /// and left a single-app modality sitting in a half-empty sheet.
    var detentHeight: CGFloat {
        let rows = CGFloat(max(sources.count, 1)) * 56
        return 116 + rows + (sources.isEmpty ? 12 : 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Connect \(modality.label)")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(GardenPalette.ink)
                .padding(.top, 22)
                .padding(.bottom, 4)

            Text(subtitle)
                .font(.system(size: 14))
                .foregroundStyle(GardenPalette.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.bottom, 18)

            if sources.isEmpty {
                emptyState
            } else {
                ForEach(sources, id: \.self) { source in
                    row(for: source)
                    Divider().padding(.leading, 62)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GardenPalette.parchment)
        .preferredColorScheme(.light)
    }

    /// Says how many choices there are, because the answer changes the sentence:
    /// "either one" is nonsense above a single row.
    private var subtitle: String {
        switch sources.count {
        case 0: return "Nothing here can be connected from this device."
        case 1: return "One tap, and the branch starts growing."
        default: return "Either one grows the branch. Both grow it further."
        }
    }

    /// Resolved at runtime rather than hard-coded, the same way
    /// `DashboardView.symbol(forSex:)` does it: a name that doesn't exist on
    /// the running OS draws *nothing*, silently, which is how this state first
    /// rendered with a hole where its icon should be.
    private static let emptySymbol: String = {
        ["iphone.slash", "app.dashed", "questionmark.app"]
            .first { UIImage(systemName: $0) != nil } ?? "exclamationmark.triangle"
    }()

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: Self.emptySymbol)
                .font(.system(size: 22))
                .foregroundStyle(GardenPalette.muted.opacity(0.7))

            Text("No apps available on this device")
                .font(.system(size: 15))
                .foregroundStyle(GardenPalette.muted)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 18)
    }

    private func row(for source: String) -> some View {
        Button {
            viewModel.distill(source: source)
            onClose()
        } label: {
            HStack(spacing: 12) {
                // `Modality.icon(forSource:)` rather than a local guess — it
                // already knows every source's mark, and the badges on the plant
                // draw from the same place, so an app looks the same everywhere.
                Image(systemName: Modality.icon(forSource: source))
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
    }
}

#Preview {
    GrowProfileView(viewModel: DistillViewModel())
}
