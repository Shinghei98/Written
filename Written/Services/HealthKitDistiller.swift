import Foundation
import HealthKit
// For `applicationState` alone — see `waitUntilActive`. The rest of this file
// knows nothing about UIKit and should stay that way.
import UIKit

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
        /// Nothing came back, and whether the user had been asked before.
        ///
        /// HealthKit never says which reads were refused — a declined permission
        /// and an empty Health app are the same answer — so this used to carry
        /// one sentence covering both, which is unhelpful in both. What *can* be
        /// known is whether a sheet was ever put in front of them, and
        /// `getRequestStatusForAuthorization` answers exactly that. With it the
        /// two cases split: already asked means the switches are the thing to
        /// go and check, never asked means there is simply nothing recorded.
        case noData(alreadyAnswered: Bool)
        /// A query that failed or never returned, carrying which one it was, how
        /// long it ran and the underlying domain/code.
        ///
        /// The detail is kept but only *shown* in debug builds. It exists
        /// because "slow, and error 5" from a device said nothing about which of
        /// six queries was at fault — but `[com.apple.healthkit 5]` is not a
        /// sentence to put in front of a tester either.
        case stageFailed(String)
        /// **Our** twenty-second ceiling, as distinct from a call that failed on
        /// its own. The two were one case, and it cost the retry below its whole
        /// purpose: `stage` wraps every underlying error as `stageFailed`, so a
        /// guard meaning "don't retry our own timeout" refused to retry
        /// `[com.apple.healthkit 100]` — the one error it was written for.
        case stageTimedOut(String)

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "Apple Health isn't available on this device."
            // **Two different failures, and they used to read identically.**
            // The `[detail]` that separates them is DEBUG-only, so a screenshot
            // from TestFlight could not say whether HealthKit had returned an
            // error or whether we had given up waiting — and one of those was a
            // bug in this file. A tester on build 14 sent exactly that
            // screenshot and it took reading the source to work out which.
            //
            // So the sentences differ. Neither names a domain or a code, which
            // is not something to put in front of a tester; they differ enough
            // to tell the two apart on sight, which is all the next report
            // needs to do.
            case .stageFailed(let detail):
                let message = "Apple Health didn't respond. Try again — and if it keeps happening, "
                    + "open Health and check Data Access & Devices › Written."
                return BuildKind.showsDiagnostics ? "\(message)\n\(detail)" : message
            case .stageTimedOut(let detail):
                let message = "Apple Health took too long to answer. Try again."
                return BuildKind.showsDiagnostics ? "\(message)\n\(detail)" : message
            // **Short, and it names the right place.** Both of these used to be
            // one sentence spelling out "Health › Profile › Apps › Written" —
            // three levels, the wrong ones, and the length is what overflowed
            // the prompt card and pushed its own button out of sight. The
            // switches are under Data Access & Devices.
            case .noData(alreadyAnswered: true):
                // Still does not claim a refusal, because HealthKit will not say
                // — but it can say the question was already put, which makes the
                // switches worth going to look at.
                return "Written has already asked for Apple Health. Turn its categories on under Data Access & Devices in the Health app, then try again."
            case .noData(alreadyAnswered: false):
                // Permission was granted this minute, so the switches are not
                // the problem and sending anyone to check them would be a wild
                // goose chase.
                return "Nothing came back from Apple Health — there may be no workouts or activity recorded yet."
            }
        }
    }

    /// Everything we ask to read. Workouts carry the sport and its duration;
    /// exercise minutes and active energy carry the intensity.
    private static var readTypes: Set<HKObjectType> {
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

    /// `requestedAt` is when the user's tap happened, not when this ran. The gap
    /// between the two is the whole of the current suspicion — the picker starts
    /// the distillation before it dismisses itself — and it is not otherwise
    /// visible from in here.
    func distill(requestedAt: Date = Date()) async throws -> [DistilledRecord] {
        let trail = Trail()
        trail.add("health")
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
        let types = Self.readTypes

        // **Whether a sheet is needed at all, before trying to raise one.**
        // Read authorization is otherwise invisible: `authorizationStatus(for:)`
        // reports sharing and says nothing about reading, which is why a refusal
        // and an empty database have always been the same answer here. This is
        // the one thing HealthKit will tell us — not what was allowed, but
        // whether the question has ever been put — and it is enough to stop the
        // failure message guessing.
        // **A probe, and never a gate — which it was for one build.** Wrapped in
        // a plain `try await`, its own failure aborted the distillation before
        // the sheet was ever asked for: on a freshly erased simulator it answers
        // `[com.apple.healthkit 4]` in a tenth of a second, and Apple Health then
        // "didn't respond" without anything having been asked. A question about
        // whether to ask must not be able to prevent asking.
        //
        // So: unanswerable means ask. The cost of guessing wrong is one extra
        // call that HealthKit returns from immediately; the cost of the other
        // default is a permission that can never be granted.
        let alreadyAnswered = (try? await Self.stage("request-status") {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                store.getRequestStatusForAuthorization(toShare: [], read: types) { status, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: status == .unnecessary) }
                }
            }
        }) ?? false

        // Nothing to present, so nothing to present *badly* — skipping the
        // request is not an optimisation, it removes the only step here that
        // depends on another process launching.
        trail.add(alreadyAnswered ? "already-answered" : "sheet-expected")
        trail.add("+\(Self.seconds(since: requestedAt)) since tap")

        if !alreadyAnswered {
            try await Self.requestAuthorization(store: store, types: types, trail: trail)
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

        // **Thrown here rather than checked by the caller**, because the reason
        // an empty result is worth naming depends on whether the user was ever
        // asked — and this is the only place that knows. `DistillViewModel` used
        // to make this call and had to construct the error blind.
        guard !records.isEmpty else { throw HealthError.noData(alreadyAnswered: alreadyAnswered) }
        return records
    }

    /// One run's steps, in order, for the failure message to carry.
    ///
    /// A class rather than a value because it is written from inside the retry
    /// loop and read after it throws; a lock because those writes can come from
    /// the detached task `stage` runs its work on.
    ///
    /// Deliberately tiny and deliberately not a logging framework: it exists to
    /// fit on one line of an error message that somebody photographs.
    final class Trail: @unchecked Sendable {
        private let lock = NSLock()
        private var steps: [String] = []

        func add(_ step: String) {
            lock.lock(); defer { lock.unlock() }
            steps.append(step)
        }

        /// Middle dots rather than newlines: this is read in a screenshot of a
        /// card, and a stack of short lines is what gets cropped.
        var line: String {
            lock.lock(); defer { lock.unlock() }
            return steps.joined(separator: " · ")
        }
    }

    /// The domain and code of whatever came back, for the trail.
    ///
    /// Our own wrapped errors already carry theirs in the message, so those are
    /// passed through rather than re-labelled as `Written.HealthError 3`, which
    /// is true and says nothing.
    private static func code(of error: Error) -> String {
        if case HealthError.stageFailed(let detail) = error { return detail }
        let nsError = error as NSError
        return "[\(nsError.domain) \(nsError.code)]"
    }

    /// How long any one HealthKit *query* may take before it is treated as hung.
    ///
    /// HealthKit has no timeout of its own: a query whose completion handler is
    /// never called leaves the `withCheckedThrowingContinuation` suspended
    /// forever, and the screen spins with nothing to report. Twenty seconds is
    /// far past any legitimate query on these windows.
    private static let stageTimeout: TimeInterval = 20

    /// **The authorization request is not a query and must not share that
    /// ceiling.** Its completion handler does not fire until the user answers
    /// the sheet, so twenty seconds was a limit on how long somebody was
    /// allowed to think — and the app itself asks them to think: every category
    /// on that sheet opens *off*, Allow stays disabled until one is switched
    /// on, and `SourcePickerSheet` tells them so in as many words. A first-time
    /// user reading the list and choosing will routinely take longer than that.
    ///
    /// It then compounded, because `stageTimedOut` is the one error the retry
    /// below deliberately refuses: a slow read was terminal, the grant being
    /// given at that moment was discarded, and the report was "Apple Health
    /// didn't respond" from somebody looking straight at the sheet. Reported on
    /// build 14, which already carried both first-run fixes.
    ///
    /// Three minutes, and it still catches what the ceiling exists for. The
    /// SpringBoard failure this is often blamed for arrives as an *error*
    /// within about ten seconds and never reaches here; only a callback that
    /// never comes at all does, and that is caught just as well late as early.
    private static let authorizeTimeout: TimeInterval = 180

    /// Runs one stage, and on failure rethrows an error naming the stage, the
    /// underlying domain/code and how long it ran. A stage that never returns
    /// is reported as a timeout rather than hanging the whole distillation.
    private static func stage<T: Sendable>(
        _ name: String,
        timeout: TimeInterval = stageTimeout,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let started = Date()
        do {
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                let baton = StageBaton()

                // **Unstructured, and abandoned rather than awaited — which is
                // the entire point.** This was a `withThrowingTaskGroup` racing
                // the work against a sleeper, and it could not do the one job it
                // was written for. A task group *waits for every child before it
                // returns*: the sleeper would throw at twenty seconds, the body
                // would exit, and the group would then sit waiting on the work
                // task forever. `cancelAll()` does not help, because a task
                // suspended inside `withCheckedThrowingContinuation` never
                // observes cancellation — the only thing that can resume it is
                // the callback that never came.
                //
                // So the timeout worked for a call that was merely slow and was
                // useless for a call that never returns, which is the only case
                // it exists for. Structured concurrency is exactly wrong here:
                // surviving a continuation nobody will resume means declining to
                // wait for it, and that requires a task nothing is awaiting.
                let worker = Task.detached(priority: .userInitiated) {
                    do {
                        let value = try await work()
                        if baton.claim() { continuation.resume(returning: value) }
                    } catch {
                        if baton.claim() { continuation.resume(throwing: error) }
                    }
                }

                Task.detached {
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    guard baton.claim() else { return }
                    // Best effort, and expected to do nothing in the case that
                    // matters. It is here for the stages that *are* cancellable.
                    worker.cancel()
                    continuation.resume(
                        throwing: HealthError.stageTimedOut("\(name) timed out after \(Int(timeout))s")
                    )
                }
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

    /// Puts the sheet up, and puts it up a second time if the *system* lost a
    /// cold-start race the first time.
    ///
    /// HealthKit does not draw its own sheet: it asks SpringBoard to launch
    /// `com.apple.HealthPrivacyService` and hosts a remote view from it. On a
    /// device where that process has never run, the launch can take longer than
    /// HealthKit's own patience. Caught in the simulator log, on a device
    /// erased seconds earlier:
    ///
    ///     10:00:29.740  Asking defaultShell to open app viewservice com.apple.HealthPrivacyService
    ///     10:00:32.555  FAILED prompting authorization request …, error Authorization session timed out
    ///     10:00:36.338  Request successful: <BSProcessHandle: HealthPrivacySe:10724>
    ///
    /// — the service finishing its launch **four seconds after** HealthKit gave
    /// up waiting for it. Nothing was refused and nothing is misconfigured; the
    /// sheet simply never got drawn, and the user sees no question and no answer.
    ///
    /// One retry, because by then the process is warm. A loop would be
    /// superstition: a second failure is a real one.
    /// **Every step is written down, and the reason is a screenshot that could
    /// not answer its own question.** A tester on build 14 sent "Apple Health
    /// didn't respond" with no sheet ever drawn, and that one sentence is
    /// produced by two entirely different failures: HealthKit erroring twice,
    /// and our own ceiling firing once with the retry deliberately skipped.
    /// Separating them cost two readings of this file and produced two
    /// different answers.
    ///
    /// So the thrown error now carries the run rather than its last line:
    ///
    ///     health · sheet-expected · +0.04s since tap · auth#1 err 10.2s [com.apple.healthkit 100] · auth#2 err 9.8s [com.apple.healthkit 100]
    ///     health · sheet-expected · +0.04s since tap · auth#1 timeout 20s
    ///
    /// The first says HealthKit refused to present, twice. The second says the
    /// callback never came and there was no second attempt. `BuildKind` is what
    /// lets a TestFlight build print it.
    ///
    /// `sinceTap` is the specific suspicion, made measurable: the picker starts
    /// the distillation *before* it dismisses itself, so HealthKit may be being
    /// asked to present over a sheet that is still being torn down. A trail
    /// showing the request going out tens of milliseconds after the tap is that
    /// claim confirmed by a tester rather than asserted here.
    private static func requestAuthorization(
        store: HKHealthStore,
        types: Set<HKObjectType>,
        trail: Trail
    ) async throws {
        for attempt in 1...2 {
            let label = attempt == 1 ? "auth#1" : "auth#2"
            let started = Date()
            do {
                // **Frontmost first.** The session does not survive the app
                // resigning active, so asking while something else owns the
                // screen is asking for the failure above.
                await waitUntilActive()
                try await stage(
                    attempt == 1 ? "authorize" : "authorize-retry",
                    timeout: authorizeTimeout
                ) {
                    // The completion-handler API, bridged by hand, rather than
                    // the async overload. `DistillViewModel` is `@MainActor`, so
                    // the async version is awaited *from* the main actor — and
                    // HealthKit delivers this particular callback on the main
                    // queue, which is the shape of a deadlock: the main thread
                    // suspended waiting for a result that needs the main thread
                    // to arrive. Bridging explicitly means the continuation
                    // resumes from HealthKit's own queue instead.
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        store.requestAuthorization(toShare: [], read: types) { _, error in
                            if let error { continuation.resume(throwing: error) }
                            else { continuation.resume() }
                        }
                    }
                }
                trail.add("\(label) ok \(seconds(since: started))")
                return
            } catch {
                // Retried on *any* error rather than on that one message,
                // because a refusal does not arrive as one — HealthKit reports a
                // denied read as success and no data. An error here is always
                // infrastructural, so a second go is always worth having.
                //
                // Except our own ceiling — `stageTimedOut`, not `stageFailed`.
                // If twenty seconds bought nothing, a further twenty is forty
                // seconds of spinner for the same answer. Written as
                // `stageFailed` first time round, which `stage` puts on *every*
                // wrapped error, so this refused the very case it exists for:
                // `[com.apple.healthkit 100]` after 10.8s, measured, with no
                // retry attempted.
                if case HealthError.stageTimedOut = error {
                    trail.add("\(label) timeout \(seconds(since: started))")
                    throw HealthError.stageTimedOut(trail.line)
                }
                trail.add("\(label) err \(seconds(since: started)) \(Self.code(of: error))")
                guard attempt == 1 else { throw HealthError.stageFailed(trail.line) }
            }
        }
    }

    /// Holds until the app is frontmost, or gives up after `seconds`.
    ///
    /// **"Authorization session timed out" is not about elapsed time.** Two runs
    /// on identically erased simulators: the one that worked waited *six
    /// seconds* for `HealthPrivacyService` and drew its sheet; the one that
    /// failed died two seconds after `App will resign active`. HealthKit
    /// abandons the session when the app it would present over stops being
    /// active — so the question is never how long it took, only whether anything
    /// else took the screen.
    ///
    /// Nothing in this app can any more: every remaining permission request is
    /// user-initiated and the picker connects one source at a time. This makes
    /// that precondition explicit rather than assumed, and covers what we do not
    /// control — a call, a system alert — by waiting for it to pass instead of
    /// asking into it.
    ///
    /// Bounded, because a user who backgrounded the app is not coming back to a
    /// sheet: five seconds and then the attempt proceeds anyway, so this can
    /// only ever improve the odds and never becomes another way to hang.
    @MainActor
    private static func waitUntilActive(upTo seconds: TimeInterval = 5) async {
        var waited: TimeInterval = 0
        while UIApplication.shared.applicationState != .active, waited < seconds {
            try? await Task.sleep(nanoseconds: 200_000_000)
            waited += 0.2
        }
    }

    /// Lets exactly one of two racers resume a continuation.
    ///
    /// A lock rather than an actor because the claim is made from inside
    /// `withCheckedThrowingContinuation`'s body, which is not async and so has
    /// nothing to await an actor on.
    private final class StageBaton: @unchecked Sendable {
        private let lock = NSLock()
        private var taken = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if taken { return false }
            taken = true
            return true
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

        // **The floor is checked here as well as in `setBirthday`, because this
        // is a second door into the same field.** Health carries a date of
        // birth, and without this an age below the minimum would arrive on the
        // profile without anybody typing it — the gate on the sheet would read
        // as correct and exclude nothing, which is the failure this codebase
        // has already recorded once for the calendar filter.
        //
        // Dropped rather than treated as a reason to refuse the account: a
        // device's Health profile is not proof of who is holding it, and the
        // authoritative answer is the one the person gives. With no record the
        // profile simply has no age until they enter one, and that is where the
        // rule bites.
        if let components = try? store.dateOfBirthComponents(),
           let birthday = Calendar.current.date(from: components),
           let age = Calendar.current.dateComponents([.year], from: birthday, to: now).year,
           (DistillViewModel.minimumAge...130).contains(age) {
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
