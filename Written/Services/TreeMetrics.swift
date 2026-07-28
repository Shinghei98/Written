import Foundation

/// Turns distilled records into the numbers the tree is grown from.
///
/// **This is a stand-in for the embedding stage, which doesn't exist yet.**
/// Diversity here is normalized Shannon entropy over the facets a record already
/// carries — creators (artists, channels) and the `genres=` pairs the distillers
/// write into `DistilledRecord.extra`. It is a defensible approximation of "how
/// varied is this person's footprint", not the real thing. When the embedding
/// service lands, replace the body of `metrics(for:in:)` and leave every caller
/// untouched.
enum TreeMetrics {

    static func state(from records: [DistilledRecord]) -> TreeState {
        var branches: [Modality: ModalityMetrics] = [:]
        for modality in Modality.allCases {
            if let metrics = metrics(for: modality, in: records) {
                branches[modality] = metrics
            }
        }
        return TreeState(branches: branches)
    }

    /// `nil` when the modality has no records at all — an unconnected branch
    /// doesn't exist rather than existing at zero size.
    static func metrics(for modality: Modality, in records: [DistilledRecord]) -> ModalityMetrics? {
        let sources = Set(modality.sources)
        let owned = records.filter { sources.contains($0.source) }
        guard !owned.isEmpty else { return nil }

        let counts = facetCounts(in: owned)
        return ModalityMetrics(
            volume: owned.count,
            diversity: normalizedEntropy(of: counts),
            dominantShare: dominantShare(of: counts)
        )
    }

    /// The lifestyle branch, measured from the derived figures rather than from
    /// records.
    ///
    /// Every other branch is sized by counting rows, and lifestyle used to be
    /// too — it was the *largest*, because a year of HealthKit is a workout row
    /// per session plus one per day plus one per hour, some nine thousand of
    /// them. Those rows are now reduced to a handful of figures and discarded on
    /// the device, so counting records would size the branch on the two that
    /// remain (an age and a biological sex) and the branch would stop growing
    /// altogether. That is not a smaller reading of the same thing; it is a
    /// different question being answered by accident.
    ///
    /// `days` stands in for the volume the raw rows used to supply, which puts
    /// lifestyle on roughly the same scale as media rather than dwarfing it.
    static func lifestyleMetrics(
        sports: [LifestyleHighlights.Sport],
        chronotypeDays: Int?,
        hasSignals: Bool
    ) -> ModalityMetrics? {
        let days = chronotypeDays ?? 0
        guard hasSignals || !sports.isEmpty else { return nil }

        var counts: [String: Int] = [:]
        for sport in sports where sport.sessions > 0 {
            counts["sport:\(sport.name.lowercased())"] = sport.sessions
        }
        // Someone with a chronotype and no recorded workouts still has a
        // lifestyle worth drawing — a single facet, so the branch is present but
        // plainly less varied than one with four sports on it. Honest rather
        // than flattering.
        if counts.isEmpty, days > 0 {
            counts["rhythm"] = days
        }
        guard !counts.isEmpty else { return nil }

        return ModalityMetrics(
            volume: days + sports.reduce(0) { $0 + $1.sessions },
            diversity: normalizedEntropy(of: counts),
            dominantShare: dominantShare(of: counts)
        )
    }

    // MARK: - Facets

    /// Counts every creator and every genre mentioned. A record with three
    /// genres contributes to all three, which is the point: breadth of taste is
    /// exactly what should make the tree fuller.
    private static func facetCounts(in records: [DistilledRecord]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for record in records {
            let creator = record.creator.trimmingCharacters(in: .whitespacesAndNewlines)
            if !creator.isEmpty {
                counts["creator:\(creator.lowercased())", default: 0] += 1
            }
            for genre in genres(of: record) {
                counts["genre:\(genre)", default: 0] += 1
            }
        }
        // Nothing but bare titles: fall back to the titles themselves so a
        // source with no creator field still registers some variety.
        if counts.isEmpty {
            for record in records {
                counts["name:\(record.name.lowercased())", default: 0] += 1
            }
        }
        return counts
    }

    /// Genres are pipe-separated inside their `extra` value — see `CLAUDE.md`
    /// and `AppleMusicDistiller`.
    private static func genres(of record: DistilledRecord) -> [String] {
        (record.extraValue("genres") ?? "")
            .split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    // MARK: - Measures

    /// Entropy normalized against `referenceFacetCount` distinct, evenly spread
    /// facets rather than against the observed count. Normalizing by the latter
    /// would score "two artists, one track each" as perfectly diverse.
    private static let referenceFacetCount = 30.0

    private static func normalizedEntropy(of counts: [String: Int]) -> Double {
        let total = Double(counts.values.reduce(0, +))
        guard total > 0, counts.count > 1 else { return 0 }

        let entropy = counts.values.reduce(0.0) { partial, count in
            let p = Double(count) / total
            return partial - p * log(p)
        }
        return min(1, max(0, entropy / log(referenceFacetCount)))
    }

    private static func dominantShare(of counts: [String: Int]) -> Double {
        let total = Double(counts.values.reduce(0, +))
        guard total > 0, let top = counts.values.max() else { return 1 }
        return Double(top) / total
    }
}
