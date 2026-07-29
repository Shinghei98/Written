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

            page(.explore) { DiscoveryView() }
            page(.wish) { ComingSoonView(tab: .wish, note: "A bottle you can put something in, and someone else can find.") }
            page(.chat) { ComingSoonView(tab: .chat, note: "Where a commonality turns into a conversation.") }
            page(.distill) {
                GrowProfileView(
                    viewModel: viewModel,
                    isOnboarding: isOnboarding,
                    // Only ever used during onboarding — `canReveal` is false
                    // afterwards, so these are never called in regular use.
                    onRevealDrag: { gardenLift = -$0 },
                    onRevealEnd: { committed in
                        withAnimation(.easeInOut(duration: 0.4)) {
                            gardenLift = 0
                            if committed { tab = .dashboard }
                        }
                    }
                )
                .offset(y: gardenLift)
            }
            page(.dashboard) {
                DashboardTab(
                    viewModel: viewModel,
                    onBack: { withAnimation(.easeInOut(duration: 0.35)) { tab = .distill } },
                    onExplore: finishOnboarding,
                    onSignOut: onSignOut,
                    isVisible: tab == .dashboard,
                    isOnboarding: isOnboarding
                )
            }

            if !isOnboarding {
                MainTabBar(selection: $tab)
                    .padding(.bottom, MainTabBar.bottomInset)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
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
        content()
            .opacity(tab == which ? 1 : 0)
            .allowsHitTesting(tab == which)
            .accessibilityHidden(tab != which)
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
