import SwiftUI

/// The garden and the dashboard, and the move between them.
///
/// They are stacked rather than pushed or presented: "View profile" slides the
/// garden *off the top* of the screen, accelerating as it goes, and the
/// dashboard is simply what was underneath all along. A navigation push would
/// slide in from the trailing edge, and a sheet would rise over the garden and
/// leave it visible behind — neither reads as leaving the garden behind.
///
/// The garden stays mounted under the offset. Tearing it down would replay the
/// plant's whole growth on the way back, and it holds the animation state the
/// badges and the stem are pinned to.
struct HomeView: View {
    /// One distillation, two screens: the view model is owned here so the
    /// dashboard reads exactly what the garden grew.
    @StateObject private var viewModel = DistillViewModel()

    @State private var lift: CGFloat = 0
    @State private var isShowingDashboard = false

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
                DashboardView(viewModel: viewModel) {
                    withAnimation(Self.returning) { lift = 0 }
                    isShowingDashboard = false
                }

                GrowProfileView(viewModel: viewModel) {
                    open(travel)
                }
                .offset(y: lift)
                // Offscreen but still mounted, so it must stop taking taps the
                // moment it starts leaving.
                .allowsHitTesting(!isShowingDashboard)
            }
#if DEBUG
            // `-screen dashboard` on the launch line; see `DebugLaunch`.
            .onAppear {
                guard DebugLaunch.opensDashboard else { return }
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(DebugLaunch.dashboardDelay * 1_000_000_000))
                    open(travel)
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
