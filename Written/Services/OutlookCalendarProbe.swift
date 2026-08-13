#if DEBUG
import Foundation

/// Drives `OutlookCalendarDistiller.shape` over a recorded Graph response and
/// reports what it produced, in words.
///
/// **This is a test that had nowhere to live.** The project has one test target
/// and it is a UI one — `WrittenUITests`, which drives the accessibility tree —
/// so a pure parsing check would have meant adding a unit-test target and the
/// `project.pbxproj` surgery the synchronized-folder arrangement exists to
/// avoid. `-probe-outlook` is the shape this codebase already uses for
/// "something that must be run rather than read", beside `-probe-ingest`,
/// `-probe-surface` and `-probe-match`.
///
/// It asserts nothing and prints everything, deliberately. The interesting
/// output is not a pass mark but the rows themselves — whether "Flight to Los
/// Angeles (UA 1103)" survives with its title intact and its start in the right
/// hour is a question about the *data*, and a green tick would hide the answer.
/// The expected counts are stated beside the actual ones so a disagreement is
/// visible without remembering what the fixture holds.
enum OutlookCalendarProbe {

    /// What the fixture is built to produce, so the report can mark its own
    /// homework. Stated here rather than in the JSON because a fixture that
    /// carries its own expected answer can be edited into agreeing with itself.
    private static let expectedEventTitles: Set<String> = [
        "Dinner at Yardbird",
        "Flight to Los Angeles (UA 1103)",
        "Team stand-up",
        "Design conference",
    ]

    private struct Fixture: Decodable {
        struct Entry: Decodable {
            let calendar: OutlookCalendarDistiller.CalendarEntry
            let events: [OutlookCalendarDistiller.EventEntry]
        }
        let calendars: [Entry]
    }

    static func run() -> String {
        guard let url = Bundle.main.url(
            forResource: "outlook_calendar_view_sample", withExtension: "json"
        ) else {
            // **A missing fixture must not read as a clean run.** The file lives
            // under `Written/Resources/`, which the synchronized folder copies
            // in automatically; if that ever stops being true this is the line
            // that says so rather than an empty report.
            return "probe-outlook: fixture not in the bundle"
        }

        let fixture: Fixture
        do {
            fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        } catch {
            return "probe-outlook: fixture did not decode — \(error)"
        }

        let records = OutlookCalendarDistiller.shape(
            calendars: fixture.calendars.map { ($0.calendar, $0.events) }
        )

        let events = records.filter { $0.dataType == "event" }
        let containers = records.filter { $0.dataType == "calendar" }
        let titles = Set(events.map(\.name))

        var lines: [String] = []
        lines.append("rows        \(records.count)")
        lines.append("calendars   \(containers.count)   expected 1 — the holidays calendar is dropped whole")
        lines.append("events      \(events.count)   expected \(expectedEventTitles.count)")

        let missing = expectedEventTitles.subtracting(titles).sorted()
        let unexpected = titles.subtracting(expectedEventTitles).sorted()
        if missing.isEmpty && unexpected.isEmpty {
            lines.append("titles      exactly as expected")
        } else {
            if !missing.isEmpty { lines.append("MISSING     \(missing.joined(separator: ", "))") }
            if !unexpected.isEmpty { lines.append("UNEXPECTED  \(unexpected.joined(separator: ", "))") }
        }

        // **Every source has to be `outlook_calendar`.** A row filed under
        // another source would be invisible to `Modality.plans.recordSources`
        // and would dodge the dedup in `ListeningHighlights.personalEvents`.
        let sources = Set(records.map(\.source))
        lines.append("source(s)   \(sources.sorted().joined(separator: ", "))")

        // **No `booked=1` may ever appear.** `Calendars.ReadBasic` returns no
        // organiser and no url, so a booked flag here would be invented — and
        // `SemanticSource` maps this connector's events to `scheduled` alone,
        // so a stamped `booked` would be a value nothing downstream can weigh.
        let booked = events.filter { $0.extra.contains("booked=1") }
        lines.append("booked=1    \(booked.count)   expected 0 — ReadBasic returns no organiser or url")

        let recurring = events.filter { $0.extra.contains("recurring=1") }
        lines.append("recurring   \(recurring.count)   expected 1 — two stand-up occurrences collapse to one row")

        lines.append("")
        lines.append("rows in full:")
        for record in records {
            lines.append("  [\(record.dataType)] \(record.name)")
            lines.append("      id    \(record.itemID)")
            lines.append("      extra \(record.extra)")
            if !record.detail.isEmpty { lines.append("      detail \(record.detail)") }
        }

        return lines.joined(separator: "\n")
    }
}
#endif
