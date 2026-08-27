import Foundation

/// The dynamic bio: six mutual terms between the reader and the person on
/// the card, each rendered through a per-category sentence, spread across
/// hubs. This replaces `DynamicPrompts`, which addressed hypothetical
/// readers; this one addresses the real one.
///
/// **The server categorizes; this file composes.** Every term arriving on
/// a card has already cleared the whole naming gate stack server-side
/// (`bio.can_name`, suppressions, the YouTube witness rule) and carries a
/// closed-vocabulary `category`/`hub`/`block` — no concept ids or keys
/// cross the wire. Mutuality is the reader's own Memories terms
/// intersected with the card's, the `MatchProfileService.captions`
/// precedent generalized: exact label match outranks a shared block,
/// which outranks the person's own strongest terms — so a sparse pair
/// still gets a bio, made of what the card's owner actually is.
///
/// **The diversity constraint is structural**: at most two picks per hub
/// and per category, distinct hubs first — six sentences that are never
/// six music terms, the owner's "minimize user distance while maximizing
/// term distance on the ontology graph".
///
/// **The never-invent rule holds throughout**: a category with no
/// template is skipped, never placeholdered; an empty result is an empty
/// pool, and the feed falls back to the legacy interest lines.
enum BioComposer {

    /// One sentence for the card's rotation pool, keeping its hub so the
    /// per-appearance draw can prefer two different worlds — the
    /// two-ontology rule carried over as hubs.
    struct Line: Equatable {
        let text: String
        let hub: String?
    }

    /// The reader's side of the intersection, built once per feed load
    /// from their own `list_assertions` rows.
    ///
    /// **Normalization bridges the two label syntaxes.** `list_assertions`
    /// composes display labels ("Jay Chou (周杰倫)", "IU - Blueming");
    /// `matching_terms` sends the raw preferred label. Casefolding alone
    /// would miss every decorated term, so the parenthetical suffix and
    /// the artist prefix are stripped before folding — a missed match
    /// degrades to near-mutual via the block, never to a wrong sentence.
    struct ViewerSnapshot {
        let scoreByLabel: [String: Double]
        let bestScoreByBlock: [String: Double]

        init(assertions: [SemanticSurfaceService.Assertion]) {
            var byLabel: [String: Double] = [:]
            var byBlock: [String: Double] = [:]
            for assertion in assertions {
                let score = assertion.strength ?? 1.0
                let key = BioComposer.normalize(assertion.label)
                byLabel[key] = max(byLabel[key] ?? 0, score)
                if let block = assertion.blockKey {
                    byBlock[block] = max(byBlock[block] ?? 0, score)
                }
            }
            scoreByLabel = byLabel
            bestScoreByBlock = byBlock
        }
    }

    // MARK: - Composition

    /// The six lines for one card, or fewer, or none — never invented.
    static func compose(
        viewer: ViewerSnapshot?,
        terms: [DiscoveryService.BioTerm]
    ) -> [Line] {
        struct Candidate {
            let term: DiscoveryService.BioTerm
            let text: String
            let tier: Double
        }

        var candidates: [Candidate] = []
        for term in terms {
            // A category with no sentence is not selectable — skipping it
            // is correct, rendering it with a placeholder is not.
            guard let text = BioTemplates.line(term.category, label: term.label)
            else { continue }
            let tier: Double
            if let viewer,
               let mine = viewer.scoreByLabel[normalize(term.label)] {
                tier = 1.0 * min(mine, term.score)
            } else if let viewer, let block = term.block,
                      let mine = viewer.bestScoreByBlock[block] {
                tier = 0.5 * min(mine, term.score)
            } else {
                tier = 0.25 * term.score
            }
            candidates.append(Candidate(term: term, text: text, tier: tier))
        }
        guard !candidates.isEmpty else { return [] }
        candidates.sort { $0.tier > $1.tier }

        // Greedy, distinct hubs first, then a second per hub — hard caps
        // of two per hub and two per category, so the pool never reads as
        // one world or one sentence-frame three times over.
        var picked: [Candidate] = []
        var hubCount: [String: Int] = [:]
        var categoryCount: [DiscoveryService.BioCategory: Int] = [:]

        for allowRepeatHub in [false, true] {
            for candidate in candidates {
                guard picked.count < 6 else { break }
                guard !picked.contains(where: { $0.term == candidate.term })
                else { continue }
                let hub = candidate.term.hub ?? "__unplaced"
                let hubUses = hubCount[hub] ?? 0
                let categoryUses = categoryCount[candidate.term.category] ?? 0
                guard categoryUses < 2 else { continue }
                if allowRepeatHub {
                    guard hubUses < 2 else { continue }
                } else {
                    guard hubUses == 0 else { continue }
                }
                picked.append(candidate)
                hubCount[hub] = hubUses + 1
                categoryCount[candidate.term.category] = categoryUses + 1
            }
        }

        return picked.map { Line(text: $0.text, hub: $0.term.hub) }
    }

    /// Applies the composer across a loaded feed page — the one shared
    /// helper Explore and Bookmarks both call, so the two surfaces read
    /// identically by construction.
    static func composed(
        _ people: [DiscoveryService.Person],
        viewer: ViewerSnapshot?
    ) -> [DiscoveryService.Person] {
        people.map { person in
            var person = person
            person.bioLines = compose(viewer: viewer, terms: person.terms)
            return person
        }
    }

    /// The reader's snapshot, or nil for *could not ask* — which composes
    /// every card at fill tier (the person's own strongest diverse terms),
    /// never an error.
    static func viewerSnapshot() async -> ViewerSnapshot? {
        guard let assertions = await SemanticSurfaceService.shared.assertions(),
              !assertions.isEmpty
        else { return nil }
        return ViewerSnapshot(assertions: assertions)
    }

    /// Casefold, strip the ` (…)` suffix and the `… - ` artist prefix —
    /// the 0364/0367 composed-label syntax, undone.
    static func normalize(_ label: String) -> String {
        var value = label
        if let open = value.range(of: " (", options: .backwards),
           value.hasSuffix(")") {
            value = String(value[..<open.lowerBound])
        }
        if let dash = value.range(of: " - ") {
            value = String(value[dash.upperBound...])
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// The owner's copy, verbatim (2026-08-28). One function, one place —
/// prose lives in Swift and never in a schema, the icebreaker's rule.
enum BioTemplates {

    /// nil = this category has no sentence yet and its terms are not
    /// selectable: `athleteTeam` waits on the Wikidata fan-name
    /// derivation, `screen` on a medium-neutral line, `authorDirector` on
    /// a directed_by predicate — dormant, never mislabeled.
    static func line(_ category: DiscoveryService.BioCategory, label: String) -> String? {
        switch category {
        case .composer:
            return "\(label) reallyyyyyyyy knows how to make good music."
        case .performer:
            return "Listening to \(label) again. Its so peak!"
        case .tvSeries:
            return "Looking for someone to binge-watch \(label) start to finish."
        case .movie:
            return "\(label) is the greatest movie in the world. Period. Debate me."
        case .authorDirector:
            return "\(label) never fails me, best director/author ever."
        case .book:
            return "Any bookworms here? looking for \(label)-philes."
        case .creator:
            return "Lets exchange secrets. I'll go first: Watching \(label) is my guilty pleasure."
        case .game:
            return "Swipe right to play \(label) together."
        case .travel:
            // The trip concept's label is "Trip to Tokyo"; the sentence
            // wants the city.
            let place = label.hasPrefix("Trip to ")
                ? String(label.dropFirst("Trip to ".count)) : label
            return "Still mesmerized by the beauty of \(place)."
        case .sportDoing:
            return "Looking for someone to do \(label.lowercased()) together."
        case .subject:
            return "Our first date can be nerdy talks on \(label)."
        case .subjectLanguage:
            // "French (language)" reads as "learning French".
            let language = label.replacingOccurrences(of: " (language)", with: "")
            return "Our first date can be nerdy talks on learning \(language)."
        case .athleteTeam, .screen, .other:
            return nil
        }
    }
}
