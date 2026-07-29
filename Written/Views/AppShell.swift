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

    /// Distill, not Explore. Someone arriving here has just finished growing
    /// their plant, and the first thing they should see is the thing they made.
    /// Reaching Explore is a deliberate move — the button on the profile
    /// preview, or the bar.
    @State private var tab: MainTab = .distill

    /// True while the garden's pull-up is being dragged. The bar sits exactly
    /// where that gesture starts, and two things reacting to one drag is worse
    /// than one of them being briefly absent.
    @State private var isGesturing = false

    var body: some View {
        ZStack(alignment: .bottom) {
            GardenPalette.parchment.ignoresSafeArea()

            page(.explore) { DiscoveryView() }
            page(.wish) { ComingSoonView(tab: .wish, note: "A bottle you can put something in, and someone else can find.") }
            page(.chat) { ComingSoonView(tab: .chat, note: "Where a commonality turns into a conversation.") }
            page(.distill) {
                HomeView(
                    onSignOut: onSignOut,
                    onExplore: { withAnimation(.easeInOut(duration: 0.45)) { tab = .explore } },
                    onGesture: { isGesturing = $0 }
                )
            }
            page(.settings) { ComingSoonView(tab: .settings, note: "Your account, your data, and what leaves this phone.") }

            MainTabBar(selection: $tab, isHidden: isGesturing)
                .padding(.bottom, 6)
        }
#if DEBUG
        // `-tab explore` on the launch line; see `DebugLaunch`.
        .onAppear {
            guard let name = DebugLaunch.forcedTab, DebugLaunch.firesOnce("tab") else { return }
            switch name {
            case "explore":  tab = .explore
            case "wish":     tab = .wish
            case "chat":     tab = .chat
            case "settings": tab = .settings
            default:         break
            }
        }
#endif
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
