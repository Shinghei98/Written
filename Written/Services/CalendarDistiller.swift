import EventKit
import Foundation

/// Distills Apple Calendar: the events someone keeps, and the calendars they
/// keep them in.
///
/// **Not in `written_api.xlsx`** — the first source that isn't. The idea is that
/// a calendar collects two kinds of signal that nothing else here reaches:
///
/// - **Tickets book themselves in.** Eventbrite, Ticketmaster, Dice and the rest
///   push a confirmed booking straight into the calendar, so a gig someone
///   actually paid to attend arrives without them lifting a finger. That is a
///   far stronger claim than a followed artist or a liked video — it cost money
///   and a Saturday. `url` and `organizer` are kept for exactly this reason:
///   they are what tells a booked event apart from a typed one.
/// - **What people write down themselves.** "Climbing with Sam", "book club",
///   "physio" — a record of how someone actually spends time, in their own
///   words, which is the behaviour the rest of the distillation only infers.
///
/// Friction profile: one system permission sheet and no login, like HealthKit.
/// Unlike HealthKit it works fully in the simulator, though a fresh simulator's
/// calendar is empty.
///
/// **This stores event titles, locations and organisers, and syncs them.** That
/// is a deliberate choice — the titles *are* the signal, and reducing them to
/// counts the way Health is reduced would throw away the thing worth having. It
/// does mean the database holds other people's names and places they were, from
/// people who never agreed to that. `PrivacyInfo.xcprivacy` says so, and if the
/// balance is ever revisited, `keptTypes` in `DistillViewModel` is the shape of
/// the alternative.
struct CalendarDistiller {

    enum CalendarError: LocalizedError {
        case notAuthorized
        case noData

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return "Calendar access was not granted. You can enable it in Settings → Written."
            case .noData:
                return "No calendar events were found. If you use iCloud calendars, check they're switched on for this iPhone."
            }
        }
    }

    private let store = EKEventStore()

    /// Whether calendar access is refused in a way only Settings can undo.
    ///
    /// Answers without prompting, which is the whole point: a refusal used to be
    /// discovered by tapping Connect and waiting for a distillation to come back
    /// with nothing, and the message arrived after the wait rather than instead
    /// of it.
    ///
    /// `.notDetermined` is deliberately *not* blocked — that is an ordinary
    /// first run, and the sheet is about to be shown. `.writeOnly` is, because
    /// on iOS 17 it reads nothing at all while looking exactly like an empty
    /// calendar; it is the same trap `requestFullAccessToEvents` exists to
    /// avoid, seen from the other side.
    static var isBlocked: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(iOS 17.0, *), status == .writeOnly { return true }
        return status == .denied || status == .restricted
    }

    func distill() async throws -> [DistilledRecord] {
        guard try await requestAccess() else { throw CalendarError.notAuthorized }

        let calendars = store.calendars(for: .event)
        var records = calendars.map(Self.record(for:))
        records += try await events(in: calendars.filter(Self.isPersonal))
        return records
    }

    /// Whether a calendar's events say anything about *this* person.
    ///
    /// **Subscribed calendars are excluded, and that is the whole point of
    /// having this.** A public calendar — national holidays, a football
    /// fixture list, phases of the moon — is identical for everyone who
    /// subscribes to it, so its events carry no information about the
    /// subscriber while swamping the ones that do: a year of holidays is dozens
    /// of rows against a handful of things somebody actually arranged.
    ///
    /// Birthdays go too. They are generated from Contacts rather than arranged,
    /// and every one of them is another person's name — which this table already
    /// stores more of than is comfortable.
    ///
    /// The *calendar list* is still recorded in full by `record(for:)` above:
    /// which calendars exist is a fact about the person, and it is one row each
    /// rather than hundreds.
    ///
    /// **The type is not enough on its own.** iOS's own holiday calendar is a
    /// subscription and is caught by it, but the same holidays arriving through
    /// a Google or Exchange account are `.calDAV` — an ordinary type, from a
    /// server, indistinguishable by type from a real diary. So the name is
    /// checked too.
    ///
    /// Matching on a name is worse than matching on a type and is used only
    /// where there is nothing better: it is English, so a phone in another
    /// language keeps its holidays. That is a smaller failure than dropping a
    /// calendar somebody actually uses, which is why the test is narrow — a
    /// calendar *called* holidays or birthdays, not one containing the word.
    static func isPersonal(_ calendar: EKCalendar) -> Bool {
        guard calendar.type != .subscription, calendar.type != .birthday else { return false }
        return !isGenerated(calendar.title)
    }

    /// Whether this phone is already supplying calendars from a Google account.
    ///
    /// **This is what decides whether connecting Google Calendar is worth
    /// offering at all.** A Google account added in iOS Settings delivers its
    /// events through EventKit as `caldav` — which is why the public-holiday
    /// filter cannot rely on calendar type — so for those people the API would
    /// collect the same dinner a second time, under a different `item_id` and a
    /// different `source`. `append_source_records` dedupes *within* a source and
    /// would not catch it: the ontology stage would see everything twice.
    ///
    /// Where a Google account is already here, the API adds nothing. Where none
    /// is, it is the only way to reach those events. That is also the honest
    /// answer to Google's "why do you need this scope" — *only for users whose
    /// calendar we cannot otherwise see*.
    ///
    /// **Matched on the source, not the calendar.** A Google account arrives as
    /// an `EKSource`, and its calendars are named whatever the person named
    /// them — "Work", "家庭" — so the account is the only thing that identifies
    /// itself. `sourceType` is `.calDAV` for Google, Fastmail and any other
    /// CalDAV server alike, hence the title test as well.
    ///
    /// Returns false when calendar access has not been granted: with nothing
    /// readable there is no evidence either way, and the safer answer is to let
    /// somebody connect a source that turns out to be redundant rather than to
    /// hide one they needed.
    static func hasGoogleAccountOnDevice() -> Bool {
        guard !isBlocked else { return false }
        return EKEventStore().sources.contains { source in
            guard source.sourceType == .calDAV || source.sourceType == .subscribed
            else { return false }
            let title = source.title.lowercased()
            return title.contains("gmail")
                || title.contains("google")
                || title.contains("googlemail")
        }
    }

    /// Whether a calendar's name marks it as generated rather than arranged.
    ///
    /// Shared with the dashboard, which has to apply the same test to rows
    /// already in the database — see `ListeningHighlights`. One definition,
    /// because two that drifted would mean the card and the distiller disagreed
    /// about what a personal calendar is.
    static func isGenerated(_ title: String) -> Bool {
        let name = title.lowercased()
        // English, plus the one other form there is direct evidence of: a real
        // device carried 37 rows from `香港节假日`. Both Chinese scripts, since
        // the simplified and traditional forms differ by one character and a
        // phone set to either will produce its own.
        //
        // This list will always be incomplete, which is why it is the *last*
        // test rather than the only one — everything with a `cal_type` is
        // settled before it, and an untyped row is not drawn at all.
        return name.contains("holiday")
            || name.contains("birthday")
            || name.contains("节假日")
            || name.contains("節假日")
    }

    /// iOS 17 split calendar access into full and write-only, and asking with
    /// the old call there returns write-only — which reads nothing and looks
    /// exactly like an empty calendar.
    private func requestAccess() async throws -> Bool {
        if #available(iOS 17.0, *) {
            return try await store.requestFullAccessToEvents()
        }
        return try await withCheckedThrowingContinuation { continuation in
            store.requestAccess(to: .event) { granted, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: granted) }
            }
        }
    }

    // MARK: - Events

    /// Events across the configured window, a year at a time.
    ///
    /// **`predicateForEvents` will not span more than four years**, and rather
    /// than failing it quietly returns nothing — the same shape of bug as the
    /// HealthKit reads that came back empty for months. Chunking by year keeps
    /// every request comfortably inside that and keeps each one small.
    ///
    /// That chunking used to be insurance against a limit the window never
    /// approached. At five years either side it is **the only reason anything
    /// comes back at all**: a single ten-year predicate returns an empty list
    /// and no error, which looks exactly like a person with no plans.
    ///
    /// Both directions on purpose: the past is what someone did, the future is
    /// what they have committed to, and a ticket bought today for a gig in
    /// November only exists ahead of now.
    private func events(in calendars: [EKCalendar]) async throws -> [DistilledRecord] {
        guard !calendars.isEmpty else { return [] }

        let now = Date()
        let calendar = Calendar.current
        guard let start = calendar.date(byAdding: .day, value: -AppConfig.calendarLookbackDays, to: now),
              let end = calendar.date(byAdding: .day, value: AppConfig.calendarLookaheadDays, to: now)
        else { return [] }

        // EventKit's fetch is synchronous and can take a moment on a busy
        // calendar, so it happens off the main actor.
        let store = self.store
        return await Task.detached(priority: .userInitiated) { () -> [DistilledRecord] in
            var records: [DistilledRecord] = []
            var seen = Set<String>()

            // The year-long chunks, built up front so they can be ordered.
            var windows: [(start: Date, end: Date)] = []
            var cursor = start
            while cursor < end {
                let next = min(calendar.date(byAdding: .year, value: 1, to: cursor) ?? end, end)
                windows.append((cursor, next))
                cursor = next
            }

            // **Nearest to today first, and that is the cap's doing.** The walk
            // used to run oldest to newest and `return` on `maxCalendarEvents`,
            // which was harmless across an eighteen-month window and is not
            // across ten years: a decade of standing meetings would fill the
            // ceiling somewhere in 2021 and the fetch would stop before reaching
            // anything ahead of now — losing the booked trip that is the whole
            // reason the window was widened.
            //
            // Outward from today, a cap costs the furthest year in whichever
            // direction, which is the year worth losing.
            let now = now
            windows.sort {
                min(abs($0.start.timeIntervalSince(now)), abs($0.end.timeIntervalSince(now)))
                    < min(abs($1.start.timeIntervalSince(now)), abs($1.end.timeIntervalSince(now)))
            }

            for window in windows {
                let predicate = store.predicateForEvents(
                    withStart: window.start, end: window.end, calendars: calendars
                )
                let matched = store.events(matching: predicate)
                // **Archived before the cap and before the dedupe**, because
                // both are Written's readings rather than the calendar's
                // answer: `maxCalendarEvents` stops at a number and the
                // recurring-identifier dedupe keeps one occurrence of fifty-two.
                // An archive that inherited those would be a copy of what we
                // chose to look at, which is what `distilled_records` already is.
                if let payload = RawArchiveSerialiser.envelope(
                    source: "apple_calendar", kind: "event",
                    objects: matched.map(RawArchiveSerialiser.event)
                ) {
                    await RawArchive.shared.captureEncoded(
                        source: "apple_calendar", endpoint: "event", payload: payload
                    )
                }
                for event in matched {
                    guard records.count < AppConfig.maxCalendarEvents else { return records }
                    let record = Self.record(for: event)
                    // A repeating event yields one occurrence per instance and
                    // the identifier is shared across them, so without this a
                    // weekly standup becomes fifty-two rows that say one thing.
                    // The first occurrence in the window wins.
                    guard seen.insert(record.itemID).inserted else { continue }
                    records.append(record)
                }
            }
            return records
        }.value
    }

    // MARK: - Normalization

    private static func record(for event: EKEvent) -> DistilledRecord {
        var extras: [String] = []
        extras.append("calendar=\(event.calendar?.title ?? "")")
        // Recorded as well as filtered on. `distill` already declines to collect
        // subscribed and birthday calendars, but rows written before it did are
        // in the database and in every restore — so anything reading these needs
        // to be able to tell them apart without re-distilling.
        if let type = event.calendar?.type {
            extras.append("cal_type=\(Self.name(for: type))")
        }
        // **The account, because `cal_type` cannot tell iCloud from Google.**
        // Both arrive as `caldav`, so a reading that has only the type puts
        // somebody's whole iCloud diary under "Calendar" — measured on a real
        // device, 141 of 163 rows. The `EKSource` title is the one field that
        // knows: "iCloud", a gmail address, an Exchange account name. It is
        // what `ListeningHighlights.Event.Provider` reads first, and it is why
        // an Outlook event can say Outlook without a Microsoft connector.
        if let account = event.calendar?.source?.title, !account.isEmpty {
            extras.append("account=\(account)")
        }
        extras.append("start=\(iso.string(from: event.startDate ?? Date()))")
        if let end = event.endDate {
            extras.append("end=\(iso.string(from: end))")
            if let start = event.startDate {
                extras.append("duration_min=\(Int(end.timeIntervalSince(start) / 60))")
            }
        }
        if let start = event.startDate {
            // Pre-computed because they are what the signal actually is: a
            // Saturday evening is a different fact from a Tuesday morning, and
            // asking SQL to work that out of a timestamp is the sort of string
            // surgery `extra` exists to avoid.
            let components = Calendar.current.dateComponents([.weekday, .hour], from: start)
            if let weekday = components.weekday {
                extras.append("weekday=\(weekday)")
                extras.append("weekend=\((weekday == 1 || weekday == 7) ? 1 : 0)")
            }
            if let hour = components.hour { extras.append("hour=\(hour)") }
        }
        if event.isAllDay { extras.append("all_day=1") }
        if event.hasRecurrenceRules { extras.append("recurring=1") }
        // **`booked` means a transaction happened, not that a URL exists.**
        //
        // Measured on a real library: of four events carrying a URL, one was
        // `Ticket: Chichén Itzá Premier Tour` — the thing this flag is for —
        // and another was `All of Us meeting 03/10`, whose URL is a Zoom link.
        // Meanwhile all four flights, which cost money and a Saturday and are
        // the strongest travel evidence a calendar holds, carried no URL at all
        // and were not flagged. So the old test caught a conference call and
        // missed every flight.
        //
        // Three states rather than two, because "somebody else put this in my
        // diary" and "I paid for this" are different facts and only the second
        // is a preference:
        //
        //   typed    — no organizer, no url: the person wrote it themselves
        //   invited  — an organizer exists: somebody else's meeting
        //   booked   — a ticket, a flight, a reservation
        //
        // `invited` is stamped from the organizer's *existence*, which is a
        // fact rather than a reading. It is deliberately not `booked`: a
        // colleague's recurring Zoom says something about a working week and
        // nothing about what somebody chose to spend a Saturday on.
        if let url = event.url?.absoluteString, !url.isEmpty {
            extras.append("url=\(url)")
            if !Self.isConferencingURL(url) { extras.append("booked=1") }
        }
        if let organizer = event.organizer?.name, !organizer.isEmpty {
            extras.append("organizer=\(organizer)")
            extras.append("invited=1")
        }
        // **A flight is booked whether or not anything wrote a URL back.**
        // Apple parses airline mail into `Flight to Los Angeles (CX 880)` and
        // leaves the organizer as `Unknown Organizer` with no url — so without
        // this the four clearest purchases in the library read as typed
        // reminders. The pattern is the canonical title and nothing else,
        // matching `_FLIGHT_TITLE_RE` in the classifier: the space in `(UA 1103)`
        // is load-bearing, and "Flight to Los Angeles" without a carrier code
        // does not match, because that is somebody's note rather than a booking.
        if !extras.contains("booked=1"), Self.isBookedTravelTitle(event.title) {
            extras.append("booked=1")
        }
        if event.status == .canceled { extras.append("cancelled=1") }

        return DistilledRecord(
            source: "apple_calendar",
            dataType: "event",
            // Stable across distillations, unlike the per-occurrence id, so a
            // re-distill updates the row rather than adding one.
            itemID: event.calendarItemIdentifier,
            name: event.title ?? "",
            creator: event.organizer?.name ?? event.calendar?.title ?? "",
            detail: event.location ?? "",
            extra: extras.joined(separator: ";"),
            collectedAt: Date()
        )
    }

    /// Hosts whose URL means "join this call", never "you bought a thing".
    ///
    /// **Matched on the host, never on the whole string.** A ticket confirmation
    /// can legitimately mention a meeting elsewhere in its URL, and a substring
    /// test would refuse it — the same restraint `domainForCreatorTag` uses for
    /// tags. Incomplete by construction, like every list of this shape here: a
    /// conferencing host nobody has met yet reads as booked, which costs one
    /// false positive rather than a missed purchase.
    private static let conferencingHosts: Set<String> = [
        "zoom.us", "teams.microsoft.com", "teams.live.com", "meet.google.com",
        "webex.com", "gotomeeting.com", "whereby.com", "chime.aws",
        "bluejeans.com", "skype.com", "discord.com", "slack.com",
    ]

    static func isConferencingURL(_ raw: String) -> Bool {
        guard let host = URL(string: raw)?.host?.lowercased() else { return false }
        return conferencingHosts.contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    /// A title that names a flight Apple parsed out of an airline's mail.
    ///
    /// **The carrier code is what makes it a booking.** `Flight to Los Angeles`
    /// is a note somebody typed; `Flight to Los Angeles (CX 880)` is a boarding
    /// pass Apple read. The space inside the parentheses is load-bearing —
    /// `[A-Z0-9]{2,3}` is greedy and would otherwise swallow the digits — which
    /// is the same trap `_FLIGHT_TITLE_RE` records in the classifier, and this
    /// pattern deliberately mirrors it so the two cannot drift into disagreeing
    /// about what a flight is.
    private static let flightTitle = try? NSRegularExpression(
        pattern: "^Flight to .+ \\([A-Z0-9]{2,3} [0-9]{1,4}\\)$")

    static func isBookedTravelTitle(_ title: String?) -> Bool {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty, let flightTitle else { return false }
        let range = NSRange(title.startIndex..<title.endIndex, in: title)
        return flightTitle.firstMatch(in: title, range: range) != nil
    }

    private static func record(for calendar: EKCalendar) -> DistilledRecord {
        DistilledRecord(
            source: "apple_calendar",
            dataType: "calendar",
            itemID: calendar.calendarIdentifier,
            name: calendar.title,
            creator: calendar.source?.title ?? "",
            detail: "",
            // A subscribed calendar is somebody else's feed — a team fixture
            // list, a public holiday set — and means something different from
            // one the user keeps themselves.
            extra: "type=\(Self.name(for: calendar.type));subscribed=\(calendar.isSubscribed ? 1 : 0)",
            collectedAt: Date()
        )
    }

    private static func name(for type: EKCalendarType) -> String {
        switch type {
        case .local: return "local"
        case .calDAV: return "caldav"
        case .exchange: return "exchange"
        case .subscription: return "subscription"
        case .birthday: return "birthday"
        @unknown default: return "unknown"
        }
    }

    private static let iso = ISO8601DateFormatter()
}
