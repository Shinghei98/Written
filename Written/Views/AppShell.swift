import SwiftUI

/// The app once onboarding is behind you: five tabs and a bar that floats over
/// all of them.
///
/// Every tab stays mounted. A `switch` would be less code and would tear the
/// garden down on every trip to Explore — replaying the plant's whole growth on
/// the way back and losing the animation state its badges and stem are pinned
/// to, which is the same reason `HomeView` keeps the garden alive under the
/// dashboard rather than swapping it out.
struct AppShell: View {
    /// Bound from `RootView`, which owns them: the photo page runs before this
    /// view exists, so the array cannot belong to the view model it feeds.
    @Binding var photos: [PickedMedia?]

    var onSignOut: () -> Void = {}

    /// One distillation, every tab. Owned here rather than by a tab, because the
    /// garden and the dashboard are now siblings — they used to be layers of one
    /// screen, which is what let that screen own it.
    @StateObject private var viewModel = DistillViewModel()

    /// Distill, not Explore. Someone arriving here has just finished growing
    /// their plant, and the first thing they should see is the thing they made.
    /// Reaching Explore is a deliberate move — the button on the profile
    /// preview, or the bar.
    @State private var tab: MainTab = .distill

    /// Which half of the app this is.
    ///
    /// Onboarding is a line, not a place you navigate: sign in, name, photos,
    /// grow the plant, meet the first person. A tab bar during it would offer
    /// four exits from a sequence whose whole point is that it has one. So the
    /// bar is absent until "Explore" is tapped, and the garden keeps the arrow
    /// and the pull-up that were its own way onward.
    ///
    /// Read once into state rather than observed: the answer only changes at the
    /// single moment `finishOnboarding` runs, and it decides the whole shape of
    /// the screen, so it should not be able to shift under a redraw.
    @State private var isOnboarding = SupabaseAuth.shared.onboardingStep != .done

    var body: some View {
        ZStack(alignment: .bottom) {
            GardenPalette.parchment.ignoresSafeArea()

            page(.explore) { DiscoveryView(viewModel: viewModel) }
            page(.wish) { ComingSoonView(tab: .wish, note: "A bottle you can put something in, and someone else can find.") }
            page(.chat) {
                ChatView(viewModel: viewModel, isVisible: tab == .chat, hidesTabBar: $isThreadOpen)
            }
            // **Before the garden, not after it.** The pull-up during onboarding
            // slides the garden off to reveal this underneath, and a ZStack
            // draws later children on top — so in the old order making the
            // dashboard visible mid-drag would have covered the very page being
            // pulled. Z-order between these two matters only while both are on
            // screen, which is only during that drag.
            page(.dashboard) {
                DashboardTab(
                    viewModel: viewModel,
                    photos: $photos,
                    onBack: { withAnimation(.easeInOut(duration: 0.35)) { tab = .distill } },
                    onExplore: finishOnboarding,
                    onSignOut: onSignOut,
                    isVisible: tab == .dashboard,
                    isOnboarding: isOnboarding
                )
            }
            page(.distill) {
                GrowProfileView(
                    viewModel: viewModel,
                    isOnboarding: isOnboarding,
                    isVisible: tab == .distill,
                    // Only ever used during onboarding — `canReveal` is false
                    // afterwards, so these are never called in regular use.
                    onRevealDrag: { gardenLift = -$0 },
                    onRevealEnd: { committed in
                        guard committed else {
                            withAnimation(.easeInOut(duration: 0.4)) { gardenLift = 0 }
                            return
                        }
                        // Carry it all the way off, rather than dropping it back
                        // to zero as this used to. That was invisible while the
                        // dashboard only appeared at the end — but now that it
                        // is there from the first millimetre of the drag, a
                        // garden returning to its place would read as the pull
                        // having failed, at the exact moment it succeeded.
                        withAnimation(.easeInOut(duration: 0.34)) {
                            gardenLift = -revealTravel
                        }
                        // Then swap, once it has left. Both changes land in one
                        // tick and neither can be seen: the garden is already
                        // off-screen when it is hidden, and the offset it
                        // returns to is the offset of a hidden view.
                        //
                        // **`gardenLift` is zero at rest, always.** Leaving it
                        // parked off-screen would be one fewer moving part here
                        // and a trap everywhere else — every future route out of
                        // the dashboard would have to remember to reset it, and
                        // the one that forgot would show an empty garden tab.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) {
                            tab = .dashboard
                            gardenLift = 0
                        }
                    }
                )
                .offset(y: gardenLift)
            }

            if !isOnboarding {
                MainTabBar(selection: $tab, isHidden: isThreadOpen)
                    .padding(.bottom, MainTabBar.bottomInset)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // Measured, not guessed, and in a `background` so it costs no layout
        // height — the one rule the bottom of this screen cannot bend, since
        // `promptsReserve` is what the plant is positioned against. A constant
        // tall enough for a Pro Max would leave an SE's garden gone long before
        // the animation ended; one sized for an SE would strand a Pro Max's
        // partway off. The slack covers the safe areas the ZStack excludes.
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        revealTravel = proxy.size.height + 120
#if DEBUG
                        // `-reveal 0.5` on the launch line; see `DebugLaunch`.
                        if let fraction = DebugLaunch.revealFraction, isOnboarding {
                            gardenLift = -proxy.size.height * CGFloat(fraction)
                        }
#endif
                    }
                    .onChange(of: proxy.size.height) { revealTravel = $0 + 120 }
            }
        )
        // The onboarding sliders reach the record system here, because this is
        // the first moment a view model exists to put them in — they are
        // answered two screens before this view is built. Idempotent, and
        // `restoreFromServer` calls it again once the server's version lands.
        .task { viewModel.adoptStoredCommunicationStyle() }
        // One placement for every tab, rather than five that can disagree — the
        // same argument `isOnboarding` makes for owning the bar here.
        //
        // An overlay, so it costs no layout height and the garden underneath
        // does not move when it appears. `safeAreaInset` reads more naturally
        // and is precisely the modifier that would break `promptsReserve`.
        //
        // Offline first when both apply: "you're offline" explains the refusal
        // that follows it, and a PostgREST message underneath would only be the
        // same fact in worse words.
        .statusBanner(
            reachability.isOnline ? viewModel.biographicsError : "You're offline. Changes won't save.",
            isWarning: true
        )
        // A refusal is a moment, not a state — unlike being offline, which ends
        // when it ends. Left up, it would still be there long after the row it
        // referred to had scrolled away.
        .onChange(of: viewModel.biographicsError) { message in
            guard message != nil else { return }
            Task {
                // Something just failed, which is the one moment worth spending
                // a request to find out whether the connection is real — the
                // path monitor calls a joined-but-dead network "satisfied", so
                // without this the offline banner stays hidden in exactly the
                // situation it was built for.
                await reachability.verify()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard viewModel.biographicsError == message else { return }
                viewModel.biographicsError = nil
            }
        }
#if DEBUG
        // `-tab explore` on the launch line; see `DebugLaunch`.
        .onAppear {
            guard let name = DebugLaunch.forcedTab, DebugLaunch.firesOnce("tab") else { return }
            switch name {
            case "explore":  tab = .explore
            case "wish":     tab = .wish
            case "chat":     tab = .chat
            case "dashboard": tab = .dashboard
            default:         break
            }
        }
#endif
    }

    /// How far the garden has been pulled up, during onboarding only. The
    /// dashboard is a sibling tab rather than a layer beneath, so this is the
    /// garden moving rather than a reveal of anything.
    @State private var gardenLift: CGFloat = 0

    /// How far the garden must travel to be entirely gone. Set from the shell's
    /// own height; the initial value only stands for the frame before that
    /// arrives, and is generous rather than accurate on purpose — too far is
    /// invisible here, too short leaves a strip of the garden hanging.
    @State private var revealTravel: CGFloat = 1200

    /// Whether a conversation is covering the Chat tab.
    ///
    /// The bar draws *over* every page, so a thread's compose field would sit
    /// underneath it — and a bar offering four ways out of a conversation is the
    /// same mistake as a bar during onboarding, one level down. `MainTabBar.isHidden`
    /// already exists for "another gesture owns the bottom of the screen"; this is
    /// the second thing that does. Owned here rather than by `ChatView` for the
    /// reason `isOnboarding` is: the thing that hides the bar and the bar itself
    /// must not be able to disagree.
    @State private var isThreadOpen = false

    @ObservedObject private var reachability = Reachability.shared

    /// "Explore" on the profile preview: the one moment onboarding ends.
    ///
    /// The bar arrives and the garden gives up its arrow together, which is why
    /// both read the same flag rather than each deciding for itself.
    private func finishOnboarding() {
        SupabaseAuth.shared.markExplored()
        withAnimation(.easeInOut(duration: 0.45)) {
            isOnboarding = false
            tab = .explore
        }
    }

    /// Mounted always, shown when selected. `opacity` rather than `isHidden`
    /// because a hidden view still lays out, which is what keeps a tab's
    /// geometry stable while you are not looking at it.
    @ViewBuilder
    private func page<Content: View>(
        _ which: MainTab,
        @ViewBuilder content: () -> Content
    ) -> some View {
        // Under `-solo 1` the other four tabs are not built at all. The three
        // modifiers below are what normally hides them, and XCUITest honours
        // none of them — see `DebugLaunch.auditsOneTabAtATime`. This changes
        // nothing outside an audit run: in Release the flag compiles to `false`.
        if isAuditingOneTab && tab != which {
            EmptyView()
        } else {
            content()
                .opacity(isDrawn(which) ? 1 : 0)
                // Still the selected tab, not merely the drawn one. Mid-pull the
                // dashboard is visible but must not take a tap, or a finger
                // travelling up the screen could press a row it is only sliding
                // past — and the garden is the page the gesture belongs to.
                .allowsHitTesting(tab == which)
                .accessibilityHidden(tab != which)
        }
    }

    /// Whether this page has to be on screen this frame, which is not the same
    /// as whether it is the selected tab.
    ///
    /// For one moment it isn't: during onboarding the garden is pulled up off
    /// the dashboard, so both are visible while `tab` still says `.distill`.
    /// Keying visibility on the selected tab alone is what made that pull reveal
    /// bare parchment — the dashboard did not appear until the gesture committed
    /// and flipped the tab, which is precisely when the reveal was already over.
    ///
    /// The same shape of bug as `DashboardTab` hiding the profile preview until
    /// its slide began: a layer needed *during* a transition, gated on a flag
    /// that only moves at the end of it.
    private func isDrawn(_ which: MainTab) -> Bool {
        if tab == which { return true }
        return gardenLift != 0 && (which == .dashboard || which == .distill)
    }

    /// Constant-folded away outside DEBUG, so the branch above costs a release
    /// build nothing.
    private var isAuditingOneTab: Bool {
#if DEBUG
        DebugLaunch.auditsOneTabAtATime
#else
        false
#endif
    }
}

/// A tab that exists on the bar before it exists as a screen.
///
/// Deliberately not a blank page: the bar has five icons from the first build so
/// its geometry never shifts, and an icon that leads nowhere with no explanation
/// reads as a bug rather than as something unfinished.
struct ComingSoonView: View {
    let tab: MainTab
    let note: String

    var body: some View {
        ZStack {
            GardenPalette.parchment.ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: tab.icon)
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(GardenPalette.gold)
                Text(tab.label)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(GardenPalette.ink)
                Text(note)
                    .font(.system(size: 14))
                    .foregroundStyle(GardenPalette.muted)
                    .multilineTextAlignment(.center)
                Text("Not built yet")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(GardenPalette.gold)
                    .padding(.horizontal, 12)
                    .frame(height: 26)
                    .overlay { Capsule().strokeBorder(GardenPalette.gold.opacity(0.35), lineWidth: 1) }
                    .padding(.top, 4)
            }
            .padding(.horizontal, 44)
            .padding(.bottom, MainTabBar.overlayHeight)
        }
        .preferredColorScheme(.light)
    }
}
