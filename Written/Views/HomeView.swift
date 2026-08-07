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
    @Binding var photos: [PickedMedia?]

    /// Back to the garden — a different tab now, rather than a layer underneath.
    var onBack: () -> Void = {}
    /// "Explore" on the preview: through to the discovery feed.
    var onExplore: () -> Void = {}
    /// Back to sign-in, for `RootView`.
    var onSignOut: () -> Void = {}

    /// Whether this tab is the one on screen.
    ///
    /// The preview slides over the dashboard and this view stays mounted, so
    /// without resetting on arrival the profile tab would reopen wherever it was
    /// left — and where it was left, during onboarding, is the preview. Tapping
    /// the profile icon has to land on the dashboard every time.
    var isVisible = true

    /// Passed through to the dashboard, which offers different ways out of
    /// itself depending on which half of the app this is.
    var isOnboarding = false

    @State private var lift: CGFloat = 0
    @State private var isShowingProfiles = false

    /// `-solo 1`, the same flag `AppShell.page` reads. Constant-folded away
    /// outside DEBUG, so the two branches above cost a release build nothing.
    private var isAuditingOneLayer: Bool {
#if DEBUG
        DebugLaunch.auditsOneTabAtATime
#else
        false
#endif
    }

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
                // Under `-solo 1` only the layer being looked at is built.
                //
                // These two are stacked, not swapped: the preview sits at full
                // frame *behind* the dashboard the whole time, and the dashboard
                // slides off it. That is right for the animation and wrong for an
                // audit — XCUITest reads the covered layer as happily as the
                // visible one, so a dump of the dashboard also contained "People
                // you will see" and "Meet someone who understands your world",
                // and every pair of those was a false overlap. Exactly the
                // problem `AppShell.page` has with its five tabs, one level down.
                if !isAuditingOneLayer || isShowingProfiles {
                    ProfilePreviewView(
                        viewModel: viewModel,
                        onBack: {
                            withAnimation(Self.returning) { lift = 0 }
                            isShowingProfiles = false
                        },
                        onExplore: onExplore,
                        isOnboarding: isOnboarding
                    )
                    // **Hidden until the dashboard actually starts to move.**
                    //
                    // It sits at full frame behind the dashboard the whole time,
                    // which is what makes the slide work — but it also means the
                    // *lighter* of the two views is ready first. Arriving on
                    // this tab therefore showed "People you will see" for a
                    // frame or two before the dashboard finished laying out its
                    // photos, biographics and cards on top. Exactly the
                    // flash-of-the-wrong-screen that `RootView` documents for
                    // sign-in, one level down.
                    //
                    // Keyed on `lift` rather than on `isShowingProfiles` alone:
                    // the reveal begins the instant the offset animation starts,
                    // and waiting for the flag would clip the first frames of it.
                    // Opacity rather than a condition, so the view stays mounted
                    // and keeps its state across the slide.
                    .opacity(isShowingProfiles || lift != 0 ? 1 : 0)
                    .allowsHitTesting(isShowingProfiles)
                }

                if !isAuditingOneLayer || !isShowingProfiles {
                    DashboardView(
                        viewModel: viewModel,
                        photos: $photos,
                        onBack: onBack,
                        onConfirm: {
                            withAnimation(Self.leaving) { lift = -travel }
                            isShowingProfiles = true
                        },
                        // Everything this device remembers is cleared here,
                        // before the session is dropped upstream — the view model
                        // owns the OAuth services, so this is the only place that
                        // can.
                        onSignOut: {
                            viewModel.signOutLocalState()
                            onSignOut()
                        },
                        isOnboarding: isOnboarding,
                        isVisible: isVisible
                    )
                    .offset(y: lift)
                    // Offscreen but still mounted, so it must stop taking taps
                    // the moment it starts leaving.
                    .allowsHitTesting(!isShowingProfiles)
                }
            }
            .onChange(of: isVisible) { visible in
                guard visible else { return }
                lift = 0
                isShowingProfiles = false
            }
            // The district row is meant to be there without being asked for, so
            // the fix is taken when this screen is first *looked at* — not when
            // it is first mounted, which `AppShell` does for all five tabs at
            // launch. `.task(id:)` re-runs on the change and
            // `captureLocationIfNeeded` is idempotent, so arriving here twice
            // costs nothing and a decline is never re-asked.
            //
            // Moved from `DashboardView` because a permission alert raised from
            // an unopened tab does not merely startle: it owns the screen, and
            // HealthKit — which presents its sheet out of another process —
            // cannot draw over it and times out instead. See the note there.
            .task(id: isVisible) {
                guard isVisible else { return }
                viewModel.captureLocationIfNeeded()
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
