#if DEBUG
import SwiftUI

/// Launch-argument overrides for looking at the illustration from the command
/// line. Debug-only, and deliberately all in one file so it can be deleted in
/// one move.
///
/// Iterating on the plant used to mean editing `TreeSkeleton.make` to force a
/// stage, building, screenshotting, editing it back and building again — two
/// full builds per look. `simctl` can't tap the `↻` stepper, so there was no
/// other way in. Arguments beginning with `-` land in `UserDefaults`' argument
/// domain, which gives us one:
///
/// ```
/// xcrun simctl launch <device> com.written.datingapp -stage 3
/// xcrun simctl launch <device> com.written.datingapp -stages all
/// ```
enum DebugLaunch {

    /// Launch arguments describe the *launch*, not every appearance of a view.
    ///
    /// Views get rebuilt: signing out and back in makes a fresh `HomeView`, and
    /// its `onAppear` would read `-screen dashboard` a second time and slide
    /// away to the dashboard again — the garden flashing past on every sign-in.
    /// Each flag fires once per process.
    @MainActor private static var fired: Set<String> = []

    @MainActor
    static func firesOnce(_ flag: String) -> Bool {
        guard !fired.contains(flag) else { return false }
        fired.insert(flag)
        return true
    }
    /// `-stage N` → the screen as though the first N modalities were connected.
    /// 0 is the bare sprout, 4 the full plant.
    static var forcedStage: Int? {
        UserDefaults.standard.string(forKey: "stage").flatMap(Int.init)
    }

    /// `-stages all` → every illustrated stage at once, so comparing against
    /// the reference art costs one launch and one screenshot instead of five.
    static var showsAllStages: Bool {
        UserDefaults.standard.string(forKey: "stages") == "all"
    }

    /// `-reveal 1` → the garden with its page already ridden up, uncovering the
    /// Dashboard button.
    ///
    /// Same reason as everything else here: the reveal is a drag, `simctl` has
    /// no way to drag, and this machine has neither `idb` nor `fbsimctl`. Without
    /// it the raised layout can be reasoned about and not looked at, which is
    /// how the badge that turned out to be sitting on a leaf got shipped.
    static var startsRevealed: Bool {
        UserDefaults.standard.string(forKey: "reveal") == "1"
    }

    /// `-screen dashboard` → plays the move to the dashboard shortly after
    /// launch. It is otherwise only reachable by tapping "View Dashboard", and
    /// `simctl` cannot tap; screenshotting during the delay and after it covers
    /// both the transition and the screen it lands on.
    static var opensDashboard: Bool {
        ["dashboard", "profiles"].contains(UserDefaults.standard.string(forKey: "screen") ?? "")
    }

    /// `-screen profiles` → carries on past the dashboard to the profile
    /// previews, which are otherwise two taps in.
    static var opensProfiles: Bool {
        UserDefaults.standard.string(forKey: "screen") == "profiles"
    }

    /// How long the garden holds before it leaves, under `-screen dashboard`.
    static let dashboardDelay: Double = 1.2

    /// `-distill 1` → runs the preview distillation shortly after launch, so the
    /// choreography that only happens while one is running — the banner, the
    /// watering can, the badges' progress rings — can be screenshotted. It is
    /// the `↻` stepper's work, and `simctl` cannot tap it.
    static var playsDistillation: Bool {
        UserDefaults.standard.string(forKey: "distill") == "1"
    }

    /// Long enough for the plant to have settled first.
    static let distillDelay: Double = 2.5

    /// `-connect health` → run a *real* distillation of that source shortly
    /// after launch, permission sheet and all. `-distill` fakes one; this is the
    /// genuine path, for sources whose sheet can't be tapped from `simctl`.
    static var connectSource: String? {
        UserDefaults.standard.string(forKey: "connect")
    }

    /// `-edit artist` / `-edit channel` / `-edit sport` → open the dashboard with
    /// one entry of that kind already wobbling. `simctl` can send no long press,
    /// so this is the only way to screenshot the editing state.
    static var editTarget: String? {
        UserDefaults.standard.string(forKey: "edit")
    }

    /// `-pick music` / `-pick media` / `-pick lifestyle` → open that modality's
    /// source picker shortly after launch. The sheet is only reachable through
    /// a "Connect …" button, and `simctl` can send no tap.
    static var pickTarget: Modality? {
        switch UserDefaults.standard.string(forKey: "pick") {
        case "music": return .music
        case "media": return .media
        case "lifestyle": return .lifestyle
        default: return nil
        }
    }

    /// `-route name` / `-route photos` / `-route home` → open straight on that
    /// screen, standing in for a session that was force-quit there.
    ///
    /// The onboarding pages are otherwise only reachable by signing in with a
    /// real Apple account, which the simulator cannot do — so without this the
    /// "resume where you quit" routing could only ever be checked on a device.
    static var forcedRoute: String? {
        UserDefaults.standard.string(forKey: "route")
    }

    /// `-loading video` / `-loading photo` → hold the photo page in its loading
    /// state. Reaching it for real means choosing something in `PhotosPicker`,
    /// which `simctl` cannot tap, and the state is transient besides.
    static var pickLoading: String? {
        UserDefaults.standard.string(forKey: "loading")
    }

    /// `-scroll media` → open the dashboard already scrolled to that card.
    /// Cards below the fold are otherwise unscreenshottable: `simctl` can send
    /// no swipe, and the alternative — reordering the page for one look — is
    /// the source-patching this harness exists to avoid.
    static var scrollTarget: String? {
        UserDefaults.standard.string(forKey: "scroll")
    }
}

/// Every illustrated stage on one screen, two to a row.
///
/// Not a single row: at a fifth of the width each panel is too small to judge a
/// petiole angle on, which is the whole reason for looking.
struct StageSheet: View {
    private let stages = SeedlingStage.allCases

    var body: some View {
        GeometryReader { geometry in
            // Half the width, and the height that width implies — sized
            // explicitly because `SeedlingView` is aspect-fit, and a
            // `maxWidth: .infinity` frame proposes it an infinite width, which
            // collapses the whole sheet to nothing.
            let width = geometry.size.width / 2
            let height = min(width / SeedlingView.aspectRatio,
                             (geometry.size.height - 40) / CGFloat((stages.count + 1) / 2))

            // Rows derived rather than fixed at two: the sheet was hardcoded to
            // a 2x2 for four stages, so adding a fifth would have dropped it
            // silently — the one failure this harness cannot afford, since its
            // whole job is showing what a change did.
            let rows = (stages.count + 1) / 2
            VStack(spacing: 14) {
                ForEach(0..<rows, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(0..<2, id: \.self) { column in
                            let index = row * 2 + column
                            if index < stages.count {
                                panel(stages[index])
                                    .frame(width: width, height: height)
                            } else {
                                Color.clear.frame(width: width, height: height)
                            }
                        }
                    }
                }
            }
            // Centred in whatever is left over.
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(GardenPalette.parchment.ignoresSafeArea())
    }

    private func panel(_ stage: SeedlingStage) -> some View {
        // Bottom-aligned, matching how the plant sits on the real screen — the
        // stem's foot is the fixed point, so a taller stage reads as taller.
        ZStack(alignment: .bottomLeading) {
            SeedlingView(stage: stage)

            Text("stage \(stage.rawValue)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(GardenPalette.ink.opacity(0.45))
        }
        // Every panel plays its entrance on appear, so a screenshot taken
        // before ~5s catches the plant mid-growth.
    }
}

#Preview("All stages") {
    StageSheet()
}
#endif
