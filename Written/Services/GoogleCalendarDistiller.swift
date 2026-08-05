import Foundation

/// Somebody's Google Calendar, for the people whose phone is not already
/// supplying it.
///
/// **This source exists for a narrow population and says so.** A Google account
/// added in iOS Settings delivers its events through EventKit as `caldav`, so
/// `CalendarDistiller` already has them — and collecting them again here would
/// put every dinner in the database twice, under a different `item_id` and a
/// different `source`, which `append_source_records` dedupes within a source and
/// would not catch. `CalendarDistiller.hasGoogleAccountOnDevice()` is what keeps
/// the two apart, and it is also the honest answer to Google's "why do you need
/// this scope": *only for users whose calendar we cannot otherwise see*.
///
/// **Everything about what an event means is borrowed rather than rewritten.**
/// The filtering, the ranking and the `extra` keys are `CalendarDistiller`'s,
/// paid for over several rounds — generated calendars, public holidays by token,
/// booked-against-typed, one row per recurring series. This file's only job is
/// to turn Google's JSON into the same `DistilledRecord` shape, so the dashboard
/// card, the ranking and the ontology stage need no knowledge that a second
/// calendar source exists.
struct GoogleCalendarDistiller {

    enum CalendarError: LocalizedError {
        case notConnected
        case server(String)

        var errorDescription: String? {
            switch self {
            case .notConnected: return "Connect Google Calendar first."
            case .server(let detail): return detail
            }
        }
    }

    private let oauth: OAuthPKCEService

    init(oauth: OAuthPKCEService) {
        self.oauth = oauth
    }

    /// The same window `CalendarDistiller` uses, and for the same reason: a
    /// ticket bought today for November only exists ahead of now, and a trip is
    /// what sits outside a year.
    private static var window: (from: Date, to: Date) {
        let now = Date()
        return (
            now.addingTimeInterval(-Double(AppConfig.calendarLookbackDays) * 86_400),
            now.addingTimeInterval(Double(AppConfig.calendarLookaheadDays) * 86_400)
        )
    }

    func distill() async throws -> [DistilledRecord] {
        // Throws rather than answering nil — `OAuthPKCEService` reports a
        // missing or refused grant as an error, which is right: an empty
        // calendar and a revoked connection must not look the same.
        let token = try await oauth.validAccessToken()

        var records: [DistilledRecord] = []
        var seen = Set<String>()

        for calendar in try await calendars(token: token) {
            // **Excluded before a single event is fetched.** Holiday and
            // birthday calendars are the bulk of most accounts — measured at
            // fifteen to one on a real device — and not asking for them at all
            // is cheaper than filtering them afterwards and kinder to the quota.
            guard !CalendarDistiller.isGenerated(calendar.summary) else { continue }
            records.append(Self.record(for: calendar))

            for event in try await events(in: calendar.id, token: token) {
                guard let record = Self.record(for: event, calendar: calendar) else { continue }
                // One row per recurring series, matching the Apple path: a
                // weekly standup is one fact about somebody's week, not
                // fifty-two. `recurringEventId` groups the occurrences and the
                // first in the window wins.
                guard seen.insert(record.itemID).inserted else { continue }
                records.append(record)
                if records.count >= AppConfig.maxCalendarEvents { return records }
            }
        }
        return records
    }

    // MARK: - Fetching

    private struct CalendarEntry: Decodable {
        let id: String
        var summary: String = ""
        var primary: Bool?
        var accessRole: String?
    }

    private struct EventEntry: Decodable {
        struct When: Decodable {
            var dateTime: String?
            /// Present instead of `dateTime` for an all-day event, which is how
            /// Google says so — there is no `allDay` flag.
            var date: String?
        }
        struct Person: Decodable {
            var email: String?
            var displayName: String?
            var `self`: Bool?
        }
        let id: String
        var summary: String?
        var location: String?
        var htmlLink: String?
        var status: String?
        var start: When?
        var end: When?
        var organizer: Person?
        var creator: Person?
        var recurringEventId: String?
        /// `default`, `birthday`, `outOfOffice`, `focusTime`, `workingLocation`.
        /// **Better than anything the Apple path has**, which has to match the
        /// word "birthday" in a title typed by a human.
        var eventType: String?
    }

    private func calendars(token: String) async throws -> [CalendarEntry] {
        struct Page: Decodable { var items: [CalendarEntry]? }
        let data = try await get(
            "https://www.googleapis.com/calendar/v3/users/me/calendarList",
            query: ["minAccessRole": "reader", "maxResults": "250"],
            token: token
        )
        return (try? JSONDecoder().decode(Page.self, from: data))?.items ?? []
    }

    private func events(in calendarID: String, token: String) async throws -> [EventEntry] {
        struct Page: Decodable {
            var items: [EventEntry]?
            var nextPageToken: String?
        }
        let window = Self.window
        var all: [EventEntry] = []
        var pageToken: String?
        var pages = 0

        repeat {
            var query = [
                "timeMin": Self.rfc3339.string(from: window.from),
                "timeMax": Self.rfc3339.string(from: window.to),
                // Google expands a recurring series only when asked. Left off,
                // one row comes back per series — which is exactly what this
                // wants, and saves expanding a decade of standups to discard
                // them.
                "singleEvents": "false",
                "maxResults": "250",
                // Cancelled events are still returned by default and are noise.
                "showDeleted": "false",
            ]
            if let pageToken { query["pageToken"] = pageToken }

            let data = try await get(
                "https://www.googleapis.com/calendar/v3/calendars/"
                    + (calendarID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? calendarID)
                    + "/events",
                query: query,
                token: token
            )
            let page = try? JSONDecoder().decode(Page.self, from: data)
            all += page?.items ?? []
            pageToken = page?.nextPageToken
            pages += 1
            // The same ceiling every fetch in this project has: an uncapped one
            // is a request that gets slower for the people who use the app most.
        } while pageToken != nil && pages < AppConfig.maxPagesPerEndpoint

        return all
    }

    private func get(_ url: String, query: [String: String], token: String) async throws -> Data {
        var components = URLComponents(string: url)
        components?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let requestURL = components?.url else {
            throw CalendarError.server("Bad URL for \(url).")
        }
        var request = URLRequest(url: requestURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            // Google's error body carries a message worth surfacing — a revoked
            // grant and a quota exhaustion look identical otherwise, and one is
            // the user's to fix while the other is ours.
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0?["error"] as? [String: Any])?["message"] as? String }
            throw CalendarError.server(detail ?? "Google Calendar said \(status).")
        }
        return data
    }

    // MARK: - Normalization

    /// Nil for anything that is not an arranged event.
    ///
    /// Birthdays go by `eventType`, which is a fact Google records rather than a
    /// word somebody typed — the Apple path has to read titles for this and
    /// misses "Augh birthday" typed into an ordinary calendar. Public holidays
    /// go by `PublicHolidays`, token by token, because Google copies them into
    /// primary calendars as ordinary events where no structural test can reach
    /// them.
    private static func record(for event: EventEntry, calendar: CalendarEntry) -> DistilledRecord? {
        let title = (event.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        guard event.eventType != "birthday" else { return nil }
        guard !PublicHolidays.matches(title) else { return nil }
        guard event.status != "cancelled" else { return nil }

        let isAllDay = event.start?.date != nil
        let start = event.start.flatMap(Self.date(from:))
        let end = event.end.flatMap(Self.date(from:))

        var extras: [String] = []
        extras.append("calendar=\(calendar.summary)")
        // **Stamped like the Apple path's, and it has to be.** A row with no
        // `cal_type` is not drawn on the events card at all — see
        // `ListeningHighlights` — so an unstamped Google row would be collected,
        // synced, and invisible.
        extras.append("cal_type=caldav")
        if let start {
            extras.append("start=\(iso.string(from: start))")
            let parts = Calendar.current.dateComponents([.weekday, .hour], from: start)
            if let weekday = parts.weekday {
                extras.append("weekday=\(weekday)")
                extras.append("weekend=\((weekday == 1 || weekday == 7) ? 1 : 0)")
            }
            if let hour = parts.hour { extras.append("hour=\(hour)") }
        }
        if let end {
            extras.append("end=\(iso.string(from: end))")
            if let start {
                extras.append("duration_min=\(Int(end.timeIntervalSince(start) / 60))")
            }
        }
        if isAllDay { extras.append("all_day=1") }
        if event.recurringEventId != nil { extras.append("recurring=1") }

        // The two fields that tell a booked ticket from a typed reminder.
        // `htmlLink` is Google's own link to the event and is on *everything*,
        // so it is not evidence — the location and an organizer who is not the
        // user are. Eventbrite, Ticketmaster and Dice all write themselves in as
        // the organiser.
        let organiser = event.organizer?.displayName ?? event.organizer?.email
        let organiserIsSomebodyElse = event.organizer?.`self` != true && (organiser?.isEmpty == false)
        if let organiser, organiserIsSomebodyElse {
            extras.append("organizer=\(organiser)")
            extras.append("booked=1")
        }

        return DistilledRecord(
            source: "google_calendar",
            dataType: "event",
            // The series id where there is one, so a re-distill updates the row
            // rather than adding an occurrence — the same promise
            // `calendarItemIdentifier` makes on the Apple side.
            itemID: event.recurringEventId ?? event.id,
            name: title,
            creator: organiser ?? calendar.summary,
            detail: event.location ?? "",
            extra: extras.joined(separator: ";"),
            collectedAt: Date()
        )
    }

    private static func record(for calendar: CalendarEntry) -> DistilledRecord {
        DistilledRecord(
            source: "google_calendar",
            dataType: "calendar",
            itemID: calendar.id,
            name: calendar.summary,
            creator: "",
            detail: "",
            extra: "type=caldav;primary=\(calendar.primary == true ? 1 : 0)",
            collectedAt: Date()
        )
    }

    private static func date(from when: EventEntry.When) -> Date? {
        if let dateTime = when.dateTime { return rfc3339.date(from: dateTime) ?? iso.date(from: dateTime) }
        // An all-day event carries a bare `2026-08-05`, which neither formatter
        // above will read.
        if let day = when.date { return dayOnly.date(from: day) }
        return nil
    }

    private static let iso = ISO8601DateFormatter()
    private static let rfc3339: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let dayOnly: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter
    }()
}
