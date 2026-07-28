import Foundation

/// One branch of the profile tree: a facet of the user's digital footprint.
///
/// `rawValue` is the invasiveness order, lowest first — asking what someone
/// listens to is the smallest thing we can ask for, so music is the shoot's
/// first branch. That same order is the order branches unlock in, so
/// `Modality.allCases` is the onboarding sequence.
///
/// There are three because the illustration has four stages: bare soil plus one
/// per connected modality. A modality with no distiller behind it yet is still
/// declared here — the user should be able to see what is coming — and
/// `isAvailable` is what says whether it can actually be connected.
enum Modality: Int, CaseIterable, Identifiable, Hashable {
    case music
    case media
    case lifestyle

    var id: Int { rawValue }

    /// `DistilledRecord.source` values that feed this branch. Empty means the
    /// modality is declared for the shape of the tree but has no distiller yet.
    var sources: [String] {
        switch self {
        // Order matters: this array drives the rows in `SourcePickerSheet` and
        // the marks in the "Connected to …" bars.
        //
        // Apple Music alone. Spotify sat beside it until the server became the
        // source of truth: its Developer Terms forbid storing Spotify Content in
        // a third-party database, so it was the one source whose data could
        // never be restored to a new device — and it could never have left
        // development mode anyway, which allows five testers against an extended
        // quota needing 250,000 monthly active users.
        case .music: return ["apple_music"]
        case .media: return ["youtube"]
        case .lifestyle: return ["health"]
        }
    }

    var label: String {
        switch self {
        case .music: return "Music"
        case .media: return "Media"
        case .lifestyle: return "Lifestyle"
        }
    }

    var systemImage: String {
        switch self {
        case .music: return "music.note"
        case .media: return "play.rectangle"
        case .lifestyle: return "heart"
        }
    }

    /// False for modalities that exist in the metaphor but can't be connected
    /// yet. They are still offered — the bar appears in its turn — with the
    /// button disabled, rather than the flow simply ending.
    var isAvailable: Bool { !sources.isEmpty }

    /// Human-readable list of the apps behind this branch, for the prompt card.
    var sourceLabels: [String] {
        sources.map(Modality.displayName(forSource:))
    }

    static func displayName(forSource source: String) -> String {
        switch source {
        case "youtube": return "YouTube"
        case "apple_music": return "Apple Music"
        case "health": return "Apple Health"
        default: return source
        }
    }

    /// The mark shown for a connected app, once its modality's bar says so.
    static func icon(forSource source: String) -> String {
        switch source {
        case "youtube": return "play.rectangle.fill"
        case "apple_music": return "music.note"
        case "health": return "heart.fill"
        default: return "app"
        }
    }
}
