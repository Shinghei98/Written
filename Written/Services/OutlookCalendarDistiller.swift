import Foundation

/// Outlook and Microsoft 365 calendars, through Microsoft Graph v1.0.
///
/// **The third calendar provider, and deliberately the least original.** Its
/// whole job is to produce the same `DistilledRecord` shape `CalendarDistiller`
/// and `GoogleCalendarDistiller` produce, so that nothing downstream learns a
/// third vocabulary: same `data_type`, same `extra` keys, same booked-against-
/// typed distinction, one row per recurring series. Outlook is a measurement of
/// the same thing, not a second kind of thing.
///
/// **`calendarView`, not `/events`.** The events endpoint returns single
/// instances *and* recurring-series masters, leaving the caller to work out how
/// often something actually happened. `calendarView` expands a window into the
/// occurrences that fall inside it, which is what frequency evidence needs —
/// and it is why this file collapses a series back to one row afterwards rather
/// than trying to reconstruct it.
///
/// **`$select` is data minimisation, not bandwidth.** `body`, `bodyPreview`,
/// `attendees`, `attachments`, `onlineMeeting` and `webLink` are all available
/// and none is requested. The one field asked for beyond the obvious is
/// `sensitivity`, which exists so the private and confidential ones can be
/// dropped before anything reads a title.
///
/// **Not in `AppConfig.semanticIngestionSources`, and that is not an
/// oversight.** Six functions in `semantic_private` name `apple_calendar` and
/// `google_calendar` by literal — among them
/// `guard_private_source_generic_lane_v03`, which bars exactly those two and
/// HealthKit from the generic mention and feedback lanes. An `outlook_calendar`
/// observation is not in those lists, so it would *not* be barred: calendar
/// titles could enter the lane the other calendars are explicitly kept out of.
/// Until those guards learn the third source code, this writes to
/// `distilled_records` only.
struct OutlookCalendarDistiller {

    enum CalendarError: LocalizedError {
        case notConnected
        case tenantRefused
        case server(String)

        var errorDescription: String? {
            switch self {
            case .notConnected:
                return "Connect Outlook Calendar first."
            case .tenantRefused:
                // **Not "connection failed".** `Calendars.ReadBasic` does not
                // normally need administrator consent, but an organisation can
                // forbid consenting to an unverified publisher — so a work or
                // university account can sign in perfectly and still be
                // refused. That is somebody's IT department, not a broken app,
                // and saying so is the difference between a person retrying
                // forever and a person moving on.
                return "Your Microsoft organisation doesn't allow this connection. "
                     + "You can continue without Outlook Calendar."
            case .server(let detail):
                return detail
            }
        }
    }

    private let oauth: OAuthPKCEService

    init(oauth: OAuthPKCEService) {
        self.oauth = oauth
    }

    /// The same window the other two calendars use.
    ///
    /// Five years either side rather than the six months a narrower reading
    /// would suggest, because the evidence that matters most sits at the edges:
    /// a ticket bought today for November only exists ahead of now, and it was
    /// a flight to Los Angeles that disproved the old 365/180.
    private static var window: (from: Date, to: Date) {
        let now = Date()
        return (
            now.addingTimeInterval(-Double(AppConfig.calendarLookbackDays) * 86_400),
            now.addingTimeInterval(Double(AppConfig.calendarLookaheadDays) * 86_400)
        )
    }

    // MARK: - Graph shapes

    /// Internal rather than private so the parse can be exercised against a
    /// recorded Graph response without a tenant — see `shape(calendars:)`.
    struct CalendarEntry: Decodable {
        var id: String
        var name: String?
    }

    struct EventEntry: Decodable {
        struct When: Decodable {
            var dateTime: String?
            /// Graph states the zone separately rather than in the string, so a
            /// timestamp parsed without it is silently wrong by hours.
            var timeZone: String?
        }
        var id: String
        var iCalUId: String?
        var subject: String?
        var start: When?
        var end: When?
        var isAllDay: Bool?
        var isCancelled: Bool?
        /// `normal | personal | private | confidential`.
        var sensitivity: String?
        var categories: [String]?
        var showAs: String?
        /// `singleInstance | occurrence | exception | seriesMaster`.
        var type: String?
        var seriesMasterId: String?
    }

    // MARK: - Distillation

    func distill() async throws -> [DistilledRecord] {
        // Throws rather than answering nil: an empty calendar and a revoked
        // grant must not look the same.
        let token = try await oauth.validAccessToken()

        var fetched: [(CalendarEntry, [EventEntry])] = []
        for calendar in try await calendars(token: token) {
            // The same exclusion the other two make, by the same shared test —
            // a holidays or birthdays calendar is generated rather than
            // arranged, whoever generated it. Tested before the events are
            // fetched, so an excluded calendar costs no requests.
            if CalendarDistiller.isGenerated(calendar.name ?? "") { continue }
            fetched.append((calendar, try await events(in: calendar.id, token: token)))
        }
        return Self.shape(calendars: fetched)
    }

    /// Everything `distill()` does once the bytes are in hand.
    ///
    /// **Split from the fetch so it can be run without a tenant.** Registering
    /// an Entra application turned out to be days of Microsoft account
    /// plumbing, and the parse is where the defects actually live — the fetch
    /// is `OAuthPKCEService` and `URLSession`, both exercised by four other
    /// sources. `-probe-outlook` drives this against a recorded `calendarView`
    /// response, so the first real sign-in tests authentication alone.
    static func shape(calendars: [(CalendarEntry, [EventEntry])]) -> [DistilledRecord] {
        var records: [DistilledRecord] = []
        var seen = Set<String>()

        for (calendar, events) in calendars {
            let name = calendar.name ?? ""
            if CalendarDistiller.isGenerated(name) { continue }

            records.append(Self.record(for: calendar))

            for event in events {
                guard let record = Self.record(for: event, calendarName: name) else {
                    continue
                }
                // **One row per series, not per occurrence.** `calendarView`
                // expands a weekly stand-up into hundreds; keeping them all
                // would drown a year of real plans in one recurring meeting and
                // would count that meeting hundreds of times as evidence. The
                // occurrence is what proves it recurs, which `recurring=1`
                // records; the series is what it is.
                guard seen.insert(record.itemID).inserted else { continue }
                records.append(record)
                if records.count >= AppConfig.maxCalendarEvents { return records }
            }
        }
        return records
    }

    // MARK: - Requests

    private func calendars(token: String) async throws -> [CalendarEntry] {
        struct Page: Decodable { var value: [CalendarEntry]? }
        let data = try await get(
            "\(AppConfig.microsoftGraphBase)/me/calendars",
            query: ["$select": "id,name", "$top": "100"],
            token: token
        )
        return (try JSONDecoder().decode(Page.self, from: data)).value ?? []
    }

    private func events(in calendarID: String, token: String) async throws -> [EventEntry] {
        struct Page: Decodable {
            var value: [EventEntry]?
            /// Graph's own continuation. **Followed verbatim** — Microsoft says
            /// not to pull the skip token out and rebuild the URL, because the
            /// shape of that token is theirs to change.
            var nextLink: String?
            enum CodingKeys: String, CodingKey {
                case value
                case nextLink = "@odata.nextLink"
            }
        }

        var all: [EventEntry] = []
        // **Chunked, because `calendarView` refuses a span over 1,825 days** —
        // "The range between the start and end dates is greater than allowed
        // range. Maximum number of days: 1825." The window here is five years
        // either side of today, which is 3,650, so a single request is refused
        // outright and the whole source reads as broken.
        //
        // The same limit exists on the Apple path for a different reason and
        // with a worse failure: `predicateForEvents` returns an *empty list and
        // no error* past four years, which is indistinguishable from somebody
        // with no plans. Graph at least says so.
        //
        // **Walked outward from today, not oldest-first**, which is the lesson
        // `CalendarDistiller` already paid for: a decade of standing meetings
        // fills `maxCalendarEvents` somewhere in the past and the walk stops
        // before reaching anything ahead of now, losing exactly the booked trip
        // the wide window exists for. Walked outward, a cap costs the furthest
        // year in either direction.
        for chunk in Self.windowChunks() {
            let fetched = try await events(
                in: calendarID, from: chunk.from, to: chunk.to, token: token
            )
            all.append(contentsOf: fetched)
            if all.count >= AppConfig.maxCalendarEvents { break }
        }
        return all
    }

    /// The window split into year-long spans, ordered outward from today.
    ///
    /// A year rather than the 1,825-day maximum: the chunk size is what decides
    /// what a cap costs, and losing the furthest *year* is a smaller loss than
    /// losing the furthest five.
    private static func windowChunks() -> [(from: Date, to: Date)] {
        let now = Date()
        let year: TimeInterval = 365 * 86_400
        let back = Double(AppConfig.calendarLookbackDays) * 86_400
        let ahead = Double(AppConfig.calendarLookaheadDays) * 86_400

        var chunks: [(from: Date, to: Date)] = []
        var offset: TimeInterval = 0
        while offset < max(back, ahead) {
            let next = offset + year
            if offset < ahead {
                chunks.append((
                    now.addingTimeInterval(offset),
                    now.addingTimeInterval(min(next, ahead))
                ))
            }
            if offset < back {
                chunks.append((
                    now.addingTimeInterval(-min(next, back)),
                    now.addingTimeInterval(-offset)
                ))
            }
            offset = next
        }
        return chunks
    }

    private func events(
        in calendarID: String, from: Date, to: Date, token: String
    ) async throws -> [EventEntry] {
        struct Page: Decodable {
            var value: [EventEntry]?
            var nextLink: String?
            enum CodingKeys: String, CodingKey {
                case value
                case nextLink = "@odata.nextLink"
            }
        }

        let iso = ISO8601DateFormatter()
        var url: String? = "\(AppConfig.microsoftGraphBase)"
            + "/me/calendars/\(calendarID)/calendarView"
        var query: [String: String]? = [
            "startDateTime": iso.string(from: from),
            "endDateTime": iso.string(from: to),
            // Everything the record needs and nothing else. No body, no
            // attendees, no organiser, no attachments, no web link — the
            // minimisation `Calendars.Read` no longer performs for us.
            "$select": "id,iCalUId,subject,start,end,isAllDay,isCancelled,"
                     + "sensitivity,categories,showAs,type,seriesMasterId",
            "$top": "1000",
        ]

        var all: [EventEntry] = []
        // Bounded for the same reason every pagination here is: a loop with no
        // ceiling turns one broken continuation into an unbounded spend.
        for _ in 0..<AppConfig.maxPagesPerEndpoint {
            guard let next = url else { break }
            let data = try await get(next, query: query ?? [:], token: token)
            let page = try JSONDecoder().decode(Page.self, from: data)
            all.append(contentsOf: page.value ?? [])
            url = page.nextLink
            // The continuation already carries its own query string.
            query = nil
            if url == nil { break }
        }
        return all
    }

    private func get(
        _ url: String, query: [String: String], token: String
    ) async throws -> Data {
        var components = URLComponents(string: url)
        if !query.isEmpty {
            components?.queryItems = query.map {
                URLQueryItem(name: $0.key, value: $0.value)
            }
        }
        guard let requestURL = components?.url else {
            throw CalendarError.server("Bad URL for \(url).")
        }

        var request = URLRequest(url: requestURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // Graph returns the offsets it is given; asking for UTC keeps the
        // parsing here from depending on the account's home zone.
        request.setValue(
            "outlook.timezone=\"UTC\"", forHTTPHeaderField: "Prefer"
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0

        // **429 is a wait, not a failure.** Microsoft asks callers to honour
        // `Retry-After` rather than retrying immediately, and one obedient
        // retry is the difference between a distillation that finishes and one
        // that reads as broken.
        if status == 429 {
            let after = Double(http?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 2
            try await Task.sleep(nanoseconds: UInt64(min(after, 30) * 1_000_000_000))
            return try await get(url, query: query, token: token)
        }

        guard (200..<300).contains(status) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0?["error"] as? [String: Any])?["message"] as? String }
            // A tenant policy refusal arrives as 403 after a *successful* sign
            // in, which is why it cannot be reported as an authentication
            // problem.
            if status == 403 { throw CalendarError.tenantRefused }
            // **The body verbatim when it will not parse.** Graph explains a
            // 401 in words — "InvalidAuthenticationToken", "Access token
            // validation failure. Invalid audience." — and those sentences are
            // the difference between a diagnosis and an afternoon of guessing.
            // Reporting only the status code is this codebase's own recurring
            // defect: a call that failed, a reason nobody read.
            let raw = String(data: data, encoding: .utf8) ?? ""
            // **A 401 is about the token, so say what the token claims.**
            // Graph's message names the symptom ("InvalidAuthenticationToken")
            // and never the cause; `aud` and `scp` name the cause outright —
            // a token minted for the wrong resource, or minted without the
            // calendar scope, are different bugs with different fixes and are
            // indistinguishable from the status code alone.
            var diagnosis = detail ?? "Outlook Calendar said \(status)."
            if status == 401 {
                // **Everything at once, because one variable per attempt is how
                // this cost an evening.** Four hypotheses were tested serially
                // — permission type, scope string, stale consent, scope on
                // refresh — and each round needed a build, an install and a
                // person tapping a button. The token's length and prefix, the
                // URL actually requested and the body actually returned are the
                // whole state of the question.
                let claims = Self.claims(of: token)
                diagnosis += " | tokenLen=\(token.count)"
                diagnosis += " tokenHead=\(token.prefix(6))"
                diagnosis += " aud=\(claims["aud"] ?? "-") scp=\(claims["scp"] ?? "-")"
                diagnosis += " | scheme=\(requestURL.scheme ?? "-")"
                diagnosis += " host=\(requestURL.host ?? "-")"
                diagnosis += " path=\(requestURL.path)"
                // **The field that explains an empty-bodied 401.** Graph
                // answers a refused token with `WWW-Authenticate: Bearer
                // error="invalid_token", error_description="..."` and no body
                // at all in some cases, so the reason is in the header or
                // nowhere.
                // The *final* url, which differs from the requested one when
                // something redirected — and URLSession drops the
                // Authorization header across a redirect, which produces
                // exactly this signature: 401, no body, no challenge.
                diagnosis += " final=\(response.url?.host ?? "-")"
                let challenge = http?.value(forHTTPHeaderField: "WWW-Authenticate") ?? "-"
                diagnosis += " | challenge=\(challenge.prefix(220))"
                diagnosis += " | body=\(raw.isEmpty ? "(empty)" : String(raw.prefix(220)))"
            }
            throw CalendarError.server(diagnosis)
        }
        return data
    }

    // MARK: - Normalization

    /// Nil for anything that is not an arranged, readable event.
    static func record(for event: EventEntry, calendarName: String) -> DistilledRecord? {
        if event.isCancelled == true { return nil }

        // **`private` and `confidential` never reach a title read**, and
        // `personal` joins them for V1. The field exists precisely so the
        // owner's own classification can be honoured, and honouring it costs
        // only the events somebody already marked as not for sharing.
        let sensitivity = (event.sensitivity ?? "normal").lowercased()
        if sensitivity != "normal" { return nil }

        let title = (event.subject ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        // Holidays copied into a primary calendar as ordinary events, which no
        // calendar-level test can see. Shared with the other two paths.
        if PublicHolidays.matches(title) { return nil }

        var extras: [String] = []
        extras.append("calendar=\(calendarName)")
        // **Exchange, not caldav.** The Apple path stamps `caldav` for a server
        // calendar; naming the protocol honestly is what lets the Exchange
        // duplication be found later rather than guessed at.
        extras.append("cal_type=exchange")

        // **Said out loud rather than silently defaulted.** An unrecognised
        // zone name means the timestamps on this row are in UTC when they were
        // meant to be somewhere else, which is a wrong hour that looks exactly
        // like a right one. Stamping it is what makes it findable later.
        if let stated = event.start?.timeZone,
           !stated.isEmpty,
           Self.zone(named: stated) == nil {
            extras.append("tz_unresolved=\(stated)")
        }

        // `Calendar.current`, so `weekday` and `hour` mean the same thing here
        // as they do for Apple Calendar. Deriving them in the *event's* zone
        // would be defensible on its own — an evening event is an evening where
        // it happens — but it would make this connector disagree with the other
        // two feeding `ListeningHighlights.shape`, and one definition of
        // "evening" across three calendars is worth more than being right about
        // events somebody attended in another timezone.
        let iso = ISO8601DateFormatter()
        if let start = Self.parse(event.start) {
            extras.append("start=\(iso.string(from: start))")
            let parts = Calendar.current.dateComponents([.weekday, .hour], from: start)
            if let weekday = parts.weekday {
                extras.append("weekday=\(weekday)")
                extras.append("weekend=\((weekday == 1 || weekday == 7) ? 1 : 0)")
            }
            if let hour = parts.hour { extras.append("hour=\(hour)") }

            if let end = Self.parse(event.end) {
                extras.append("end=\(iso.string(from: end))")
                if end > start {
                    extras.append("duration_min=\(Int(end.timeIntervalSince(start) / 60))")
                }
            }
        }

        if event.isAllDay == true { extras.append("all_day=1") }
        if event.seriesMasterId != nil || event.type == "occurrence"
            || event.type == "exception" {
            extras.append("recurring=1")
        }
        if let categories = event.categories, !categories.isEmpty {
            extras.append("categories=\(categories.prefix(6).joined(separator: "|"))")
        }
        if let showAs = event.showAs, !showAs.isEmpty {
            extras.append("show_as=\(showAs)")
        }

        // **No `booked=1`, and this is the honest gap in the source.**
        // `booked` on the other two paths comes from an organiser and a
        // ticketing `url` — the two fields that tell a booking somebody paid
        // for from a reminder they typed. `Calendars.ReadBasic` returns
        // neither, by design, and asking for `Calendars.Read` to get them would
        // also hand over every event body. So every Outlook event resolves to
        // `scheduled`, and the strongest claim the calendar source can make is
        // one this provider cannot make at all. Worth revisiting only if
        // `booked` turns out to carry the source.

        return DistilledRecord(
            source: "outlook_calendar",
            dataType: "event",
            // The series where there is one, so the same weekly event is one
            // row across every occurrence in the window. `iCalUId` is stable
            // across calendars where Graph supplies it.
            itemID: event.seriesMasterId ?? event.iCalUId ?? event.id,
            name: title,
            // Deliberately empty. The other paths put an organiser here; this
            // scope returns none, and inventing a value would make the column
            // mean two things.
            creator: "",
            detail: "",
            extra: extras.joined(separator: ";"),
            collectedAt: Date()
        )
    }

    /// The calendar itself — a container, and the semantic layer treats it as
    /// one: no action, no evidence, captured because it explains the rows.
    static func record(for calendar: CalendarEntry) -> DistilledRecord {
        DistilledRecord(
            source: "outlook_calendar",
            dataType: "calendar",
            itemID: calendar.id,
            name: calendar.name ?? "",
            creator: "",
            detail: "",
            extra: "type=exchange;subscribed=0",
            collectedAt: Date()
        )
    }

    /// Graph sends `2026-08-13T09:00:00.0000000` with the zone in a sibling
    /// field, so the fractional seconds have to be tolerated and the `Z` is
    /// supplied by the `Prefer: outlook.timezone="UTC"` header rather than by
    /// the string.
    /// **The zone is a separate field and must be read, not assumed.**
    ///
    /// Graph writes `dateTime` with no offset in it — `2026-08-20T19:30:00.0000000`
    /// — and states the zone beside it. The first version of this function took
    /// the string alone and appended `Z`, so a 19:30 Hong Kong dinner was stored
    /// as 19:30 UTC: eight hours out, in a field nothing downstream can sanity
    /// check, with `hour=` and `weekday=` derived from it and therefore wrong
    /// too. `EventEntry.When` carried a comment warning of exactly this while
    /// the parse ignored it.
    ///
    /// **`Prefer: outlook.timezone="UTC"` is sent on every request, so in
    /// practice the zone comes back UTC and the naive version would have been
    /// right nearly always** — which is the argument for fixing it rather than
    /// leaving it. A bug that only appears when Microsoft declines a preference
    /// header is one nobody would find.
    static func parse(_ when: EventEntry.When?) -> Date? {
        guard let raw = when?.dateTime, !raw.isEmpty else { return nil }
        // Seven fractional digits, which nothing here reads and which
        // `ISO8601DateFormatter` rejects in some combinations. Seconds are the
        // finest granularity anything downstream asks for.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.timeZone = zone(named: when?.timeZone) ?? .gmt
        return formatter.date(from: String(raw.prefix(19)))
    }

    /// The access token's own claims, for diagnosing a refusal.
    ///
    /// A Microsoft access token is a JWT and its payload is base64url in the
    /// middle segment — readable without verification, which is all that is
    /// wanted here. **Nothing branches on this**: it is only ever put in an
    /// error message, so a token shape that fails to decode costs a diagnosis
    /// rather than a distillation.
    static func claims(of token: String) -> [String: String] {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return [:] }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else { return [:] }
        return dictionary.compactMapValues { value in
            (value as? String) ?? (value as? CustomStringConvertible)?.description
        }
    }

    /// Nil for a zone name this platform does not recognise, which is a real
    /// case: Graph can answer with Windows names like `China Standard Time`
    /// rather than IANA ones. Nil is not treated as UTC silently — the caller
    /// stamps `tz_unresolved=` so a wrong hour is visible in the row instead of
    /// being indistinguishable from a right one.
    static func zone(named name: String?) -> TimeZone? {
        guard let name, !name.isEmpty else { return nil }
        if name.caseInsensitiveCompare("UTC") == .orderedSame { return .gmt }
        return TimeZone(identifier: name) ?? TimeZone(abbreviation: name)
    }
}
