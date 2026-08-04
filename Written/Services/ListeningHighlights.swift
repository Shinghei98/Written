import Foundation

/// Podcast shows and the events somebody arranged, ranked for the dashboard's
/// cards.
///
/// Pure and stateless, like `MusicHighlights` and `MediaHighlights`. Both live
/// in one file because they are one idea — read the records of a source, rank
/// them, hand back a list a card can draw.
///
/// Audiobooks were here and are not: Apple Books has no public API and its
/// audiobooks are DRM-locked inside its own container, so nothing could ever
/// have reached this. See the source list in CLAUDE.md.
enum ListeningHighlights {

    // MARK: - Podcasts

    struct Show: Identifiable, Hashable {
        var id: String { showID.isEmpty ? name.lowercased() : showID }
        let showID: String
        let name: String
        /// The publisher: "Audiochuck", "The New York Times". MediaPlayer files
        /// it under `artist`, which is where a podcast's producer lives.
        let publisher: String
        /// Episodes of this show currently on the phone.
        let episodes: Int
        /// 0…1, the furthest through any one episode they have got. The only
        /// behavioural signal Apple exposes for podcasts — there is no play
        /// count and no last-played date, measured.
        let progress: Double
        let score: Double
    }

    /// **Ranked by having started it, not by having been sent it.**
    ///
    /// Apple auto-downloads recent episodes of followed shows, so the number of
    /// episodes on the phone is mostly a fact about Apple's cache policy. What
    /// separates a show somebody follows from one they listen to is whether any
    /// episode was ever opened, which is what `progress` records. Episodes still
    /// count for something — following five shows and playing none should still
    /// rank them — but they are the tiebreak rather than the measure.
    static func shows(in records: [DistilledRecord]) -> [Show] {
        let live = records.filter { $0.source == "apple_podcasts" && !$0.isRemovedByUser }

        var progressByShow: [String: Double] = [:]
        for episode in live where episode.dataType == "podcast_episode" {
            let show = episode.creator.lowercased()
            guard !show.isEmpty else { continue }
            let value = Double(episode.extraValue("progress") ?? "") ?? 0
            progressByShow[show] = max(progressByShow[show] ?? 0, value)
        }

        return live
            .filter { $0.dataType == "podcast_show" }
            .map { record in
                let progress = progressByShow[record.name.lowercased()] ?? 0
                let episodes = Int(record.extraValue("episodes_on_device") ?? "") ?? 0
                return Show(
                    showID: record.itemID,
                    name: record.name,
                    publisher: record.creator,
                    episodes: episodes,
                    progress: progress,
                    // Started beats stocked, and by enough that no number of
                    // undownloaded-and-unplayed episodes overtakes one show
                    // somebody actually opened.
                    score: progress * 10 + Double(episodes)
                )
            }
            .sorted { ($0.score, $0.name) > ($1.score, $1.name) }
    }

    // MARK: - Events

    struct Event: Identifiable, Hashable {
        var id: String { eventID }
        let eventID: String
        let name: String
        let start: Date?
        /// Written in by a ticketing site rather than typed by the user —
        /// Eventbrite, Ticketmaster, Dice all leave a `url`. It cost money and a
        /// Saturday, which is why `CalendarDistiller` keeps the field at all.
        let booked: Bool
        let calendar: String
    }

    /// **Public calendars are excluded here as well as at the distiller.**
    ///
    /// `CalendarDistiller` no longer collects subscribed or birthday calendars,
    /// but rows written before it stopped are in the database and come back on
    /// every restore — so filtering only at collection time would leave a year
    /// of national holidays in this card for anybody who distilled early. Rows
    /// old enough to predate `cal_type=` are kept: they were collected when
    /// nothing was filtered, and dropping them on a missing field would hide
    /// real events too.
    static func events(in records: [DistilledRecord]) -> [Event] {
        records
            .filter { record in
                guard record.source == "apple_calendar",
                      record.dataType == "event",
                      !record.isRemovedByUser else { return false }
                let type = record.extraValue("cal_type")
                return type != "Subscription" && type != "Birthday"
            }
            .map { record in
                Event(
                    eventID: record.itemID,
                    name: record.name,
                    start: record.extraValue("start").flatMap(Self.iso.date(from:)),
                    booked: record.extraValue("booked") == "1",
                    calendar: record.extraValue("calendar") ?? ""
                )
            }
            // Soonest first among what is still ahead, then the recent past
            // behind it — the same order a person reads their own calendar in.
            .sorted { lhs, rhs in
                switch (lhs.start, rhs.start) {
                case let (left?, right?): return left > right
                case (nil, _): return false
                case (_, nil): return true
                }
            }
    }

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
