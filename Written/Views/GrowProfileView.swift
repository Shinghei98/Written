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

    init(
        viewModel: DistillViewModel,
        isOnboarding: Bool = false,
        isVisible: Bool = true,
        onRevealDrag: @escaping (CGFloat) -> Void = { _ in },
        onRevealEnd: @escaping (Bool) -> Void = { _ in }
    ) {
        self.viewModel = viewModel
        self.isOnboarding = isOnboarding
        self.isVisible = isVisible
        self.onRevealDrag = onRevealDrag
        self.onRevealEnd = onRevealEnd
        _displayedSkeleton = State(initialValue: viewModel.skeleton)
    }

    @Environment(\.scenePhase) private var scenePhase

    /// Whether this is the first time through, before "Explore" has been
    /// tapped. The arrow and the pull-up exist only here: during onboarding
    /// there is no tab bar, so the garden has to carry the way onward itself.
    /// In regular use the bar does that job and an arrow would be a second
    /// route to the same place.
    var isOnboarding = false

    /// Whether the garden is the tab on screen, as `ChatView` and `DashboardTab`
    /// are each told. Only the badges read it, and only to stop their clock
    /// while nobody is looking at them — every tab stays mounted, so a bob left
    /// running behind Explore would redraw for the life of the app.
    var isVisible = true

    var onRevealDrag: (CGFloat) -> Void = { _ in }

    /// The finger left the screen: `true` to go through to the dashboard,
    /// `false` to settle back onto the garden.
    var onRevealEnd: (Bool) -> Void = { _ in }

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

    /// What the picker was asked for, held between the tap and the sheet
    /// finishing its dismissal. See the `.sheet`'s `onDismiss`.
    @State private var chosenSource: String?

    /// The tree currently on screen, which lags the view model's by one
    /// watering: the new shape must not appear until the can has poured, or the
    /// tree visibly grows before anything waters it.
    /// The plant currently drawn, seeded from the view model in `init`.
    ///
    /// **Not `.empty`, and that is the whole of the re-assembling bug.** Starting
    /// bare meant `SeedlingView` first appeared at `.sprout` and played its
    /// entrance — a seed pushing out of the soil — before `growTree` set the real
    /// skeleton a moment later and it grew the rest of the way. So every launch
    /// replayed a plant the reader had already grown, and no amount of settling
    /// inside `SeedlingView` could help: by the time the true stage arrived the
    /// sprout was already climbing.
    ///
    /// `DistillViewModel.init` loads `RecordStore` and `LifestyleStore`
    /// synchronously, so the skeleton is right here before the first frame — the
    /// same reason `ConversationView` seeds its messages in `init` rather than in
    /// `.task`, which runs one frame too late.
    @State private var displayedSkeleton: TreeSkeleton
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
    /// Which branch the user actually asked for, as opposed to which one the
    /// plant would grow next.
    ///
    /// **These stopped being the same thing when the badges became tappable.**
    /// A re-distillation of an already-connected source is not the next step in
    /// the sequence, so reading `nextModality` named the wrong branch in the
    /// banner and left the ring on the tapped badge sitting at a full circle —
    /// no progress anywhere, which reads as the tap having done nothing.
    @State private var requestedModality: Modality?

    /// The last branch a distillation was actually started for, kept **after**
    /// that distillation ends.
    ///
    /// **This is the difference between a failure being reported and a failure
    /// being swallowed.** The prompt card was built for `nextModality` and asked
    /// *that* branch what went wrong, which is right only while the two agree.
    /// Connect a source out of sequence — Lifestyle first, when Media is next —
    /// and the error is recorded against Lifestyle while the card interrogates
    /// Media, gets nil, and draws "Ready to grow?" as though nothing had been
    /// tried. The watering can runs, the screen returns to exactly how it was,
    /// and nothing anywhere says why: reported as "it just keeps loading and
    /// never ended", because with no ending drawn there is no way to tell that
    /// it ended.
    ///
    /// `requestedModality` already knows the answer and is deliberately cleared
    /// when the run finishes (`onChange` below) so the next run cannot inherit
    /// it — which is the same moment the error needs it. Hence a second
    /// property that outlives the run and is replaced only by the next attempt.
    @State private var lastAttempted: Modality?
    @State private var distillProgress: Double = 0
    @State private var progressWalk: Task<Void, Never>?

    /// How far the arrow is lifted, in points. Driven a hop at a time by
    /// `startBobbing`.
    @State private var arrowLift: CGFloat = 0
    @State private var bobbing: Task<Void, Never>?
    /// Whether a reveal drag is in flight.
    ///
    /// A flag rather than the live offset. Storing the offset here meant a
    /// `@State` write on every touch event, so each frame rebuilt this view *and*
    /// `HomeView` — and the offset is not needed locally anyway, since
    /// `HomeView` owns the movement.
    @State private var isDragging = false

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
    /// Was the tallest the stack could ever get; is now deliberately more than
    /// that. The old figure — two bars, the invitation and the Dashboard button
    /// — is kept as the derivation it came from, plus one row's pitch, because
    /// the number's job changed: it stopped being "the most the stack needs" and
    /// became "the space the stack is given". Growing it walks the boundary
    /// between the garden and the rows *up* the screen, which lifts the plant
    /// and lets the rows start higher in one move.
    private static let promptsReserve: CGFloat = 44 * 2 + 76 + 48 + 8 * 3 + barRow

    /// What the badge and the sparkles are, as a fraction of the garden square.
    ///
    /// **Measured, and the reference is written down because the whole point is
    /// that it can be re-derived.** The square is `min(width, height)` of the
    /// space this page gives the garden, and it is *height*-limited on every
    /// iPhone — logged at **257.67pt on an iPhone 17 Pro**, which works out at
    /// ~127pt on an SE (3rd gen) and ~339pt on a 17 Pro Max from the badge
    /// spacing on screenshots of all three.
    ///
    /// So these are the tuned point sizes over 257.67. A 17 Pro therefore
    /// renders exactly what it rendered before — 48pt badges, 13 and 9pt
    /// sparkles — and every other phone now gets the same badge *relative to the
    /// plant* instead of the same badge in points. The art was hand-tuned on a
    /// 3x device (`shootBadge` still talks in "24px of a 144px badge", which is
    /// 48pt at 3x), which is why that is the one held fixed.
    ///
    /// If the garden's height budget ever changes, these do not need touching —
    /// they are ratios. What would need re-measuring is the 257.67, and only if
    /// somebody wants to keep the 17 Pro pinned to 48pt exactly.
    private static let badgeRatio: CGFloat = 48.0 / 257.666667
    private static let sparkleLarge: CGFloat = 13.0 / 257.666667
    private static let sparkleSmall: CGFloat = 9.0 / 257.666667

    /// The gap between the header and the plant.
    ///
    /// Fixed, where it used to be half of whatever was left over. The garden sat
    /// between two flexible spacers that split the slack evenly, so it was
    /// centred in the space rather than placed in it — and the only way to raise
    /// the plant was to take space from the bottom, which moved the rows the
    /// wrong way. Pinning the top gap and letting the single spacer below absorb
    /// the remainder makes the plant's height something set here rather than
    /// something that falls out.
    /// 38, which is half way back from the 10 the lift first landed on. The
    /// plant had risen 57 points from where it used to sit and that was too far;
    /// this returns 28 of them. The rows are untouched by it — their top edge is
    /// set by `promptsReserve` and stays where the lift put it, so what closes
    /// is the gap between the plant and the stack rather than either boundary
    /// moving back.
    private static let gardenTopGap: CGFloat = 38

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

    /// The strip at the foot of the page holding the arrow.
    ///
    /// Taken out of the reserve rather than added below it. The reserve is what
    /// the garden is measured against, so a strip added underneath would have
    /// come straight off the plant — and the Dashboard button that used to sit
    /// inside the reserve was 48 points plus its gap, so removing it pays for
    /// this twice over and still leaves the rows better off than before.
    private static let handleHeight: CGFloat = 28

    /// Bumped when the app comes back to the front, so a permission changed
    /// while it was away is re-read. See `promptCard`.
    @State private var permissionTick = 0

    /// How far the page must be dragged before letting go goes through to the
    /// dashboard rather than settling back.
    ///
    /// A fixed distance, not a fraction of the screen: this is a commit
    /// threshold for a gesture, and a thumb's idea of "I meant that" does not
    /// scale with the phone.
    private static let commitDistance: CGFloat = 110

    /// What the stack is drawn and scrolled inside, once the arrow's strip and
    /// the tab bar's clearance are taken out.
    private static let promptsDrawn: CGFloat =
        promptsReserve - MainTabBar.overlayHeight + promptsOverdraw

    /// Whether the page can be pulled up at all: only during onboarding, and
    /// only once something has been connected — the dashboard is the way into
    /// what a distillation produced, so there has to be one.
    private var canReveal: Bool {
        isOnboarding && !viewModel.treeState.connectedModalities.isEmpty
    }

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
                Spacer(minLength: 0).frame(height: Self.gardenTopGap)
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
                    // One strip, two occupants, and never both: during
                    // onboarding the arrow advertising the pull-up, afterwards
                    // the clearance the tab bar needs. They are the same height
                    // by construction rather than by coincidence, so the totals
                    // hold either way and the plant does not move between the
                    // two halves of the app.
                    if isOnboarding {
                        revealHandle
                            .frame(height: MainTabBar.overlayHeight, alignment: .bottom)
                    } else {
                        Color.clear.frame(height: MainTabBar.overlayHeight)
                    }
                }
                // Plain parchment now. The rounded edge and shadow were there
                // to make this read as a sheet lying over the dashboard, and
                // with the pull-up gone there is nothing underneath for it to
                // be a sheet over.
                .background(GardenPalette.parchment.ignoresSafeArea(edges: .bottom))
                // Simultaneous rather than exclusive: the stack above is a
                // scroll view and would otherwise swallow every upward drag
                // before this saw it. `canReveal` is false outside onboarding,
                // so in regular use this does nothing at all.
                .simultaneousGesture(revealDrag)
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
                    // So `-connect` exercises the same attribution a tap does,
                    // rather than falling back to `nextModality` and testing a
                    // path no user takes.
                    requestedModality = Modality.owning(source: source)
                    viewModel.distill(source: source)
                }
            }
            // `-probe podcasts` lives at the root now — see `WrittenApp`. It was
            // here, and here it only fires if the garden is the screen you land
            // on, which is not true for anyone past onboarding.
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
                // What was asked for, falling back to the sequence for the
                // paths that start a distillation without going through a
                // picker — `-connect health` and the preview stepper.
                distillingModality = requestedModality ?? viewModel.treeState.nextModality
                // Survives the run, unlike the two above. Set here rather than
                // at the tap so every route in — picker, badge, `-connect` —
                // records it in one place.
                lastAttempted = distillingModality
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
                    // Cleared with the rest, or the *next* run inherits this
                    // one's branch and animates the wrong ring.
                    requestedModality = nil
                }
            }
        }
        // **`onDismiss`, not the row's own action.** The chosen source is
        // started once this sheet has actually gone, rather than while it is
        // going: a system permission request raised during a modal's dismissal
        // has nothing stable to present over, and for Apple Health that is a
        // plausible cause of the sheet never appearing at all — see
        // `SourcePickerSheet.onChoose`.
        //
        // This is the transition's own completion callback, so it needs no
        // guessed delay, and it is right for every source rather than only for
        // Health: YouTube's `ASWebAuthenticationSession` and the MusicKit and
        // EventKit alerts are all presentations racing the same dismissal.
        //
        // A sheet swiped away without a choice leaves `chosenSource` nil and
        // starts nothing, which is what should happen anyway.
        .sheet(item: $pickedModality, onDismiss: startChosenSource) { modality in
            // Built once so the detent and the content agree on how many rows
            // there are — asking the sheet for 280pt regardless left a
            // single-app modality in a half-empty card.
            let sheet = SourcePickerSheet(
                modality: modality,
                viewModel: viewModel,
                onChoose: { source in
                    chosenSource = source
                    pickedModality = nil
                }
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
                // **Two lines, shrinking to fit rather than taking a third.**
                //
                // `BrandFont` is `.custom(…, relativeTo:)` and follows Dynamic
                // Type; the app's other 165 type declarations are
                // `.system(size:)` and do not. So a larger text setting enlarges
                // this heading alone — measured at 1.3× on a tester's phone,
                // 41.7pt of cap height against the ~32 a 46pt Quicksand should
                // give, while `.system(size: 15)` on the same screen measured
                // exactly its designed 10.5.
                //
                // At that size "Grow your" needs more than the ~274pt left after
                // the trailing padding on a 390pt phone, so it wrapped to three
                // lines — and the plant, which is built from what remains under
                // this header, lost about 55pt. Neither the font scaling nor the
                // narrow screen would have done it alone, which is why it
                // arrived as a device report.
                //
                // **Not a `.dynamicTypeSize` clamp**, which is the shorter fix
                // and refuses somebody's accessibility setting outright. The
                // heading still grows; it just stops spending the drawing's
                // room to do it.
                .lineLimit(2)
                // Down to a third if it has to. The floor is low on purpose:
                // it is the last thing standing between a large text setting
                // and a header that overflows its budget, and a heading a
                // little small is a far better outcome than one that clips.
                .minimumScaleFactor(0.35)
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
        // **A fixed budget, and this is what makes the plant deterministic.**
        //
        // The header used to take its natural height and the illustration got
        // whatever remained — so a heading that grew spent the drawing's room,
        // and the plant was the only element on the screen with no floor. That
        // is what shrank it on a tester's phone; the art itself was never
        // fragile, since `TreeGeometry.scale` is `min(width, height)` of
        // whatever box it is handed and every coordinate is a fraction of that.
        //
        // With this fixed, the plant's box reads
        // `screen − safeArea − headerBudget − promptsReserve`: every term a
        // constant, so the drawing is the same size at every text setting on a
        // given device. The hand-measured badge positions were always assuming
        // that and never actually had it.
        //
        // **Text yields instead**, through `lineLimit` and
        // `minimumScaleFactor` above. That is the trade: at large sizes the
        // heading is smaller than it wants to be, and the subject of the screen
        // is untouched.
        .frame(height: Self.headerBudget, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What the title and subtitle get, whatever the text size.
    ///
    /// Measured off the design rather than chosen: the title is two lines of
    /// 46pt Quicksand at a −2 line spacing, so about 111pt; the 10pt gap; and
    /// the subtitle, `.system(size: 16)` and therefore fixed, wrapping to at
    /// most three lines inside its 268pt column, so about 57. 180 covers it with
    /// a little slack and no more — slack here is room the plant does not get.
    private static let headerBudget: CGFloat = 180

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
                // The same `side` every other part of the illustration is built
                // from — `TreeGeometry.scale` takes exactly this of the frame it
                // is handed, and the badges' own positions come through
                // `TreeGeometry.illustration`. Anything sized in raw points
                // inside this reader is the odd one out, which is how the badges
                // came to overlap on a small phone.
                let side = min(geometry.size.width, geometry.size.height)

                // Clear of the badge, which now sits at ~0.83 × 0.36 beside the
                // right-hand leaf.
                SparkleView(size: Self.sparkleLarge * side, delay: 0.0)
                    .position(x: geometry.size.width * 0.87, y: geometry.size.height * 0.14)
                SparkleView(size: Self.sparkleSmall * side, delay: 1.2)
                    .position(x: geometry.size.width * 0.12, y: geometry.size.height * 0.44)

                // Pinned to the right-hand leaf rather than to the screen, so
                // it keeps its place against the plant as the stem lifts them.
                // One badge per part of the plant, each keeping its own icon:
                // music belongs to the pair of leaves it grew, so it stays a
                // music note once connected rather than turning into whatever
                // is offered next.
                if displayedSkeleton.illustrated != nil {
                    // Whatever comes first in the sequence, not music by name.
                    // The cotyledons are the plant's first growth, so they carry
                    // the first modality — which is media now.
                    ModalityBadge(modality: Self.firstModality,
                                  progress: badgeProgress(Self.firstModality),
                                  diameter: Self.badgeRatio * side, isFloating: isVisible)
                        // **Before `.position`, and that is not a style choice.**
                        // `position` returns a view that fills its parent and
                        // merely draws the child at a point — so a tap attached
                        // after it covers the whole garden, not the badge. Four
                        // of those overlap completely and the last in the ZStack
                        // takes every tap, which is why every icon opened Events.
                        .modifier(BadgeTap(modality: Self.firstModality,
                                           isEnabled: !viewModel.isDistilling) {
                            connect(Self.firstModality)
                        })
                        .position(cotyledonBadge(in: CGRect(origin: .zero, size: geometry.size)))
                        // Arrives once the plant has finished opening, not with
                        // it: the seedling is the thing to look at first, and
                        // the badge is an invitation to what comes next.
                        .scaleEffect(hasBadgeArrived ? 1 : 0.72)
                        .opacity(hasBadgeArrived ? 1 : 0)
                        // An opacity of 0 still takes taps in SwiftUI, unlike in
                        // UIKit — so without this the badge is pressable during
                        // the half second before it is visible.
                        .allowsHitTesting(hasBadgeArrived)
                }

                // One per shoot, in the order the modalities unlock — each
                // beside the growth it belongs to, and only once that shoot has
                // finished unfolding.
                // **`leafLift`, not `stage.extended`** — and that is the whole
                // of the bough-to-canopy jump.
                //
                // `shoots(by:)` does not just filter: past 3 it *blends* every
                // shoot toward its canopy shape, so the same shoot id has
                // different reach and turn at 3 and at 4. Read off the discrete
                // stage, that blend landed the instant `displayedSkeleton` was
                // assigned — which happens outside any transaction, so
                // `.position` had nothing to interpolate and the badges simply
                // reappeared somewhere else. `leafLift` carries the same number
                // but is set inside `withAnimation(extensionAnimation)`, so the
                // move animates, and it is what `shootExtent` below already
                // used — the two were reading the plant at different moments.
                if displayedSkeleton.illustrated != nil {
                    ForEach(SeedlingArt.shoots(by: leafLift)) { shoot in
                        if let modality = shootModality(shoot) {
                            ModalityBadge(modality: modality, progress: badgeProgress(modality),
                                          diameter: Self.badgeRatio * side, isFloating: isVisible)
                                // Before `.position` — see the note on the music
                                // badge above.
                                .modifier(BadgeTap(modality: modality, isEnabled: !viewModel.isDistilling) {
                                    connect(modality)
                                })
                                .position(shootBadge(shoot, in: CGRect(origin: .zero, size: geometry.size)))
                                .scaleEffect(hasShootBadgeArrived[shoot.id] == true ? 1 : 0.72)
                                .opacity(hasShootBadgeArrived[shoot.id] == true ? 1 : 0)
                                .allowsHitTesting(hasShootBadgeArrived[shoot.id] == true)
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
                        ConnectedBar(
                            modality: modality,
                            sources: viewModel.connectedSources(for: modality),
                            // The same `connect` the badges and the prompt card
                            // call, so all three routes to a source open the
                            // same picker and record the same attribution.
                            isEnabled: !viewModel.isDistilling,
                            onTap: { connect(modality) }
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    // The branch that just failed takes the card back, ahead of
                    // whichever one the sequence would offer. Its message, its
                    // Connect button — so the retry is on the thing that broke
                    // rather than on the next thing along.
                    if let prompt = promptModality {
                        promptCard(for: prompt)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .id(prompt)
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
            // **A failure grows the card and changes nothing about the tree.**
            //
            // Which is why the line above never fired for one: `treeState` is
            // the same before and after a distillation that returned nothing.
            // The card got ~95pt taller inside a fixed 288pt window and the new
            // content — the message's last lines, and the button under it —
            // went below the fold, where it stayed for a week. Keyed on the
            // statuses because that is what a failure actually moves.
            .onChange(of: viewModel.healthStatus) { _ in scrollToFoot(proxy) }
            .onChange(of: viewModel.calendarStatus) { _ in scrollToFoot(proxy) }
            .onChange(of: viewModel.appleMusicStatus) { _ in scrollToFoot(proxy) }
            .onChange(of: viewModel.youtubeStatus) { _ in scrollToFoot(proxy) }
        }
        .animation(.spring(response: 0.6, dampingFraction: 0.85), value: viewModel.treeState)
    }

    /// The foot of the scrolling stack, which is where it should sit whenever
    /// the set of connections changes.
    private static let promptsFoot = "prompts-foot"

    private func scrollToFoot(_ proxy: ScrollViewProxy) {
        withAnimation(.spring(response: 0.6, dampingFraction: 0.85)) {
            proxy.scrollTo(Self.promptsFoot, anchor: .bottom)
        }
    }

    /// The arrow at the foot of the page: the only sign that there is anything
    /// under it.
    ///
    /// Not a control. It is a label for the gesture, so it takes no taps —
    /// `allowsHitTesting(false)` rather than merely having no action, or it
    /// would swallow the drag that starts on top of it, which is exactly where
    /// a user aiming at the arrow will start one.
    private var revealHandle: some View {
        Image(systemName: "chevron.up")
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(GardenPalette.gold)
            .offset(y: arrowLift)
            .opacity(canReveal ? 1 : 0)
            .animation(.easeInOut(duration: 0.35), value: canReveal)
            .allowsHitTesting(false)
            .onAppear(perform: startBobbing)
            .onDisappear { bobbing?.cancel() }
    }

    /// Two hops, a pause, two hops — rather than a continuous rise and fall.
    ///
    /// A steady bob is ambient and stops being read after a few seconds; a
    /// burst with a gap is a signal, because the gap is what makes the next
    /// burst an event. `repeatForever(autoreverses:)` cannot express it — it
    /// only knows one cycle — so the rhythm is driven from a task and each hop
    /// is its own animation.
    private func startBobbing() {
        bobbing?.cancel()
        bobbing = Task { @MainActor in
            while !Task.isCancelled {
                // Nothing to advertise, or the page is already up: idle rather
                // than exit, since either can change without this restarting.
                guard canReveal, !isDragging else {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    continue
                }
                for _ in 0..<2 {
                    withAnimation(.easeOut(duration: 0.24)) { arrowLift = -7 }
                    try? await Task.sleep(nanoseconds: 240_000_000)
                    withAnimation(.easeIn(duration: 0.26)) { arrowLift = 0 }
                    try? await Task.sleep(nanoseconds: 260_000_000)
                }
                try? await Task.sleep(nanoseconds: 1_300_000_000)
            }
        }
    }

    /// Dragging the page itself, which is the gesture the arrow is advertising.
    ///
    /// **Measured in `.global`, and it has to be.** `HomeView` moves this whole
    /// view in response to what this reports, and a `DragGesture` measures its
    /// translation against the view it is attached to — so in the default local
    /// space the page moving under the finger changed the frame the translation
    /// was measured in, which changed the translation, which moved the page
    /// again. That is a feedback loop, and on device it read as the page
    /// shaking. The global space does not move when the page does.
    private var revealDrag: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                guard canReveal else { return }
                // Clamped at zero: the dashboard is above this page and there is
                // nothing below it, so pulling down does nothing rather than
                // implying a third screen.
                if !isDragging { isDragging = true }
                onRevealDrag(max(0, -value.translation.height))
            }
            .onEnded { value in
                guard canReveal, isDragging else { return }
                isDragging = false
                // Where the finger was going, not just where it stopped, so a
                // short flick commits the same way a long slow pull does.
                let projected = max(0, -value.predictedEndTranslation.height)
                onRevealEnd(projected >= Self.commitDistance)
            }
    }


    /// Which branch the prompt card speaks for: the one that just failed if it
    /// did, otherwise the next in the sequence.
    ///
    /// The failure has to be re-read rather than remembered — `lastAttempted`
    /// records what was tried, not how it went, so a branch that succeeded and
    /// became a `ConnectedBar` must not go on holding the card.
    private var promptModality: Modality? {
        if let attempted = lastAttempted,
           viewModel.failureMessage(for: attempted) != nil {
            return attempted
        }
        return viewModel.treeState.nextModality
    }

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

                // **One button, and only ever one.**
                //
                // A failure used to grow a second button underneath explaining
                // itself, which then sat below the fold of the 288pt reserve and
                // was never seen by anybody. Whatever the card has to offer goes
                // here, where the finger already is.
                //
                // It stays "Try again" for Health even though a retry cannot
                // *grant* anything — HealthKit shows its sheet once. What a
                // retry is for is re-reading after the switch has been changed
                // in Health, which is the actual sequence: read the message, go
                // and turn it on, come back and tap.
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
                        // **Long-press to copy, for the builds that carry a
                        // diagnostic trail.** A tester's screenshot is the only
                        // instrument this project has, and a wrapped line of
                        // stage names and error codes is exactly the thing that
                        // gets cropped, blurred or retyped wrong. Copying hands
                        // over the whole string.
                        //
                        // Only where there is something worth copying:
                        // `BuildKind.showsDiagnostics` is Debug and TestFlight,
                        // and in a shipped build this is one plain sentence that
                        // a context menu would only clutter.
                        .contextMenu {
                            if BuildKind.showsDiagnostics {
                                Button {
                                    UIPasteboard.general.string = failure
                                } label: {
                                    Label("Copy details", systemImage: "doc.on.doc")
                                }
                            }
                        }

                    // The way out, not just a description of the problem.
                    //
                    // Every permission this app asks for can be refused in a
                    // place the app cannot reach, and saying so while making the
                    // reader find that place themselves is the difference
                    // between a dead end and a fix.
                    //
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
    /// How much further from the stem every badge sits than the growth it marks.
    ///
    /// **One constant, applied with the sign of the side it is on**, so the left
    /// column moves left exactly as far as the right column moves right. Adding
    /// it per-site would let the two drift apart, and a plant whose badges are
    /// 4pt further out on one side than the other reads as crooked long before
    /// anybody works out why.
    ///
    /// In unit space, so it scales with the garden square like everything else
    /// the illustration is built from — 0.05 is about 13pt on a 17 Pro and 6pt
    /// on an SE, which is the right relationship: the gap should grow with the
    /// plant rather than staying a fixed number of points.
    private static let badgeSpread: CGFloat = 0.05

    private func cotyledonBadge(in rect: CGRect) -> CGPoint {
        guard displayedSkeleton.illustrated != nil else {
            return CGPoint(x: rect.width * 0.74, y: rect.height * 0.58)
        }
        let tip = SeedlingArt.cotyledonTip(mirrored: true, extended: leafLift)
        // The cotyledon badge is always the right-hand one, so the spread is
        // always added rather than signed.
        return TreeGeometry.illustration(
            CGPoint(x: tip.x + 0.074 + Self.badgeSpread, y: tip.y + 0.082),
            in: rect
        )
    }

    /// Just outside a shoot's cluster, level with it and on the shoot's own
    /// side of the stem.
    private func shootBadge(_ shoot: SeedlingArt.Shoot, in rect: CGRect) -> CGPoint {
        let extent = SeedlingArt.shootExtent(of: shoot, extended: leafLift)
        // Signed by the side the shoot is on, so both columns move out by the
        // same distance rather than one drifting relative to the other.
        let side: CGFloat = shoot.reach.width < 0 ? -1 : 1
        let outward: CGFloat = side * (0.082 + Self.badgeSpread)

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
            // The 1.15 applies to the tuned 0.082 only. Multiplying the spread
            // by it as well would push this one badge 15% further out than its
            // neighbours, which is exactly the asymmetry the single constant is
            // meant to prevent.
            return TreeGeometry.illustration(
                CGPoint(x: extent.x + side * (0.082 * 1.15 + Self.badgeSpread), y: extent.y - 0.028),
                in: rect
            )
        }

        return TreeGeometry.illustration(
            CGPoint(x: extent.x + outward, y: extent.y + 0.010 + Self.firstShootDrop(shoot)),
            in: rect
        )
    }

    /// Extra clearance for the lowest shoot's badge, and nothing else's.
    ///
    /// Every other badge is spaced from its neighbour by the pitch between two
    /// shoots, which the drawing sets. The first one's neighbour is the
    /// *cotyledon* badge, which hangs off the leaves rather than off a shoot and
    /// so is not spaced by anything — at stage 1 the two sat 6pt apart, on 48pt
    /// badges, and read as one object.
    ///
    /// Applied to shoot 0 alone for that reason. Dropping every shoot would
    /// leave the crowding it is meant to fix exactly as it was, since the shoots
    /// would move together, and would push the upper ones off their own growth.
    /// Sign is positive because the illustration's y runs down the page, and the
    /// cotyledon badge sits above this one.
    private static func firstShootDrop(_ shoot: SeedlingArt.Shoot) -> CGFloat {
        shoot.id == 0 ? 0.031 : 0
    }

    /// The modality the cotyledon badge stands for: the first one connected.
    ///
    /// Read from the sequence rather than written as `.music`, which is what it
    /// used to be — the order is now `Modality.allCases`' business alone, and a
    /// name hardcoded here would quietly disagree with it.
    private static var firstModality: Modality { Modality.allCases[0] }

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
    /// Starts whatever the picker was asked for, now that it has gone.
    ///
    /// `requestedModality` is not set here: `connect(_:)` already recorded it
    /// when the picker opened, which is deliberately earlier than this — by the
    /// time a distillation starts, the only thing left to go on is
    /// `nextModality`, and that is the wrong answer for a re-distill.
    private func startChosenSource() {
        guard let source = chosenSource else { return }
        chosenSource = nil
        viewModel.distill(source: source)
    }

    private func connect(_ modality: Modality) {
        pickedModality = modality
        // Remembered here rather than worked out when the distillation starts:
        // by then the only thing left to go on is `nextModality`, which is a
        // different question and the wrong answer for a re-distill.
        requestedModality = modality
    }

    /// Draws a plant that is simply *there* — no entrance, no growth.
    ///
    /// Both callers need every one of these five, which is why it is one
    /// function rather than two similar blocks: the skeleton, full opacity, the
    /// cotyledon badge, every shoot badge this stage has, and `leafLift`. That
    /// last one is not decoration — badge *positions* are read off it, so a
    /// settled plant with `leafLift` at zero would put its icons in the wrong
    /// place even once they were visible.
    private func settle(to skeleton: TreeSkeleton) {
        displayedSkeleton = skeleton
        treeOpacity = 1
        hasBadgeArrived = true
        if let stage = skeleton.illustrated {
            for shoot in SeedlingArt.shoots(by: stage.extended) {
                hasShootBadgeArrived[shoot.id] = true
            }
        }
        // Straight to full extension: the animated form is in step with a stem
        // that, this time, is not climbing.
        leafLift = skeleton.illustrated?.extended ?? 1
    }

    private func growTree() async {
        let next = viewModel.skeleton

        // **A plant arriving from the server has not grown.** While the restore
        // is still in flight the tree is whatever the local cache held — nothing
        // at all, on an account that has just signed in on this device — so
        // drawing it and calling that "the first draw" makes the *real* plant,
        // when it lands a moment later, look like growth: dissolve, regrow,
        // badges popping in on their own timers. That is the reassembly people
        // reported after switching accounts.
        //
        // Snapped, and deliberately without setting `hasDrawnOnce`, so the draw
        // that follows hydration is still treated as the first one and takes the
        // settle path below rather than the growth path.
        //
        // **Through `settle`, not by assigning the skeleton alone.** Written the
        // short way this returned before the badges were told they had arrived —
        // and they draw at `opacity(hasShootBadgeArrived ? 1 : 0)`, so they were
        // invisible. Worse, `growTree` only re-runs when `treeState` *changes*:
        // on a relaunch where the cache already matches the server it never
        // changes, so nothing ever set the flags and the icons stayed gone for
        // good. Reported within minutes of the build landing.
        if viewModel.isHydrating {
            settle(to: next)
            return
        }
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
        // **A relaunch onto a grown plant is not a beginning.** `SeedlingView`
        // settles rather than replaying its entrance in that case, and the
        // badges have to agree — left as they were they would still pop in on
        // their own timers, half a second after a plant that never grew, which
        // reads worse than either behaviour on its own.
        //
        // Computed before `hasDrawnOnce` is set, since that is the flag being
        // asked about.
        let isRelaunchOntoGrown = !hasDrawnOnce && (next.illustrated ?? .sprout) != .sprout

        hasDrawnOnce = true

        if isRelaunchOntoGrown {
            settle(to: next)
            return
        }

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
        // **A source without a case here draws a blank disc**, because `unknown`
        // is a faint circle and nothing else. That is what happened to Apple
        // Podcasts: the source shipped, distilled, joined the Media bar, and
        // rendered as nothing. Adding a source means adding a mark, and the
        // `default` is a placeholder for the genuinely unrecognised rather than
        // a resting place for the newest one.
        switch source {
        case "youtube": youtube
        case "apple_music": appleMusic
        case "apple_podcasts": applePodcasts
        case "spotify": spotify
        case "health": health
        case "apple_calendar": calendar
        case "google_calendar": googleCalendar
        default: unknown
        }
    }

    /// Google Calendar's mark: the waisted blue leaf and the white 31.
    ///
    /// **Three shapes, and the profile was measured off the icon rather than
    /// read off it.** Scanning the app icon row by row, as fractions of the
    /// white tile:
    ///
    ///     y 0.20   width 0.502   the cap, lightest blue
    ///     y 0.30   width 0.655   cap meets body — widest
    ///     y 0.55   width 0.606   the waist
    ///     y 0.75   width 0.655   widest again
    ///     y 0.82   —             bottom
    ///
    /// So the body is two smooth-edged trapeziums meeting at their narrow ends,
    /// with the join reading as a faint fold because the gradient crosses it;
    /// and above them a third, weaker-blue trapezium whose *wide* side is the
    /// one the body's top covers. The waist is only 7% — a gentle curve, not a
    /// pinch, and drawing it any deeper reads as an hourglass.
    ///
    /// The piece is **0.655 of the tile wide**, centred, with 0.17 of clear
    /// white either side. Two earlier drafts had it far too large: a plain white
    /// tile with blue text, then a blue rectangle at 0.78 with almost no
    /// padding.
    private var googleCalendar: some View {
        ZStack {
            RoundedRectangle(cornerRadius: diameter * 0.26)
                .fill(.white)
                .overlay {
                    RoundedRectangle(cornerRadius: diameter * 0.26)
                        .strokeBorder(GardenPalette.ink.opacity(0.10), lineWidth: 1)
                }

            ZStack {
                // The cap, behind the body so the body's wide top covers its
                // wide bottom — which is how the icon hides the join.
                GoogleCalendarCap()
                    .fill(Color(red: 0.706, green: 0.769, blue: 0.996))
                    .frame(width: diameter * 0.655, height: diameter * 0.20)
                    .offset(y: -diameter * 0.215)

                GoogleCalendarBody()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.459, green: 0.600, blue: 0.969),
                                Color(red: 0.318, green: 0.545, blue: 0.965),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: diameter * 0.655, height: diameter * 0.52)
                    .offset(y: diameter * 0.055)

                Text("31")
                    .font(.system(size: diameter * 0.30, weight: .medium))
                    .foregroundStyle(.white)
                    .offset(y: diameter * 0.055)
            }
        }
        .frame(width: diameter, height: diameter)
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

    /// Apple Podcasts' mark: the purple tile, which is the part anyone
    /// recognises at 26 points.
    ///
    /// Stylised like the others rather than reproduced — YouTube's is a red
    /// rounded rectangle and a white triangle, not the real wordmark. The glyph
    /// is `mic.fill` for the same reason `Modality.icon(forSource:)` uses it, so
    /// the badge on the plant and the mark in the bar agree; Apple's own
    /// concentric-arc figure has no SF Symbol equivalent and would read as mush
    /// at this size anyway.
    /// Apple Podcasts' mark: the broadcast figure on purple.
    ///
    /// **Measured off the app icon rather than approximated.** It drew a
    /// `mic.fill` before, which is a microphone and not what Apple ships — the
    /// real glyph is a circle over a tapered body inside two faint rings, the
    /// "someone broadcasting" figure. Colours sampled from the icon: the tile
    /// runs rgb(155,88,205) at the top to rgb(111,54,168) at the bottom, and the
    /// rings are the same purple lightened rather than white.
    ///
    /// Proportions, also measured, as fractions of the tile: the glyph is 0.25
    /// wide and 0.56 tall, the head about 0.17 across.
    private var applePodcasts: some View {
        ZStack {
            RoundedRectangle(cornerRadius: diameter * 0.26)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.608, green: 0.345, blue: 0.804),
                            Color(red: 0.435, green: 0.212, blue: 0.659),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            // The two broadcast rings, lightened rather than white — at this
            // size a white ring reads as a border on the tile.
            Circle()
                .strokeBorder(.white.opacity(0.28), lineWidth: diameter * 0.055)
                .frame(width: diameter * 0.70, height: diameter * 0.70)
                .offset(y: -diameter * 0.04)
            Circle()
                .strokeBorder(.white.opacity(0.34), lineWidth: diameter * 0.05)
                .frame(width: diameter * 0.44, height: diameter * 0.44)
                .offset(y: -diameter * 0.04)

            // The head.
            Circle()
                .fill(.white)
                .frame(width: diameter * 0.17, height: diameter * 0.17)
                .offset(y: -diameter * 0.12)

            // The body: wide at the shoulders, tapering to a rounded point.
            // A capsule would be simpler and reads as a pill rather than a
            // figure, which is the difference between this and the microphone
            // it replaced.
            PodcastBody()
                .fill(.white)
                .frame(width: diameter * 0.20, height: diameter * 0.30)
                .offset(y: diameter * 0.16)
        }
        .frame(width: diameter, height: diameter)
    }

    /// Beta only, and goes with the rest of Spotify — but a blank disc in the
    /// meantime is worse than twelve lines that get deleted together.
    private var spotify: some View {
        ZStack {
            Circle().fill(Color(red: 0.11, green: 0.73, blue: 0.33))
            Image(systemName: "waveform")
                .font(.system(size: diameter * 0.46, weight: .semibold))
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
    /// False while any distillation is running — the same guard the badges take.
    /// Two at once would have them writing over each other's records.
    var isEnabled: Bool = true
    /// Re-open this branch's picker, to distil it again or to add its second app.
    ///
    /// **A finished bar was the only part of this screen that did nothing.** The
    /// badge on the plant re-distils, the prompt card's button connects the next
    /// branch, and the bar naming a branch you have already connected — the most
    /// obvious thing to press when you want that branch again — was decoration.
    /// Music's two apps make it worse: somebody who connected Apple Music and
    /// later wants Spotify has the bar for exactly that in front of them.
    var onTap: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            // **Every label takes the width of the widest one**, so the app
            // marks beside them form a column instead of landing wherever their
            // own text happens to end. Several of these stack up, and four marks
            // at four different x read as a mistake rather than as a list.
            //
            // A `ZStack` is the whole mechanism: it takes the size of its
            // largest child, so the column lands on "Lifestyle" — the longest of
            // the four — on its own. No measured constant, and it stays right if
            // a fifth modality arrives with a longer name.
            //
            // The alternative, a fixed `minWidth`, would be wrong at every text
            // size but the one it was measured at. This app mixes two font
            // systems and only one of them scales; hardcoding a width here is
            // exactly the class of thing the Dynamic Type axis of the layout
            // audit exists to catch.
            ZStack(alignment: .leading) {
                ForEach(Modality.allCases) { other in
                    Text("Connected to \(other.label)")
                        .hidden()
                        .accessibilityHidden(true)
                }
                Text("Connected to \(modality.label)")
            }
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(GardenPalette.ink)
            .lineLimit(1)
            // The sizing copies must not be squeezed by a narrow row, or the
            // column they define would move with whichever label is real.
            .fixedSize(horizontal: true, vertical: false)

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
        // The whole bar, including the gap between the label and the marks: a
        // row that only answers on its text reads as unreliable rather than as
        // untappable.
        .contentShape(RoundedRectangle(cornerRadius: 18))
        // `onTapGesture` rather than a `Button`, for the reasons `BadgeTap`
        // gives: a button styles and animates its label, and the garden carries
        // a pull-up `DragGesture` during onboarding that a button's own
        // recogniser would compete for. A bar that swallowed the pull would
        // cost more than the shortcut is worth.
        .onTapGesture {
            guard isEnabled else { return }
            onTap()
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Connected to \(modality.label)")
        .accessibilityHint("Opens the list of apps for this branch, to distil it again")
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

/// Makes a badge on the plant do what its row in the stack below does.
///
/// The badges were decoration — the only way to connect or re-distil a source
/// was the button in the prompt card, and the icon *for* that source, sitting
/// on the plant it grew, did nothing when pressed. Tapping the thing you mean
/// is the shorter route, and it is the one people try first.
///
/// `onTapGesture` rather than wrapping the badge in a `Button`, for two
/// reasons. A button styles and animates its label, which would fight the
/// badge's own bob and its arrival spring. And the garden carries a pull-up
/// `DragGesture` during onboarding — a tap gesture leaves drags alone, where a
/// button's own gesture recogniser competes for them, and a badge that
/// swallowed the pull would be a worse loss than a shortcut is a gain.
struct BadgeTap: ViewModifier {
    let modality: Modality
    let isEnabled: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        content
            // The whole disc, not just the glyph and the ring: the badge is
            // mostly empty space and a tap that only lands on the note would
            // read as the icon being unreliable rather than untappable.
            .contentShape(Circle())
            .onTapGesture {
                guard isEnabled else { return }
                action()
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Connect \(modality.label)")
            .accessibilityHint("Opens the list of apps for this branch")
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
    ///
    /// **Passed in rather than fixed, and that is a bug fix.** It was a hard 48
    /// while every *position* around it — `cotyledonBadge`, `shootBadge`, the
    /// leaves, the branch strokes — scales with the garden square. The square is
    /// height-limited on every iPhone, so it is 127pt on an SE, 258pt on a 17
    /// Pro and 339pt on a Pro Max: a 2.7× range. A constant diameter across that
    /// made the badge 37.7% of the plant on the small phone against 14.2% on the
    /// big one, and on the SE the four badges overlapped each other and sat on
    /// the leaves. Measured, not guessed — the same pair of badges is 88pt apart
    /// on a 17 Pro and 43.5pt apart on an SE, against a 48pt badge.
    ///
    /// See `GrowProfileView.badgeDiameter(in:)` for the ratio and where it comes
    /// from.
    var diameter: CGFloat = 48

    /// Everything else the badge is made of follows the diameter, so one number
    /// scales the whole thing. These are the fractions the tuned 48pt badge had:
    /// a 3pt ring and a 6pt bob.
    private var ringWidth: CGFloat { diameter * (3.0 / 48.0) }
    private var bob: CGFloat { diameter * (6.0 / 48.0) }

    /// One flat gold, not a gradient: any variation around the rim reads as a
    /// glint travelling as the badge bobs, which is the shimmer this is meant to
    /// be free of. Brighter and more saturated than `GardenPalette.gold`, which
    /// is a muted khaki — right for text on parchment, dull as a ring.
    /// Now `GardenPalette.badgeGold`, because the chat bubble uses the same
    /// gold and two copies of one colour drift apart the first time either moves.
    private static let ringGold = GardenPalette.badgeGold

    /// Whether the garden is the tab on screen.
    ///
    /// The clock below runs on the display refresh, and every tab in `AppShell`
    /// stays mounted — so without this the badges would redraw sixty times a
    /// second behind Explore, Chat and the dashboard, forever.
    var isFloating = true

    /// One full up-and-down, in seconds. Slow enough to be ambient: a bob you
    /// can time is a progress indicator, and nothing here is in progress.
    private static let bobPeriod: Double = 5.2

    var body: some View {
        // **A clock, not `withAnimation(.repeatForever())`.**
        //
        // The bob used to be a repeating animation started in `onAppear`, and
        // any *other* explicit transaction touching this view replaced it —
        // permanently, because nothing restarted it. The badges' own arrival is
        // one: `hasBadgeArrived` flips inside a `withAnimation(.spring(…))`, so
        // a badge stopped floating a moment after it appeared. The filling
        // progress ring did it too. What was left looked arbitrary — whichever
        // badge had most recently escaped a transaction was the one still
        // moving, which is exactly how it was reported.
        //
        // Derived from the date, the offset is a pure function of time. There is
        // no animation to interrupt, so nothing can interrupt it.
        TimelineView(.animation(paused: !isFloating)) { context in
            badge.offset(y: offset(at: context.date))
        }
    }

    private var badge: some View {
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
    }

    /// A sine of the wall clock — **the same one for every badge, with no phase
    /// offset**, so they rise and fall together.
    ///
    /// Staggering them was tried and is wrong. The argument for it was that the
    /// old per-badge `onAppear` repeats were never synchronised, so a shared
    /// clock would be a change in character; but what it actually looked like
    /// was four things drifting independently, which reads as the badges being
    /// loose. In step they read as one plant breathing, which is what they hang
    /// off.
    ///
    /// A shared clock is also what keeps them together over a long session: the
    /// offset is computed from the date, not accumulated, so nothing drifts.
    private func offset(at date: Date) -> CGFloat {
        let turns = date.timeIntervalSinceReferenceDate / Self.bobPeriod
        return -bob * CGFloat(sin(turns * 2 * .pi))
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
    /// Hands the chosen source back and closes; **it does not start the
    /// distillation itself.**
    ///
    /// It used to do both, in that order — distil, then dismiss — which put the
    /// system permission request in the air while this sheet was still on
    /// screen being torn down. For most sources that is merely untidy: an alert
    /// queues. For Apple Health it is a plausible cause of the failure two
    /// testers reported, because HealthKit does not draw its own sheet — it
    /// hosts a remote view from `com.apple.HealthPrivacyService`, which has to
    /// be *presented* over whatever is topmost, and what was topmost was a
    /// modal in mid-dismissal. HealthKit's answer to not being able to present
    /// is no refusal, no wait, and no sheet.
    ///
    /// `HealthKitDistiller.waitUntilActive` cannot cover this: it tests
    /// `applicationState`, which stays `.active` throughout a sheet dismissal.
    /// It can see the app being backgrounded and is blind to our own modal.
    var onChoose: (String) -> Void = { _ in }

    /// Only what this device can actually offer — see `SourceAvailability`,
    /// which hides the two Apple frameworks where they cannot work rather than
    /// hiding whatever app happens not to be installed.
    private var sources: [String] { SourceAvailability.sources(for: modality) }

    /// The line under a source's name, for the one case where tapping it leads
    /// somewhere the name does not prepare you for.
    ///
    /// **Health only, and it stays a dead end without it.** Its sheet opens with
    /// every category off and keeps "Allow" *disabled* until one is switched on,
    /// so a tester tapped Allow, nothing happened, and reported the app frozen.
    /// Nothing can be drawn over that sheet and no message afterwards reaches
    /// somebody who never got past it, so it has to be said here or not at all.
    ///
    /// Podcasts had one describing what it reads, and it is gone: nothing about
    /// tapping it fails or surprises. That is the bar — a note earns its place
    /// by preventing a dead end, not by explaining a source.
    static func note(forSource source: String) -> String? {
        switch source {
        case "health": return "Switch on what you'll share — or Turn On All — then Allow."
        default: return nil
        }
    }

    /// The height the sheet asks for: the header, plus a row each.
    ///
    /// Computed rather than fixed at 280, which was sized for music's two rows
    /// and left a single-app modality sitting in a half-empty sheet.
    var detentHeight: CGFloat {
        let rows = CGFloat(max(sources.count, 1)) * 56
        // Every row carrying a second line needs its own room — see
        // `note(forSource:)`. Counted rather than assumed because the detent is
        // a *fixed* height: a row that outgrows its 56 points is simply cropped,
        // and the cropped part would be the one sentence the row exists to add.
        // Derived from the sources actually shown, so a third note later cannot
        // silently overflow the way a hardcoded count would.
        let notes = CGFloat(sources.filter { Self.note(forSource: $0) != nil }.count) * 18
        return 116 + rows + notes + (sources.isEmpty ? 12 : 0)
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
            onChoose(source)
        } label: {
            HStack(spacing: 12) {
                // `Modality.icon(forSource:)` rather than a local guess — it
                // already knows every source's mark, and the badges on the plant
                // draw from the same place, so an app looks the same everywhere.
                Image(systemName: Modality.icon(forSource: source))
                    .font(.system(size: 17))
                    .foregroundStyle(GardenPalette.gold)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(Modality.displayName(forSource: source))
                        .font(.system(size: 17))
                        .foregroundStyle(GardenPalette.ink)

                    // **Two sources need a sentence before they are tapped, and
                    // for the same underlying reason**: what happens next is not
                    // what somebody would assume, and by the time it happens the
                    // app can no longer say anything.
                    //
                    // Health, because its sheet opens with every category off
                    // and keeps "Allow" *disabled* until one is turned on —
                    // verified on a clean sheet, not inferred. Tap it and
                    // nothing happens, which reads as a frozen app, and that is
                    // exactly how it was reported. Nothing can be drawn over
                    // that sheet, and no message afterwards reaches somebody who
                    // never got past it.
                    //
                    // Podcasts, because the media library only holds
                    // **downloaded** episodes. Somebody who streams everything
                    // connects it and gets nothing, and an empty result that was
                    // never explained is the failure this project keeps paying
                    // for. Said here, "nothing found" is a fact about their
                    // downloads rather than a mystery.
                    //
                    // Music and Calendar get nothing: a single yes/no alert with
                    // no switches and no precondition, so a note would be noise.
                    if let note = Self.note(forSource: source) {
                        Text(note)
                            .font(.system(size: 12))
                            .foregroundStyle(GardenPalette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

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

/// The body of Apple Podcasts' figure: wide at the shoulders, tapering to a
/// rounded point.
///
/// A `Capsule` reads as a pill and loses the taper that makes the glyph a
/// person rather than a microphone — which is the whole difference between this
/// mark and the `mic.fill` it replaced.
private struct PodcastBody: Shape {
    func path(in rect: CGRect) -> Path {
        let topRadius = rect.width / 2
        let bottomRadius = rect.width * 0.32
        var path = Path()
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.minY + topRadius),
            radius: topRadius,
            startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.midX + bottomRadius, y: rect.maxY - bottomRadius),
            control: CGPoint(x: rect.maxX, y: rect.midY)
        )
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.maxY - bottomRadius),
            radius: bottomRadius,
            startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.minY + topRadius),
            control: CGPoint(x: rect.minX, y: rect.midY)
        )
        path.closeSubpath()
        return path
    }
}

/// The body of Google Calendar's mark: two smooth-edged trapeziums meeting at
/// their narrow ends, so the sides curve gently inward at the waist.
///
/// Measured at 0.655 of the tile wide at its widest and 0.606 at the waist — a
/// 7% draw-in. Deeper than that and it reads as an hourglass rather than as the
/// slight fold the icon actually has.
private struct GoogleCalendarBody: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let r = w * 0.20                 // corner rounding
        let waist = w * 0.037            // half of the 7% draw-in
        var p = Path()
        p.move(to: CGPoint(x: r, y: 0))
        p.addLine(to: CGPoint(x: w - r, y: 0))
        p.addQuadCurve(to: CGPoint(x: w, y: r), control: CGPoint(x: w, y: 0))
        // Right side, curving in to the waist and back out.
        p.addQuadCurve(to: CGPoint(x: w, y: h - r), control: CGPoint(x: w - waist * 2, y: h / 2))
        p.addQuadCurve(to: CGPoint(x: w - r, y: h), control: CGPoint(x: w, y: h))
        p.addLine(to: CGPoint(x: r, y: h))
        p.addQuadCurve(to: CGPoint(x: 0, y: h - r), control: CGPoint(x: 0, y: h))
        p.addQuadCurve(to: CGPoint(x: 0, y: r), control: CGPoint(x: waist * 2, y: h / 2))
        p.addQuadCurve(to: CGPoint(x: r, y: 0), control: CGPoint(x: 0, y: 0))
        p.closeSubpath()
        return p
    }
}

/// The weaker-blue trapezium above it: narrow at the top, widening to the
/// bottom, where the body's own wide edge covers the join.
private struct GoogleCalendarCap: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        // 0.502 against 0.655 at its widest — measured off the icon.
        let inset = w * (1 - 0.502 / 0.655) / 2
        let r = w * 0.16
        var p = Path()
        p.move(to: CGPoint(x: inset + r, y: 0))
        p.addLine(to: CGPoint(x: w - inset - r, y: 0))
        p.addQuadCurve(to: CGPoint(x: w - inset, y: r), control: CGPoint(x: w - inset, y: 0))
        p.addLine(to: CGPoint(x: w, y: h))
        p.addLine(to: CGPoint(x: 0, y: h))
        p.addLine(to: CGPoint(x: inset, y: r))
        p.addQuadCurve(to: CGPoint(x: inset + r, y: 0), control: CGPoint(x: inset, y: 0))
        p.closeSubpath()
        return p
    }
}
