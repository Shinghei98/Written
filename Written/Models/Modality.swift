import Foundation

/// One branch of the profile tree: a facet of the user's digital footprint.
///
/// `rawValue` is the invasiveness order, lowest first — asking what someone
/// listens to is the smallest thing we can ask for, so music is case zero.
///
/// **It is no longer the unlock order, and the two must not be confused.**
/// `allCases` is given explicitly below and the raw values stay where they are,
/// because `TreeSkeleton` derives each branch's attachment height from
/// `rawValue`. Anything asking "in what order does the user meet these?" reads
/// `allCases`; only the drawing reads `rawValue`. `TreeState.connectedModalities`
/// got this wrong for one build and sent music to the top of the stack the
/// moment it was connected.
///
/// Four, against an illustration with four stages — bare soil plus one per
/// connected modality — so the fourth does not grow the plant again. It lights
/// the badge on the bough instead, the shoot that was already drawn with a bud
/// at its tip and had no app behind it. A modality with no distiller behind it
/// yet is still declared here — the user should be able to see what is coming —
/// and `isAvailable` is what says whether it can actually be connected.
enum Modality: Int, CaseIterable, Identifiable, Hashable {
    case music
    case media
    case lifestyle
    case plans

    var id: Int { rawValue }

    /// **The unlock sequence, and it is deliberately not the declaration order.**
    ///
    /// `allCases` is what every part of the app reads as "the order these are
    /// connected in" — `TreeState.nextModality`, `shootModality`, the preview
    /// stepper — so giving it explicitly moves the sequence in one place.
    ///
    /// The declaration order and the raw values stay where they are, and that is
    /// the point rather than laziness. `TreeSkeleton` derives a branch's
    /// attachment height from `modality.rawValue`, so renumbering the cases would
    /// move the branches — and the plant is supposed to look exactly as it did.
    /// Reordering the *sequence* changes which badge stands for what; reordering
    /// the *cases* would change the drawing.
    static let allCases: [Modality] = [.media, .lifestyle, .music, .plans]

    /// `DistilledRecord.source` values that feed this branch. Empty means the
    /// modality is declared for the shape of the tree but has no distiller yet.
    /// Whether a refused permission for this source is fixed in the Health app
    /// rather than in Settings.
    ///
    /// Health is the one permission not reachable from Written's own Settings
    /// page — it lives under Privacy & Security, or in Health under Profile ›
    /// Apps. Every other source's switch is on the app's page.
    var opensHealthApp: Bool { sources.contains("health") }

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
        // **Spotify is here for the data-collection beta and comes out before
        // the App Store build.** It was dropped when Postgres became the source
        // of truth: its Developer Terms forbid storing Spotify Content in a
        // third-party database, so it is the one source whose rows could never
        // be restored to a new device — and it cannot leave development mode
        // anyway, which allows five testers against an extended quota needing
        // 250,000 monthly actives. Neither fact has changed. What changed is the
        // purpose: a beta that exists to gather listening data is worth a second
        // music source for a few weeks. See CLAUDE.md for the removal condition.
        //
        // Apple Music first: it is the one the product depends on, and the
        // picker draws these in order.
        case .music: return ["apple_music", "spotify"]
        case .media: return ["youtube"]
        // Not in `written_api.xlsx` — the first source that isn't. A calendar
        // is where a bought ticket lands by itself: Eventbrite, Ticketmaster
        // and Dice all write the booking straight in, so an event someone paid
        // to attend arrives without them doing anything. See `CalendarDistiller`.
        case .plans: return ["apple_calendar"]
        case .lifestyle: return ["health"]
        }
    }

    var label: String {
        switch self {
        case .music: return "Music"
        case .media: return "Media"
        case .lifestyle: return "Lifestyle"
        // The case stays `.plans` and the label says "Events". Renaming the case
        // would touch every switch over `Modality` and every persisted raw value
        // for a word nobody sees — `label` is the only thing a user reads.
        case .plans: return "Events"
        }
    }

    var systemImage: String {
        switch self {
        case .music: return "music.note"
        case .media: return "play.rectangle"
        case .lifestyle: return "heart"
        case .plans: return "calendar"
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

    /// Which branch a source feeds. `nil` for a source no modality claims.
    static func owning(source: String) -> Modality? {
        allCases.first { $0.sources.contains(source) }
    }

    static func displayName(forSource source: String) -> String {
        switch source {
        case "youtube": return "YouTube"
        case "apple_music": return "Apple Music"
        case "spotify": return "Spotify"
        case "health": return "Apple Health"
        case "apple_calendar": return "Apple Calendar"
        default: return source
        }
    }

    /// The mark shown for a connected app, once its modality's bar says so.
    static func icon(forSource source: String) -> String {
        switch source {
        case "youtube": return "play.rectangle.fill"
        case "apple_music": return "music.note"
        case "spotify": return "waveform"
        case "health": return "heart.fill"
        case "apple_calendar": return "calendar"
        default: return "app"
        }
    }
}
