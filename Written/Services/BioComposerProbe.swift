#if DEBUG
import Foundation

/// The composer's unit cases, run in-process behind `-probe-bio` — the
/// probe convention, because this project has no unit-test target and a
/// UI test cannot reach app internals. Each case prints PASS or FAIL
/// with what it saw; the report is the console's, the alert only a
/// headline.
enum BioComposerProbe {

    static func run() -> String {
        var lines: [String] = []
        func check(_ name: String, _ passed: Bool, _ detail: String = "") {
            lines.append("\(passed ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        }

        func term(_ label: String, _ category: DiscoveryService.BioCategory,
                  hub: String?, score: Double = 0.8,
                  block: String? = nil) -> DiscoveryService.BioTerm {
            DiscoveryService.BioTerm(label: label, kind: nil, score: score,
                                     category: category, hub: hub, block: block)
        }

        // 1. Hub cap: six music performers in, at most two lines out.
        let sixMusic = (1...6).map {
            term("Artist \($0)", .performer, hub: "hub:music")
        }
        let capped = BioComposer.compose(viewer: nil, terms: sixMusic)
        check("hub cap", capped.count == 2, "6 music in → \(capped.count) lines")

        // 2. Nil-template categories are skipped, never placeholdered.
        let dormant = [term("Antetokounmpo", .athleteTeam, hub: "hub:sports_movement"),
                       term("Some Show", .screen, hub: "hub:film_video"),
                       term("Unknown Thing", .other, hub: nil)]
        check("never-invent", BioComposer.compose(viewer: nil, terms: dormant).isEmpty)

        // 3. Empty everything is an empty pool.
        check("empty in, empty out", BioComposer.compose(viewer: nil, terms: []).isEmpty)

        // 4. Unknown wire category degrades to .other.
        check("unknown category",
              DiscoveryService.BioCategory(wire: "hologram_idol") == .other)

        // 5. Label normalization bridges the composed display syntax.
        check("parenthetical strip",
              BioComposer.normalize("Jay Chou (周杰倫)") == "jay chou")
        check("artist prefix strip",
              BioComposer.normalize("IU - Blueming") == "blueming")

        // 6. Diversity beats raw score: with four hubs on offer, the six
        // picks span at least three of them even when one hub dominates.
        let mixed = [term("A", .performer, hub: "hub:music", score: 0.9),
                     term("B", .performer, hub: "hub:music", score: 0.9),
                     term("C", .performer, hub: "hub:music", score: 0.9),
                     term("D", .game, hub: "hub:games_play", score: 0.3),
                     term("E", .travel, hub: "hub:places_cultures", score: 0.2),
                     term("F", .subject, hub: "hub:ideas_learning", score: 0.1)]
        let spread = BioComposer.compose(viewer: nil, terms: mixed)
        let hubs = Set(spread.compactMap(\.hub))
        check("diversity", hubs.count >= 3 && spread.count >= 5,
              "\(spread.count) lines over \(hubs.count) hubs")

        // 7. Category cap: three books never yield three book sentences.
        let books = (1...3).map { term("Book \($0)", .book, hub: "hub:ideas_learning") }
        check("category cap",
              BioComposer.compose(viewer: nil, terms: books).count == 2)

        // 8. The trip label sheds its prefix in the sentence.
        let trip = BioComposer.compose(
            viewer: nil, terms: [term("Trip to Tokyo", .travel, hub: "hub:places_cultures")])
        check("travel wording",
              trip.first?.text == "Still mesmerized by the beauty of Tokyo.",
              trip.first?.text ?? "nil")

        return lines.joined(separator: "\n")
    }
}
#endif
