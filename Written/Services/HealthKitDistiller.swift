import Foundation
import HealthKit

/// Distills the signals listed for Apple Watch / HealthKit in written_api.xlsx:
/// recorded sport type and duration, and activity intensity and duration.
///
/// Read-only, and only the types below: HealthKit hands out authorization per
/// type, and asking for a heart-rate series or a sleep log we have no use for
/// would widen the permission sheet for nothing. What the ontology stage wants
/// from a body is *what this person does and how often* — not their vitals.
///
/// Friction, in the terms of the prime constraint: one system sheet, no login,
/// no password. Same shape as Apple Music.
struct HealthKitDistiller {

    /// One store for the app's lifetime, not one per distillation.
    ///
    /// Apple's guidance is explicit that an `HKHealthStore` should be created
    /// once and kept — its callbacks are delivered against the instance that
    /// made the request, and a short-lived store is a documented way to get a
    /// completion handler that never fires. `HealthKitDistiller` is a struct
    /// built fresh on every connect, so it was minting a new store each time.
    private static let sharedStore = HKHealthStore()

    private var store: HKHealthStore { Self.sharedStore }

    enum HealthError: LocalizedError {
        case unavailable
        /// Nothing came back. Named for the symptom rather than the cause on
        /// purpose: HealthKit never says which reads were refused, so a declined
        /// permission and an empty Health app are the same answer here, and the
        /// message has to cover both without guessing which one it is.
        case noData
        /// A query that failed or never returned, carrying which one it was, how
        /// long it ran and the underlying domain/code.
        ///
        /// The detail is kept but only *shown* in debug builds. It exists
        /// because "slow, and error 5" from a device said nothing about which of
        /// six queries was at fault — but `[com.apple.healthkit 5]` is not a
        /// sentence to put in front of a tester either.
        case stageFailed(String)

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "Apple Health isn't available on this device."
            case .stageFailed(let detail):
                let message = "Apple Health didn't respond. Try again — and if it keeps happening, "
                    + "check Health › Profile › Apps › Written, or Settings › Privacy & Security › Health."
                #if DEBUG
                return "\(message)\n[\(detail)]"
                #else
                return message
                #endif
            case .noData:
                // Names Privacy & Security first because that is the switch that
                // actually gates it — with Health off there, the permission
                // sheet never appears at all and the request simply never
                // returns, which is indistinguishable from the app being stuck.
                return "Nothing came back from Apple Health. Open Health › Profile › Apps › Written and turn the categories on — then try again. If they are already on, there may be no workouts or activity recorded yet, or Health itself may be switched off for Written under Settings › Privacy & Security."
            }
        }
    }

    /// Everything we ask to read. Workouts carry the sport and its duration;
    /// exercise minutes and active energy carry the intensity.
    private var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [
            HKObjectType.workoutType(),
            // Characteristics, not samples: written once when the user set up
            // Health, and read straight off the store rather than queried.
            HKObjectType.characteristicType(forIdentifier: .dateOfBirth),
            HKObjectType.characteristicType(forIdentifier: .biologicalSex)
        ].compactMap { $0 }.reduce(into: Set<HKObjectType>()) { $0.insert($1) }
        // `distanceWalkingRunning` is here because `workouts()` reads it for the
        // `distance_km` extra. It was queried without being requested, which is
        // the one mismatch that can make HealthKit answer
        // `errorAuthorizationNotDetermined` — asking for a type you never put in
        // front of the user is not a question they can have answered.
        for identifier: HKQuantityTypeIdentifier in [
            .appleExerciseTime, .activeEnergyBurned, .stepCount, .distanceWalkingRunning
        ] {
            if let type = HKObjectType.quantityType(forIdentifier: identifier) {
                types.insert(type)
            }
        }
        return types
    }

    func distill() async throws -> [DistilledRecord] {
        guard HKHealthStore.isHealthDataAvailable() else { throw HealthError.unavailable }

        // The sheet appears here. HealthKit deliberately doesn't tell us what
        // the user allowed for *reads* — a denied type reads as empty, which is
        // indistinguishable from having no data — so this only throws when the
        // request itself fails, and an empty distillation is reported below.
        //
        // Wrapped in `stage` like the queries, and that is not symmetry for its
        // own sake: this call once hung indefinitely, and because it sits before
        // every other stage the app simply spun with nothing to report.
        let store = self.store
        let types = readTypes
        try await Self.stage("authorize") {
            // The completion-handler API, bridged by hand, rather than the async
            // overload. `DistillViewModel` is `@MainActor`, so the async version
            // is awaited *from* the main actor — and HealthKit delivers this
            // particular callback on the main queue, which is the shape of a
            // deadlock: the main thread is suspended waiting for a result that
            // needs the main thread to arrive. Bridging explicitly means the
            // continuation resumes from HealthKit's own queue instead.
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                store.requestAuthorization(toShare: [], read: types) { _, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
        }

        // Two windows, because the two kinds of data cost wildly different
        // amounts to read and answer different questions.
        //
        // Workouts are *sparse* — a few hundred rows for a serious athlete, and
        // capped anyway — and they are where seasonality lives: the skier, the
        // summer swimmer. A year earns its keep.
        //
        // Quantity samples are *dense*. An Apple Watch writes active energy
        // every few minutes, so a year is hundreds of thousands of samples per
        // type, and `HKStatisticsCollectionQuery` must scan every one. What we
        // do with them — a median wake hour, an average step count, a 24-number
        // hour-of-day shape — is stationary, so the extra ten months buys
        // nothing the ontology stage can use and costs most of the wait.
        let workoutsSince = Self.date(daysAgo: AppConfig.healthWorkoutLookbackDays)
        let activitySince = Self.date(daysAgo: AppConfig.healthActivityLookbackDays)

        // Each stage is timed and its failure labelled. HealthKit has no timeout
        // of its own, so without this a query that never calls back leaves the
        // screen spinning forever with nothing to say.
        var records = demographics()
        records += try await Self.stage("workouts") { try await workouts(since: workoutsSince) }
        records += try await Self.stage("activity") { try await activityDays(since: activitySince) }
        return records
    }

    /// How long any one HealthKit call may take before it is treated as hung.
    ///
    /// HealthKit has no timeout of its own: a query whose completion handler is
    /// never called leaves the `withCheckedThrowingContinuation` suspended
    /// forever, and the screen spins with nothing to report. Twenty seconds is
    /// far past any legitimate query on these windows.
    private static let stageTimeout: TimeInterval = 20

    /// Runs one stage, and on failure rethrows an error naming the stage, the
    /// underlying domain/code and how long it ran. A stage that never returns
    /// is reported as a timeout rather than hanging the whole distillation.
    private static func stage<T: Sendable>(
        _ name: String, _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let started = Date()
        do {
            return try await withThrowingTaskGroup(of: T.self) { group in
                group.addTask { try await work() }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(stageTimeout * 1_000_000_000))
                    throw HealthError.stageFailed("\(name) timed out after \(Int(stageTimeout))s")
                }
                guard let first = try await group.next() else {
                    throw HealthError.stageFailed("\(name) returned nothing")
                }
                group.cancelAll()
                return first
            }
        } catch let error as HealthError {
            throw error
        } catch {
            let nsError = error as NSError
            throw HealthError.stageFailed(
                "\(name) failed after \(Self.seconds(since: started)) "
                    + "[\(nsError.domain) \(nsError.code)]"
            )
        }
    }

    private static func seconds(since date: Date) -> String {
        String(format: "%.1fs", Date().timeIntervalSince(date))
    }

    private static func date(daysAgo days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
    }

    // MARK: - Who they are

    /// Age and sex, which Health stores as *characteristics* rather than
    /// samples. Both throw when the user declined them, and a decline is a
    /// perfectly ordinary answer here — the rest of the distillation carries on
    /// without them rather than failing.
    private func demographics() -> [DistilledRecord] {
        var records: [DistilledRecord] = []
        let now = Date()

        if let components = try? store.dateOfBirthComponents(),
           let birthday = Calendar.current.date(from: components),
           let age = Calendar.current.dateComponents([.year], from: birthday, to: now).year,
           (0...130).contains(age) {
            records.append(
                DistilledRecord(
                    source: "health", dataType: "age", itemID: "age",
                    name: "\(age)", creator: "", detail: "",
                    // The year, not the date: an age is what the profile shows,
                    // and a full birth date is more than anything here needs.
                    extra: "birth_year=\(components.year.map(String.init) ?? "")",
                    collectedAt: now
                )
            )
        }

        if let sex = try? store.biologicalSex().biologicalSex, let label = Self.label(for: sex) {
            records.append(
                DistilledRecord(
                    source: "health", dataType: "biological_sex", itemID: "biological_sex",
                    name: label, creator: "", detail: "",
                    extra: "raw=\(sex.rawValue)", collectedAt: now
                )
            )
        }

        return records
    }

    /// `nil` for the two answers that aren't a label — Health's `.other` and
    /// `.notSet`. A profile row is better absent than filled with "Other".
    static func label(for sex: HKBiologicalSex) -> String? {
        switch sex {
        case .female: return "Female"
        case .male: return "Male"
        default: return nil
        }
    }

    // MARK: - Workouts

    /// One record per session: the sport, how long, how hard, and which device
    /// or app recorded it.
    private func workouts(since: Date) async throws -> [DistilledRecord] {
        let predicate = HKQuery.predicateForSamples(withStart: since, end: Date(), options: .strictStartDate)
        let samples: [HKSample] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: AppConfig.maxWorkouts,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
            ) { _, samples, error in
                // A read the user declined comes back as an empty set, not an
                // error, so nothing here treats "no workouts" as a failure.
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: samples ?? []) }
            }
            store.execute(query)
        }

        return samples.compactMap { sample in
            guard let workout = sample as? HKWorkout else { return nil }

            var extras = ["duration_min=\(Int((workout.duration / 60).rounded()))"]
            if let energy = workout.statistics(for: HKQuantityType(.activeEnergyBurned))?
                .sumQuantity()?.doubleValue(for: .kilocalorie()) {
                extras.append("energy_kcal=\(Int(energy.rounded()))")
            }
            if let distance = workout.statistics(for: HKQuantityType(.distanceWalkingRunning))?
                .sumQuantity()?.doubleValue(for: .meterUnit(with: .kilo)) {
                extras.append(String(format: "distance_km=%.2f", distance))
            }
            extras.append("started_at=\(Self.timestamp.string(from: workout.startDate))")

            return DistilledRecord(
                source: "health",
                dataType: "workout",
                itemID: workout.uuid.uuidString,
                name: Self.name(for: workout.workoutActivityType),
                // Which watch or app logged it — a Strava-tracked ride and a
                // Watch-tracked one are the same sport recorded by different
                // habits, and the ontology stage may care.
                creator: workout.sourceRevision.source.name,
                detail: Self.dayFormatter.string(from: workout.startDate),
                extra: extras.joined(separator: ";"),
                collectedAt: Date()
            )
        }
    }

    // MARK: - Daily activity

    /// One record per day: exercise minutes, active calories, steps.
    ///
    /// A day at a time rather than every sample, because "activity intensity and
    /// duration" is a pattern over weeks — and a year of raw samples would be
    /// hundreds of thousands of rows for no more meaning.
    private func activityDays(since: Date) async throws -> [DistilledRecord] {
        async let exercise = Self.stage("exerciseMin") {
            try await dailyTotals(.appleExerciseTime, unit: .minute(), since: since)
        }
        async let energy = Self.stage("activeEnergy") {
            try await dailyTotals(.activeEnergyBurned, unit: .kilocalorie(), since: since)
        }
        async let steps = Self.stage("stepsDaily") {
            try await dailyTotals(.stepCount, unit: .count(), since: since)
        }
        async let hours = Self.stage("stepsHourly") { try await hourlySteps(since: since) }

        let (exerciseByDay, energyByDay, stepsByDay, stepsByHour) = try await (exercise, energy, steps, hours)
        let days = Set(exerciseByDay.keys).union(energyByDay.keys).union(stepsByDay.keys)

        let firstMoves = firstMovements(in: stepsByHour)

        var records: [DistilledRecord] = days.sorted(by: >).map { day in
            var extras: [String] = []
            if let minutes = exerciseByDay[day] { extras.append("exercise_min=\(Int(minutes.rounded()))") }
            if let kcal = energyByDay[day] { extras.append("active_kcal=\(Int(kcal.rounded()))") }
            if let count = stepsByDay[day] { extras.append("steps=\(Int(count.rounded()))") }
            // When they got going. The proxy for a wake time — there is no API
            // for when a phone was first picked up, and sleep tracking only
            // exists for people who wear something to bed.
            if let move = firstMoves[Calendar.current.startOfDay(for: day)] {
                extras.append("first_move=\(String(format: "%02d:00", move))")
            }

            let label = Self.dayFormatter.string(from: day)
            return DistilledRecord(
                source: "health",
                dataType: "activity_day",
                itemID: label,
                name: label,
                creator: "",
                detail: "",
                extra: extras.joined(separator: ";"),
                collectedAt: Date()
            )
        }

        records += hourProfile(from: stepsByHour)
        return records
    }

    /// Twenty-four records, one per hour of the clock — the shape of the
    /// person's day, summed over the window.
    ///
    /// A row per hour *of the window* would be 8,760 of them for a year and say
    /// nothing more: the question is which hours they are active in, not what
    /// they did at 3pm last March.
    private func hourProfile(from stepsByHour: [Date: Double]) -> [DistilledRecord] {
        var totals = [Double](repeating: 0, count: 24)
        for (date, steps) in stepsByHour {
            totals[Calendar.current.component(.hour, from: date)] += steps
        }
        let overall = totals.reduce(0, +)
        guard overall > 0 else { return [] }

        return (0..<24).map { hour in
            let label = String(format: "%02d:00", hour)
            return DistilledRecord(
                source: "health",
                dataType: "activity_hour",
                itemID: label,
                name: label,
                creator: "",
                detail: "",
                extra: "hour=\(hour);steps=\(Int(totals[hour].rounded()));"
                    + String(format: "share=%.4f", totals[hour] / overall),
                collectedAt: Date()
            )
        }
    }

    /// The first hour of each day that clears the step threshold, keyed by the
    /// day it belongs to.
    ///
    /// "Day" runs from `AppConfig.dayBoundaryHour`, so activity at 01:00 counts
    /// toward the evening before rather than starting a new day at its earliest
    /// possible hour.
    private func firstMovements(in stepsByHour: [Date: Double]) -> [Date: Int] {
        let calendar = Calendar.current
        var earliest: [Date: (hour: Int, date: Date)] = [:]

        for (date, steps) in stepsByHour where Int(steps) >= AppConfig.wakeStepThreshold {
            let hour = calendar.component(.hour, from: date)
            // Before the boundary the hour belongs to the previous day.
            let owningDay = hour < AppConfig.dayBoundaryHour
                ? calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: date))
                : calendar.startOfDay(for: date)
            guard let owningDay else { continue }

            // Sorting by the clock would put 01:00 first; the day starts at the
            // boundary, so compare on hours since it.
            let sinceBoundary = (hour - AppConfig.dayBoundaryHour + 24) % 24
            if let current = earliest[owningDay] {
                let currentSince = (current.hour - AppConfig.dayBoundaryHour + 24) % 24
                if sinceBoundary < currentSince { earliest[owningDay] = (hour, date) }
            } else {
                earliest[owningDay] = (hour, date)
            }
        }

        return earliest.mapValues(\.hour)
    }

    /// Step totals per hour of the window. Same query as `dailyTotals`, a finer
    /// interval — and the same authorization, so this costs no new permission.
    private func hourlySteps(since: Date) async throws -> [Date: Double] {
        try await totals(.stepCount, unit: .count(), since: since, interval: DateComponents(hour: 1))
    }

    /// Daily sums for one quantity type, keyed by the start of each day.
    private func dailyTotals(
        _ identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        since: Date
    ) async throws -> [Date: Double] {
        try await totals(_: identifier, unit: unit, since: since, interval: DateComponents(day: 1))
    }

    /// Sums for one quantity type, bucketed by `interval`.
    private func totals(
        _ identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        since: Date,
        interval: DateComponents
    ) async throws -> [Date: Double] {
        guard let type = HKObjectType.quantityType(forIdentifier: identifier) else { return [:] }

        let anchor = Calendar.current.startOfDay(for: since)
        let predicate = HKQuery.predicateForSamples(withStart: since, end: Date(), options: .strictStartDate)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsCollectionQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum,
                anchorDate: anchor,
                intervalComponents: interval
            )
            query.initialResultsHandler = { _, results, error in
                if let error { return continuation.resume(throwing: error) }
                var totals: [Date: Double] = [:]
                results?.enumerateStatistics(from: anchor, to: Date()) { statistics, _ in
                    if let sum = statistics.sumQuantity()?.doubleValue(for: unit), sum > 0 {
                        totals[statistics.startDate] = sum
                    }
                }
                continuation.resume(returning: totals)
            }
            store.execute(query)
        }
    }

    // MARK: - Naming

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let timestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// `HKWorkoutActivityType` is an integer enum with no display name, and the
    /// distillation is meant to be readable in a CSV, so the common ones are
    /// spelled out. Anything unmapped keeps its raw value rather than being
    /// flattened into "Other" — an unnamed sport is still a distinct sport.
    static func name(for type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: return "Running"
        case .walking: return "Walking"
        case .hiking: return "Hiking"
        case .cycling: return "Cycling"
        case .swimming: return "Swimming"
        case .rowing: return "Rowing"
        case .elliptical: return "Elliptical"
        case .stairClimbing, .stairs: return "Stairs"
        case .traditionalStrengthTraining: return "Strength training"
        case .functionalStrengthTraining: return "Functional strength"
        case .coreTraining: return "Core training"
        case .highIntensityIntervalTraining: return "HIIT"
        case .yoga: return "Yoga"
        case .pilates: return "Pilates"
        case .barre: return "Barre"
        case .dance, .cardioDance, .socialDance: return "Dance"
        case .flexibility, .cooldown: return "Stretching"
        case .mindAndBody: return "Mind and body"
        case .tennis: return "Tennis"
        case .badminton: return "Badminton"
        case .tableTennis: return "Table tennis"
        case .basketball: return "Basketball"
        case .soccer: return "Football"
        case .americanFootball: return "American football"
        case .baseball: return "Baseball"
        case .volleyball: return "Volleyball"
        case .golf: return "Golf"
        case .climbing: return "Climbing"
        case .martialArts, .kickboxing, .boxing: return "Martial arts"
        case .surfingSports: return "Surfing"
        case .paddleSports: return "Paddling"
        case .snowboarding: return "Snowboarding"
        case .downhillSkiing, .crossCountrySkiing: return "Skiing"
        case .skatingSports: return "Skating"
        case .equestrianSports: return "Horse riding"
        case .fishing: return "Fishing"
        case .hunting: return "Hunting"
        case .bowling: return "Bowling"
        case .fitnessGaming: return "Fitness gaming"
        case .other: return "Other workout"
        default: return "Workout type \(type.rawValue)"
        }
    }
}
