import SwiftUI

/// The dashboard and the profile preview, and the move between them.
///
/// They are stacked rather than pushed or presented: confirming on the dashboard
/// slides it *off the top* of the screen, accelerating as it goes, and the
/// preview is simply what was underneath all along. A navigation push would
/// slide in from the trailing edge, and a sheet would rise over the dashboard
/// and leave it visible behind — neither reads as leaving it.
///
/// **The garden used to live here too**, and reached the dashboard by being
/// pulled up off the screen. The dashboard is a tab now, so that gesture and the
/// arrow advertising it are gone and the garden no longer moves at all. What is
/// left is the one vertical move that remains: dashboard to preview.
struct DashboardTab: View {
    @ObservedObject var viewModel: DistillViewModel

    /// Back to the garden — a different tab now, rather than a layer underneath.
    var onBack: () -> Void = {}
    /// "Explore" on the preview: through to the discovery feed.
    var onExplore: () -> Void = {}
    /// Back to sign-in, for `RootView`.
    var onSignOut: () -> Void = {}

    @State private var lift: CGFloat = 0
    @State private var isShowingProfiles = false

    /// Accelerating away, and easing back: `easeIn` spends its speed at the end
    /// of the travel, so the dashboard gathers pace as it leaves rather than
    /// gliding out at a constant rate.
    private static let leaving: Animation = .easeIn(duration: 0.5)
    private static let returning: Animation = .easeOut(duration: 0.45)

    var body: some View {
        GeometryReader { geometry in
            // Past the top edge, safe areas included, or the dashboard's last
            // sliver hangs at the top of the screen once the animation settles.
            let travel = geometry.size.height
                + geometry.safeAreaInsets.top
                + geometry.safeAreaInsets.bottom
                + 40

            ZStack {
                ProfilePreviewView(
                    viewModel: viewModel,
                    onBack: {
                        withAnimation(Self.returning) { lift = 0 }
                        isShowingProfiles = false
                    },
                    onExplore: onExplore
                )

                DashboardView(
                    viewModel: viewModel,
                    onBack: onBack,
                    onConfirm: {
                        withAnimation(Self.leaving) { lift = -travel }
                        isShowingProfiles = true
                    },
                    // Everything this device remembers is cleared here, before
                    // the session is dropped upstream — the view model owns the
                    // OAuth services, so this is the only place that can.
                    onSignOut: {
                        viewModel.signOutLocalState()
                        onSignOut()
                    }
                )
                .offset(y: lift)
                // Offscreen but still mounted, so it must stop taking taps the
                // moment it starts leaving.
                .allowsHitTesting(!isShowingProfiles)
            }
#if DEBUG
            // `-screen profiles` on the launch line; see `DebugLaunch`. The
            // dashboard itself is now `-tab dashboard` and needs no delay.
            .onAppear {
                guard DebugLaunch.opensProfiles, DebugLaunch.firesOnce("screen") else { return }
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(DebugLaunch.dashboardDelay * 1_000_000_000))
                    withAnimation(Self.leaving) { lift = -travel }
                    isShowingProfiles = true
                }
            }
#endif
        }
    }
}
