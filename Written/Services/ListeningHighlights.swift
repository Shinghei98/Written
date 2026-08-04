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

    /// What a year of somebody's calendar looks like, without saying what any of
    /// it was.
    ///
    /// **The dashboard shows this and never the titles.** Events are stored
    /// whole and synced — the titles *are* the signal and the database keeps
    /// every one for the ontology stage — but a title is also a therapy
    /// appointment, a doctor's name, or dinner with somebody, and putting those
    /// on a profile page by default is a different act from collecting them.
    /// The shape carries the habit, which is what a reader of a profile would
    /// actually take from it, and none of the specifics.
    ///
    /// Counted from the pre-computed `extra` fields rather than re-derived from
    /// timestamps, for the reason `CalendarDistiller` records them: a Saturday
    /// evening is a different fact from a Tuesday morning, and working that out
    /// of a date twice is how the two copies drift apart.
    struct EventShape: Equatable {
        let total: Int
        /// Written in by a ticketing site rather than typed — it cost money and
        /// a Saturday, which is the strongest claim in the whole distillation.
        let booked: Int
        let weekend: Int
        /// Starting at 17:00 or later.
        let evening: Int
        /// The weekday with the most on it, already named.
        let busiestDay: String?

        var isEmpty: Bool { total == 0 }
    }

    /// **Nothing draws this now** — the card lists the events themselves, which
    /// is what somebody recognises their own year by. It is kept because the
    /// readings it encodes are real and derived rather than stored: booked
    /// against typed, evenings, weekends, the busiest day. The ontology stage
    /// will want them and they should not have to be re-derived.
    static func shape(in records: [DistilledRecord]) -> EventShape {
        let live = personalEvents(in: records)

        var byWeekday: [Int: Int] = [:]
        var booked = 0, weekend = 0, evening = 0

        for record in live {
            if record.extraValue("booked") == "1" { booked += 1 }
            if record.extraValue("weekend") == "1" { weekend += 1 }
            if let hour = Int(record.extraValue("hour") ?? ""), hour >= 17 { evening += 1 }
            if let weekday = Int(record.extraValue("weekday") ?? "") {
                byWeekday[weekday, default: 0] += 1
            }
        }

        // `weekday` is Foundation's 1-based Sunday-first number, which is what
        // `Calendar.current.dateComponents` gave the distiller.
        let busiest = byWeekday.max { $0.value < $1.value }?.key
        let names = DateFormatter().weekdaySymbols ?? []

        return EventShape(
            total: live.count,
            booked: booked,
            weekend: weekend,
            evening: evening,
            busiestDay: busiest.flatMap { index in
                names.indices.contains(index - 1) ? names[index - 1] : nil
            }
        )
    }

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
    /// The rows both readings share: this person's own events, public calendars
    /// excluded twice over — once at collection and again here for rows written
    /// before the distiller started filtering.
    private static func personalEvents(in records: [DistilledRecord]) -> [DistilledRecord] {
        records.filter { record in
            guard record.source == "apple_calendar",
                  record.dataType == "event",
                  !record.isRemovedByUser else { return false }
            let type = record.extraValue("cal_type")
            return type != "Subscription" && type != "Birthday"
        }
    }

    /// The events themselves, titles and all — what the card shows.
    ///
    /// **One row per distinct title.** A calendar is mostly repetition: a
    /// standing meeting, a weekly class, a recurring reminder, each written in
    /// dozens of times. Listing every occurrence would bury the things worth
    /// reading — the tour, the flight, the concert — under fifty copies of
    /// "Gym". The occurrences are all still in the database and all still go to
    /// the ontology stage; this is a reading, not a filter on what is kept.
    ///
    /// The first of each name survives, which after the sort below is the
    /// soonest — so a repeating event is dated by its next occurrence rather
    /// than by whichever copy happened to come back first.
    static func events(in records: [DistilledRecord], limit: Int = 40) -> [Event] {
        var seen: Set<String> = []
        return personalEvents(in: records)
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
            .filter { seen.insert($0.name.lowercased()).inserted }
            .prefix(limit)
            .map { $0 }
    }

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
