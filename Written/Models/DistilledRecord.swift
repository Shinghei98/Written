import Foundation

/// One row of distilled digital footprint, normalized across all sources
/// so the ontology/embedding pipeline downstream consumes a single schema.
struct DistilledRecord: Identifiable, Hashable, Codable {
    /// Local and disposable. It exists so SwiftUI can tell two rows apart in a
    /// list, is regenerated on every distillation, and identifies nothing —
    /// which is why it is omitted from `CodingKeys` and why the database keys on
    /// `(user, source, data_type, item_id)` instead.
    let id = UUID()

    private enum CodingKeys: String, CodingKey {
        case source, dataType, itemID, name, creator, detail, extra, collectedAt
    }

    /// Which app the record was distilled from, e.g. "youtube", "apple_music".
    let source: String

    /// The kind of signal, e.g. "subscription", "liked_video", "playlist",
    /// "library_song", "recently_played", "heavy_rotation", "recommendation".
    let dataType: String

    /// Stable identifier of the item in the source platform.
    let itemID: String

    /// Primary display name (video title, song name, channel name, ...).
    let name: String

    /// Creator/owner (channel, artist, curator) when applicable.
    let creator: String

    /// Secondary context (album, parent playlist, description snippet, ...).
    let detail: String

    /// Extra machine-readable context (genres, dates, ratings, counts).
    let extra: String

    /// When Written distilled this record.
    let collectedAt: Date
}

extension DistilledRecord {
    /// One value out of `extra`, which is `key=value;key=value` — see CLAUDE.md.
    /// `nil` rather than `""` for a key that is absent or empty, so callers can
    /// fall back without checking twice.
    ///
    /// Some values are themselves pipe-separated lists (`genres`, and `creator`
    /// on a track with several artists); splitting those is the caller's job.
    func extraValue(_ key: String) -> String? {
        for pair in extra.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0] == key else { continue }
            let value = String(parts[1])
            return value.isEmpty ? nil : value
        }
        return nil
    }
}

/// Distillation lifecycle of a single source app.
enum SourceStatus: Equatable {
    case idle
    case running
    case done(count: Int)
    case failed(message: String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}
