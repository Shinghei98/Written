import Foundation

/// Turns distilled health records into the figures the dashboard's lifestyle
/// card shows. Pure and stateless, like `MusicHighlights` and `MediaHighlights`.
enum LifestyleHighlights {

    /// When this person's day starts, and how reliably.
    struct Chronotype {
        /// Minutes past midnight, median across the days we have.
        let medianWakeMinutes: Int
        /// Median absolute deviation, in minutes. A consistent 07:00 riser and
        /// someone averaging 07:00 across 05:00 and 09:00 are different people,
        /// and only the spread tells them apart.
        let spreadMinutes: Int
        let label: String
        /// How many days the figures rest on, so the card can be honest about it.
        let days: Int

        var wakeTime: String {
            String(format: "%02d:%02d", medianWakeMinutes / 60, medianWakeMinutes % 60)
        }

        /// Which mark to draw — one per band, off the *same* thresholds the
        /// label uses.
        ///
        /// It used to be a single `isMorning` boolean split at 08:00, which gave
        /// four labels two symbols: Early riser and Morning person were drawn
        /// identically, so were Steady starter and Late riser, and the one
        /// distinction it did draw put a moon over someone who gets up at 8:30.
        /// Sharing the thresholds is what stops the mark and the words ever
        /// disagreeing.
        var phase: Phase {
            switch medianWakeMinutes {
            case ..<earlyRiserBefore: return .dawn
            case ..<morningPersonBefore: return .morning
            case ..<steadyStarterBefore: return .lateMorning
            default: return .night
            }
        }
    }

    /// The sun's position when this person gets up, which is the thing the
    /// bands are really describing.
    enum Phase {
        /// Before 06:30 — up before the sun is properly out.
        case dawn
        /// 06:30–08:00.
        case morning
        /// 08:00–10:00. Not nocturnal; just a softer start.
        case lateMorning
        /// 10:00 onward.
        case night
    }

    struct Sport: Identifiable, Hashable {
        var id: String { name }
        let name: String
        let sessions: Int
        let minutes: Int
    }

    // MARK: - The labels, which are a draft

    /// **Draft thresholds — the thing to argue about**, in minutes past midnight.
    /// They are a reading of what an hour *means* socially, not a measurement of
    /// anything, and they should be checked against real distillations before
    /// anybody's profile carries one.
    static let earlyRiserBefore = 6 * 60 + 30
    static let morningPersonBefore = 8 * 60
    static let steadyStarterBefore = 10 * 60

    /// Below this many dated days, no label at all. A confident "night owl" off
    /// three days is worse than saying nothing.
    static let minimumDays = 7

    static func label(forWakeMinutes minutes: Int) -> String {
        switch minutes {
        case ..<earlyRiserBefore: return "Early riser"
        case ..<morningPersonBefore: return "Morning person"
        case ..<steadyStarterBefore: return "Steady starter"
        default: return "Late riser"
        }
    }

    // MARK: - Reading the records

    /// `nil` when there aren't enough dated days to say anything.
    static func chronotype(in records: [DistilledRecord]) -> Chronotype? {
        let wakes = records
            .filter { $0.source == "health" && $0.dataType == "activity_day" }
            .compactMap { minutes(fromClock: $0.extraValue("first_move")) }
            .sorted()

        guard wakes.count >= minimumDays else { return nil }

        let middle = median(of: wakes)
        // Deviation from the median rather than the mean: one 05:00 airport run
        // shouldn't widen the spread the way it would widen a variance.
        let deviations = wakes.map { abs($0 - middle) }.sorted()

        return Chronotype(
            medianWakeMinutes: middle,
            spreadMinutes: median(of: deviations),
            label: label(forWakeMinutes: middle),
            days: wakes.count
        )
    }

    /// Share of the day's steps in each hour, 0…23, normalized to the busiest
    /// hour so the tallest bar is full height.
    static func hourlyActivity(in records: [DistilledRecord]) -> [Double] {
        var shares = [Double](repeating: 0, count: 24)
        for record in records where record.source == "health" && record.dataType == "activity_hour" {
            guard let hour = record.extraValue("hour").flatMap(Int.init), (0..<24).contains(hour),
                  let share = record.extraValue("share").flatMap(Double.init) else { continue }
            shares[hour] = share
        }
        guard let peak = shares.max(), peak > 0 else { return [] }
        return shares.map { $0 / peak }
    }

    /// Steps on a typical day. Mean rather than median: this is a volume, and a
    /// rest day is part of the volume rather than an outlier to be shrugged off
    /// the way a 5am airport run is when reading a habit *time*.
    static func averageDailySteps(in records: [DistilledRecord]) -> Int? {
        let daily = records
            .filter { $0.source == "health" && $0.dataType == "activity_day" }
            .compactMap { $0.extraValue("steps").flatMap(Int.init) }
        guard !daily.isEmpty else { return nil }
        return daily.reduce(0, +) / daily.count
    }

    /// Sports by how often they were done, most first. Ties break on name, so
    /// the order doesn't shuffle between renders.
    static func topSports(in records: [DistilledRecord], limit: Int = 4) -> [Sport] {
        var sessions: [String: Int] = [:]
        var minutes: [String: Int] = [:]

        for record in records where record.source == "health" && record.dataType == "workout"
            // Struck off by the user; the row keeps its note and stops counting.
            && !record.isRemovedByUser {
            let name = record.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            sessions[name, default: 0] += 1
            minutes[name, default: 0] += record.extraValue("duration_min").flatMap(Int.init) ?? 0
        }

        var ranked = sessions.map { Sport(name: $0.key, sessions: $0.value, minutes: minutes[$0.key] ?? 0) }
        ranked.sort { left, right in
            left.sessions == right.sessions ? left.name < right.name : left.sessions > right.sessions
        }
        return Array(ranked.prefix(limit))
    }

    // MARK: - Small maths

    /// `HH:MM` → minutes past midnight.
    private static func minutes(fromClock clock: String?) -> Int? {
        guard let clock else { return nil }
        let parts = clock.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else { return nil }
        return hour * 60 + minute
    }

    /// Assumes `values` is sorted. Even counts average the middle pair.
    ///
    /// Taking the lower one instead collapses the spread of a evenly split
    /// habit to zero: someone alternating 05:00 and 09:00 has deviations of
    /// five 0s and five 240s, whose lower-middle is 0 — reported as "give or
    /// take no time at all", which is precisely the person the spread exists to
    /// catch.
    ///
    /// These are minutes past midnight, so a sleeper whose times straddle
    /// midnight would need circular statistics to be described properly. Nobody
    /// in that position is being served well by a single number anyway.
    private static func median(of values: [Int]) -> Int {
        guard !values.isEmpty else { return 0 }
        let middle = values.count / 2
        if values.count % 2 == 1 { return values[middle] }
        return (values[middle - 1] + values[middle]) / 2
    }
}
