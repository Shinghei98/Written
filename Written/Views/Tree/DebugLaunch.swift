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
    /// `-stage N` → the screen as though the first N modalities were connected.
    /// 0 is bare soil, 3 the full plant.
    static var forcedStage: Int? {
        UserDefaults.standard.string(forKey: "stage").flatMap(Int.init)
    }

    /// `-stages all` → every illustrated stage at once, so comparing against
    /// the reference art costs one launch and one screenshot instead of four.
    static var showsAllStages: Bool {
        UserDefaults.standard.string(forKey: "stages") == "all"
    }

    /// `-screen dashboard` → plays the move to the dashboard shortly after
    /// launch. It is otherwise only reachable by tapping "View profile", and
    /// `simctl` cannot tap; screenshotting during the delay and after it covers
    /// both the transition and the screen it lands on.
    static var opensDashboard: Bool {
        UserDefaults.standard.string(forKey: "screen") == "dashboard"
    }

    /// How long the garden holds before it leaves, under `-screen dashboard`.
    static let dashboardDelay: Double = 1.2
}

/// All four illustrated stages on one screen, 2×2.
///
/// Not a row of four: at a quarter of the width each panel is too small to
/// judge a petiole angle on, which is the whole reason for looking.
struct StageSheet: View {
    private let stages = SeedlingStage.allCases

    var body: some View {
        GeometryReader { geometry in
            // Half the width, and the height that width implies — sized
            // explicitly because `SeedlingView` is aspect-fit, and a
            // `maxWidth: .infinity` frame proposes it an infinite width, which
            // collapses the whole sheet to nothing.
            let width = geometry.size.width / 2
            let height = width / SeedlingView.aspectRatio

            VStack(spacing: 20) {
                ForEach(0..<2, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(0..<2, id: \.self) { column in
                            panel(stages[row * 2 + column])
                                .frame(width: width, height: height)
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
