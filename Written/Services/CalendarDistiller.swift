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

    func distill() async throws -> [DistilledRecord] {
        guard try await requestAccess() else { throw CalendarError.notAuthorized }

        let calendars = store.calendars(for: .event)
        var records = calendars.map(Self.record(for:))
        records += try await events(in: calendars)
        return records
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
            var windowStart = start

            while windowStart < end {
                let windowEnd = min(
                    calendar.date(byAdding: .year, value: 1, to: windowStart) ?? end,
                    end
                )
                let predicate = store.predicateForEvents(
                    withStart: windowStart, end: windowEnd, calendars: calendars
                )
                for event in store.events(matching: predicate) {
                    guard records.count < AppConfig.maxCalendarEvents else { return records }
                    let record = Self.record(for: event)
                    // A repeating event yields one occurrence per instance and
                    // the identifier is shared across them, so without this a
                    // weekly standup becomes fifty-two rows that say one thing.
                    // The first occurrence in the window wins.
                    guard seen.insert(record.itemID).inserted else { continue }
                    records.append(record)
                }
                windowStart = windowEnd
            }
            return records
        }.value
    }

    // MARK: - Normalization

    private static func record(for event: EKEvent) -> DistilledRecord {
        var extras: [String] = []
        extras.append("calendar=\(event.calendar?.title ?? "")")
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
        // The two fields that tell a booked ticket from a typed reminder.
        // Eventbrite, Ticketmaster and Dice all write a URL back; almost nothing
        // a person types by hand has one.
        if let url = event.url?.absoluteString, !url.isEmpty {
            extras.append("url=\(url)")
            extras.append("booked=1")
        }
        if let organizer = event.organizer?.name, !organizer.isEmpty {
            extras.append("organizer=\(organizer)")
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
