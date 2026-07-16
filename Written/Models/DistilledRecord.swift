import Foundation

/// One row of distilled digital footprint, normalized across all sources
/// so the ontology/embedding pipeline downstream consumes a single schema.
struct DistilledRecord: Identifiable, Hashable {
    let id = UUID()

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
