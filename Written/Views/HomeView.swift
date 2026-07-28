import SwiftUI

/// The garden and the dashboard, and the move between them.
///
/// They are stacked rather than pushed or presented: "View Dashboard" slides the
/// garden *off the top* of the screen, accelerating as it goes, and the
/// dashboard is simply what was underneath all along. A navigation push would
/// slide in from the trailing edge, and a sheet would rise over the garden and
/// leave it visible behind — neither reads as leaving the garden behind.
///
/// The garden stays mounted under the offset. Tearing it down would replay the
/// plant's whole growth on the way back, and it holds the animation state the
/// badges and the stem are pinned to.
struct HomeView: View {
    /// Back to sign-in, for `RootView`. Reached from the garden's debug header.
    var onSignOut: () -> Void = {}

    /// One distillation, two screens: the view model is owned here so the
    /// dashboard reads exactly what the garden grew.
    @StateObject private var viewModel = DistillViewModel()

    /// How far each screen has slid off the top. The stack is garden over
    /// dashboard over profiles, and each layer leaves the same way the one
    /// before it did — one move learned once.
    @State private var lift: CGFloat = 0
    @State private var dashboardLift: CGFloat = 0
    @State private var isShowingDashboard = false
    @State private var isShowingProfiles = false

    /// Accelerating away, and easing back: `easeIn` spends its speed at the end
    /// of the travel, so the garden gathers pace as it leaves rather than
    /// gliding out at a constant rate.
    private static let leaving: Animation = .easeIn(duration: 0.5)
    private static let returning: Animation = .easeOut(duration: 0.45)

    var body: some View {
        GeometryReader { geometry in
            // Past the top edge, safe areas included, or the garden's last
            // sliver hangs at the top of the screen once the animation settles.
            let travel = geometry.size.height
                + geometry.safeAreaInsets.top
                + geometry.safeAreaInsets.bottom
                + 40

            ZStack {
                ProfilePreviewView(viewModel: viewModel) {
                    withAnimation(Self.returning) { dashboardLift = 0 }
                    isShowingProfiles = false
                }

                DashboardView(
                    viewModel: viewModel,
                    onBack: {
                        withAnimation(Self.returning) { lift = 0 }
                        isShowingDashboard = false
                    },
                    onConfirm: {
                        withAnimation(Self.leaving) { dashboardLift = -travel }
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
                .offset(y: dashboardLift)
                .allowsHitTesting(!isShowingProfiles)

                // Deliberately without an `onSignOut`. Signing out has to clear
                // this device first — `viewModel.signOutLocalState()` above —
                // and a second route to `onSignOut` that skipped it would drop
                // the session while leaving the distillation on disk.
                GrowProfileView(
                    viewModel: viewModel,
                    onViewDashboard: { open(travel) }
                )
                // The garden rides the dashboard's exit too: it sits above it in
                // the stack, so without this it would be left hanging over the
                // profiles when the dashboard leaves.
                .offset(y: lift + dashboardLift)
                // Offscreen but still mounted, so it must stop taking taps the
                // moment it starts leaving.
                .allowsHitTesting(!isShowingDashboard)
            }
#if DEBUG
            // `-screen dashboard` on the launch line; see `DebugLaunch`.
            .onAppear {
                guard DebugLaunch.opensDashboard, DebugLaunch.firesOnce("screen") else { return }
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(DebugLaunch.dashboardDelay * 1_000_000_000))
                    open(travel)
                    guard DebugLaunch.opensProfiles else { return }
                    // Long enough for the dashboard's own slide to finish, or
                    // the two moves collide and neither reads.
                    try? await Task.sleep(nanoseconds: 1_400_000_000)
                    withAnimation(Self.leaving) { dashboardLift = -travel }
                    isShowingProfiles = true
                }
            }
#endif
        }
    }

    private func open(_ travel: CGFloat) {
        withAnimation(Self.leaving) { lift = -travel }
        isShowingDashboard = true
    }
}

#Preview {
    HomeView()
}
