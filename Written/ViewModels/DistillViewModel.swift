import CoreLocation
import Foundation
import SwiftUI

@MainActor
final class DistillViewModel: ObservableObject {

    @Published var youtubeStatus: SourceStatus = .idle
    @Published var appleMusicStatus: SourceStatus = .idle
    @Published var healthStatus: SourceStatus = .idle
    @Published private(set) var records: [DistilledRecord] = []

    @Published var isExporterPresented = false
    @Published var exportDocument: CSVDocument?
    @Published var exportResultMessage: String?

    /// What the tree is grown from. Recomputed whenever records change, never
    /// per frame.
    @Published private(set) var treeState: TreeState = .empty
    @Published private(set) var skeleton = TreeSkeleton.make(from: .empty, seed: DistillViewModel.treeSeed)

    /// What the dashboard shows, on the same terms as `treeState`: derived once
    /// per distillation rather than per frame. A SwiftUI body runs on any state
    /// change — an image finishing, a scroll, an animation tick — and ranking a
    /// thousand records inside one is how a screen goes sticky.
    @Published private(set) var musicArtists: [MusicHighlights.Artist] = []
    /// Empty whenever nothing carries a genre. The dashboard hides its block
    /// rather than drawing an empty one.
    @Published private(set) var musicGenres: [MusicHighlights.Genre] = []
    @Published private(set) var mediaChannels: [MediaHighlights.Channel] = []
    @Published private(set) var chronotype: LifestyleHighlights.Chronotype?
    @Published private(set) var hourlyActivity: [Double] = []
    @Published private(set) var sports: [LifestyleHighlights.Sport] = []
    @Published private(set) var averageDailySteps: Int?

    /// Who the profile belongs to: age and sex from Health, district and city
    /// from one location fix.
    @Published private(set) var identity = IdentitySummary()

    /// The example match on the profile screen. Derived from `identity` and the
    /// records together, so it is recomputed alongside everything else rather
    /// than being built in the view — a `body` that ranks songs would rebuild
    /// the ranking on every scroll tick.
    @Published private(set) var exampleProfile = ExampleProfile(
        handle: ExampleProfile.photoAsset, age: nil, place: nil,
        musicLine: nil, interestLine: nil, song: nil
    )

    /// The chorus `LyricsService` found for the current top song, once it has.
    /// Held here rather than inside `ExampleProfile` so that stays a pure value
    /// built from records alone.
    private var fetchedHook: String?
    /// What `fetchedHook` belongs to, so a re-distill that changes the top song
    /// doesn't caption the new song with the old song's chorus.
    private var fetchedHookSong: MusicHighlights.Song?

    private let location = LocationDistiller()
    private var isLocating = false
    @Published private(set) var lastCollectedAt: Date?
    /// Sources that actually returned records, for `connectedSources(for:)`.
    private var returnedSources: Set<String> = []

    /// What the user has struck off. Published so the dashboard can redraw the
    /// moment something is removed.
    @Published private(set) var bans = BanList.load()

    private let googleOAuth = OAuthPKCEService(provider: .google)

    init() {
        // The last snapshot, before anything draws. A connection is a durable
        // fact — "has been connected", not "is listening" — so the tree and the
        // connected bars have to be right on the first frame rather than
        // appearing a beat later or, as they used to, not at all.
        records = RecordStore.load()
        if !records.isEmpty { recomputeDerived() }

        // Then reconcile with the server, which is the actual record. The cache
        // above is what makes the first frame right; this is what makes a
        // reinstall or a new phone show the same garden as the old one, which
        // nothing did before — sync only ever pushed.
        restoreFromServer()

#if DEBUG
        // `-stage 3` on the launch line seeds the plant, so a stage can be
        // looked at without patching the source and rebuilding. See `DebugLaunch`.
        // After the load above, so a forced stage still wins.
        if let stage = DebugLaunch.forcedStage { applyPreview(connected: stage) }
#endif
    }

    var hasRecords: Bool { !records.isEmpty }

    var isDistilling: Bool {
        youtubeStatus.isRunning || appleMusicStatus.isRunning
            || healthStatus.isRunning
    }

    func status(for source: String) -> SourceStatus {
        switch source {
        case "youtube": return youtubeStatus
        case "apple_music": return appleMusicStatus
        case "health": return healthStatus
        default: return .idle
        }
    }

    /// Entry point for the tree UI, which thinks in sources rather than methods.
    func distill(source: String) {
        switch source {
        case "youtube": distillYouTube()
        case "apple_music": distillAppleMusic()
        case "health": distillHealth()
        default: break
        }
    }

    private static var treeSeedKey: String { AccountScope.key("written.tree.seed") }

    /// Fixed per account, so a given person's tree keeps the same character
    /// across launches instead of reshuffling every time it is drawn.
    ///
    /// A `var`, not the `let` it was: a `static let` is resolved once per
    /// process, so after signing out and into a different account the second
    /// person's tree was drawn from the first person's seed until the app was
    /// killed. Reading it each time costs a `UserDefaults` lookup.
    static var treeSeed: UInt64 {
        if let stored = UserDefaults.standard.object(forKey: treeSeedKey) as? NSNumber {
            return stored.uint64Value
        }
        let seed = UInt64.random(in: 1...UInt64.max)
        UserDefaults.standard.set(NSNumber(value: seed), forKey: treeSeedKey)
        return seed
    }

    /// Leaves nothing on this device.
    ///
    /// Signing out is still not disconnecting — a connection is a snapshot that
    /// was taken once, and that stays true. What changed is *where* the fact
    /// lives: Postgres holds the records, the connections, the ban list and the
    /// user object, so signing back in restores the garden exactly as it was
    /// without the phone having kept a thing in the meantime.
    ///
    /// The device copy is a cache in front of that, and a cache that outlived
    /// the session would be retention with extra steps.
    func signOutLocalState() {
        googleOAuth.disconnect()
        BanList.clear()
        RecordStore.clear()
        UserDefaults.standard.removeObject(forKey: Self.treeSeedKey)
        clearInMemoryState()
    }

    /// What `signOutLocalState` used to be, kept apart because a restore needs
    /// exactly this and none of the erasing above.
    private func clearInMemoryState() {
        bans = BanList()
        records = []
        returnedSources = []
        knownConnections = []
        chronotype = nil
        hourlyActivity = []
        sports = []
        averageDailySteps = nil
        recomputeDerived()
    }

    /// Everything this device holds for the account being deleted.
    ///
    /// Identical to signing out now that signing out erases the device too —
    /// what differs is on the server, which `SupabaseAuth.deleteAccount` handles.
    /// Kept as its own name because the call sites mean different things and one
    /// of them is irreversible.
    ///
    /// Called *before* the session goes away, because `AccountScope` reads the
    /// stored user id to know which files and Keychain items to remove — after
    /// sign-out it would resolve to `local` and clear the wrong ones.
    func deleteAccountLocalState() {
        signOutLocalState()
    }

    // MARK: - Restoring from the server

    /// Applies what `RestoreService` fetched.
    ///
    /// The server is the source of truth, so this replaces rather than merges —
    /// with one exception. The lifestyle figures are only overwritten when the
    /// server actually has them: a distillation that just happened is newer than
    /// anything a restore can know, and blanking a freshly connected Health
    /// account because the upload hasn't landed yet would be the restore
    /// undoing the work.
    func apply(_ snapshot: RestoreService.Snapshot) {
        records = snapshot.records.map(applyingBans)
        bans = snapshot.bans
        bans.save()
        knownConnections.formUnion(snapshot.connectedSources)

        if let seed = snapshot.treeSeed {
            UserDefaults.standard.set(NSNumber(value: seed), forKey: Self.treeSeedKey)
        } else {
            // First restore for an account that predates the column — send this
            // device's seed up so the next device draws the same plant.
            let seed = Self.treeSeed
            Task.detached(priority: .utility) {
                await SyncService.shared.pushUserObject(treeSeed: seed)
            }
        }

        recomputeDerived()

        if let lifestyle = snapshot.lifestyle {
            chronotype = lifestyle.chronotype
            hourlyActivity = lifestyle.hourlyActivity
            sports = lifestyle.sports.filter { !bans.contains(.sport, $0.name) }
            averageDailySteps = lifestyle.averageDailySteps
        }

        // Age and sex live on the user object; district still arrives as a
        // record, so only fill what `recomputeDerived` couldn't.
        if identity.age == nil { identity.age = snapshot.identity.age }
        if identity.sex == nil { identity.sex = snapshot.identity.sex }
        if identity.place == nil { identity.place = snapshot.identity.place }

        RecordStore.save(records)
    }

    /// Pulls the account down, replacing whatever the cache had.
    func restoreFromServer() {
        Task {
            guard let snapshot = await RestoreService.shared.hydrate() else { return }
            apply(snapshot)
        }
    }

    /// The apps of a modality that have been connected — what its
    /// "Connected to …" bar shows marks for.
    ///
    /// Not read off the statuses, because "connected" means *has been connected*
    /// — a durable fact about a snapshot that was taken, not a claim that
    /// anything is listening now. A status is only about the current session and
    /// would forget by morning.
    ///
    /// Two sources of truth, unioned, and the second is why this changed:
    /// `returnedSources` is what came back from records, which stopped being able
    /// to speak for Health the moment its raw rows were discarded — a connected
    /// Health account has no records at all, so the lifestyle branch would have
    /// read as never grown. `connectedSources` comes from `source_connections`
    /// on the server, which records the *fact* of a connection independently of
    /// whether any rows survived it.
    func connectedSources(for modality: Modality) -> [String] {
        modality.sources.filter { returnedSources.contains($0) || knownConnections.contains($0) }
    }

    /// Sources known to have been connected regardless of what they left behind.
    ///
    /// Seeded by the restore from `source_connections`, and added to the moment a
    /// distillation succeeds. The second half matters for the case that has no
    /// records at all: someone who grants workouts and activity but declines
    /// date of birth and biological sex leaves Health with nothing, and the
    /// branch would sit ungrown until a restore said otherwise.
    @Published private(set) var knownConnections: Set<String> = []

    /// Why this modality's last connection attempt came to nothing, if it did.
    ///
    /// Statuses were being set and never read: a failed distillation played the
    /// watering can, left the tree the same size and said nothing, which reads
    /// as a button that doesn't work. Apple Health hits this the most — an empty
    /// Health app and a declined read both come back as no records — so the
    /// modality most likely to fail was the one failing most silently.
    ///
    /// Only the *current* attempt's failure counts: a source that has since been
    /// distilled successfully is no longer failing, whatever it did before.
    func failureMessage(for modality: Modality) -> String? {
        for source in modality.sources {
            if case .failed(let message) = status(for: source) { return message }
        }
        return nil
    }

    var recordCountBySource: [(source: String, count: Int)] {
        Dictionary(grouping: records, by: \.source)
            .map { (source: $0.key, count: $0.value.count) }
            .sorted { $0.source < $1.source }
    }

    // MARK: - Distillation

    func distillYouTube() {
        guard !youtubeStatus.isRunning else { return }
        youtubeStatus = .running
        Task {
            do {
                let distiller = YouTubeDistiller(oauth: googleOAuth)
                let newRecords = try await distiller.distill()
                replaceRecords(from: "youtube", with: newRecords)
                youtubeStatus = .done(count: newRecords.count)
            } catch {
                youtubeStatus = .failed(message: error.localizedDescription)
            }
        }
    }

    func distillAppleMusic() {
        guard !appleMusicStatus.isRunning else { return }
        appleMusicStatus = .running
        Task {
            do {
                let distiller = AppleMusicDistiller()
                let newRecords = try await distiller.distill()
                replaceRecords(from: "apple_music", with: newRecords)
                appleMusicStatus = .done(count: newRecords.count)
            } catch {
                appleMusicStatus = .failed(message: Self.detail(of: error))
            }
        }
    }

    /// An error's sentence, with its identity attached in debug builds only.
    ///
    /// MusicKit's `localizedDescription` for a token failure is "Failed to
    /// request developer token" and nothing else — the same string whether the
    /// App ID lacks the MusicKit service, the request never left the device, or
    /// Apple refused it. The domain and code are what tell those apart, and they
    /// are worth having while developing; they are not worth showing a tester,
    /// who can do nothing with `[ICError 4]` except mistrust the app.
    private static func detail(of error: Error) -> String {
#if DEBUG
        let nsError = error as NSError
        var line = error.localizedDescription
        line += "\n[\(nsError.domain) \(nsError.code)]"
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            line += " ← [\(underlying.domain) \(underlying.code)]"
        }
        if let reason = nsError.localizedFailureReason { line += "\n\(reason)" }
        return line
#else
        return error.localizedDescription
#endif
    }

    func distillHealth() {
        guard !healthStatus.isRunning else { return }
        healthStatus = .running
        Task {
            do {
                // Off the main actor deliberately. This class is `@MainActor`,
                // so an unqualified `Task` inherits it and every HealthKit await
                // suspends the main thread — which is how a stuck permission
                // request wedged the whole app, timeout included: the timeout
                // fired on a background task but could never resume `distill()`,
                // because resuming it needed the main thread the request was
                // holding.
                let newRecords = try await Task.detached(priority: .userInitiated) {
                    try await HealthKitDistiller().distill()
                }.value

                // HealthKit reports a declined read as no data rather than as an
                // error, so a zero-record distill is the one case worth naming:
                // otherwise the branch grows on an empty permission and the user
                // is told nothing.
                guard !newRecords.isEmpty else {
                    healthStatus = .failed(message: HealthKitDistiller.HealthError.noData.localizedDescription)
                    return
                }

                // Everything the lifestyle card shows is worked out here, while
                // the raw rows still exist — because after the next line they
                // don't.
                let applied = newRecords.map(applyingBans)
                applyLifestyle(from: applied)

                // **The raw rows are discarded.** Workouts, activity days and
                // hourly steps are read, reduced to the figures above, and
                // dropped — they are never handed to `replaceRecords`, so they
                // never reach `records`, and never reach the file on disk. Only
                // the extracted demographics stay, and only because age and sex
                // are answers rather than samples.
                //
                // Passing the kept rows through `replaceRecords` rather than
                // assigning them also clears the raw rows an older build of this
                // app already wrote to disk.
                let extracted = applied.filter { Self.healthKeptTypes.contains($0.dataType) }
                knownConnections.insert("health")
                replaceRecords(from: "health", with: extracted)
                pushDemographics(from: extracted)

                healthStatus = .done(count: newRecords.count)
            } catch {
                healthStatus = .failed(message: error.localizedDescription)
            }
        }
    }

    /// The only HealthKit rows that outlive the distillation that produced them.
    ///
    /// Both are answers, not samples: an age and a biological sex, each a single
    /// value HealthKit hands over on request. What is dropped is the reading —
    /// every workout, every day, every hour — which is the part guideline 5.1.3
    /// is about and the part there is genuinely a lot of.
    private static let healthKeptTypes: Set<String> = ["age", "biological_sex"]

    /// Works the lifestyle card out of the raw rows, once.
    ///
    /// Called before those rows are discarded and never again, which is the
    /// whole point: these four values cannot be recomputed afterwards, so they
    /// are state rather than a derivation, and the restore sets them the same way.
    private func applyLifestyle(from raw: [DistilledRecord]) {
        chronotype = LifestyleHighlights.chronotype(in: raw)
        hourlyActivity = LifestyleHighlights.hourlyActivity(in: raw)
        sports = LifestyleHighlights.topSports(in: raw)
        averageDailySteps = LifestyleHighlights.averageDailySteps(in: raw)
    }

    /// Age and sex up to the user object, where they are the only copy.
    ///
    /// Health rows are never uploaded, so without this a restored account would
    /// know a person's music and not their age. `birth_year` rather than a date:
    /// `HealthKitDistiller` deliberately keeps only the year, and uploading more
    /// precision than the app itself holds would be inventing it.
    private func pushDemographics(from records: [DistilledRecord]) {
        let birthYear = records
            .first { $0.dataType == "age" }?
            .extraValue("birth_year")
            .flatMap(Int.init)
        let sex = records.first { $0.dataType == "biological_sex" }?.name

        guard birthYear != nil || sex != nil else { return }
        Task.detached(priority: .utility) {
            await SyncService.shared.pushUserObject(birthYear: birthYear, sex: sex)
        }
    }

    private func replaceRecords(from source: String, with newRecords: [DistilledRecord]) {
        records.removeAll { $0.source == source }
        // Freshly fetched rows know nothing of what the user struck off last
        // time, so the bans are re-applied here. Without this a re-distill
        // quietly resurrects everything they removed.
        let applied = newRecords.map(applyingBans)
        records += applied
        recomputeDerived()
        // The single point every source's records pass through, so one call here
        // keeps the device copy and the server copy honest about all of them.
        RecordStore.save(records)
        sync(source: source, records: applied)
    }

    /// Pushes the derived health figures on their own.
    ///
    /// They used to travel only as part of a distillation, which was fine while
    /// they were recomputed from records — anything that changed them changed
    /// the records too. Striking off a sport now changes the figures without
    /// touching a single record, so it needs its own way up.
    private func syncLifestyle() {
        let chronotype = self.chronotype
        let sports = self.sports
        let hourly = self.hourlyActivity
        let steps = self.averageDailySteps

        Task.detached(priority: .utility) {
            await SyncService.shared.pushHealthSignals(
                chronotype: chronotype,
                sports: sports,
                hourlyActivity: hourly,
                averageDailySteps: steps
            )
        }
    }

    /// Struck-off entries follow the records up, so the server knows what the
    /// user rejected rather than re-learning it from a fresh distill.
    private func syncBans() {
        let snapshot = bans
        Task.detached(priority: .utility) { await SyncService.shared.pushBans(snapshot) }
    }

    /// Pushes what just landed, without the screen waiting on it.
    ///
    /// Detached and unawaited on purpose: the records are already on the device
    /// and the garden should grow the moment they arrive. A failed upload is
    /// something to retry, not something to hold the plant still for — and this
    /// is the one place every source's records pass through, so one call here
    /// covers all of them.
    ///
    /// Health is the exception, and takes the other branch: its raw rows are
    /// gone by the time this runs — discarded in `distillHealth` — so only the
    /// figures derived from them travel, plus the row saying it was connected.
    private func sync(source: String, records: [DistilledRecord]) {
        let chronotype = self.chronotype
        let sports = self.sports
        let hourly = self.hourlyActivity
        let steps = self.averageDailySteps

        let currentBans = bans

        Task.detached(priority: .utility) {
            if source == "health" {
                await SyncService.shared.pushHealthSignals(
                    chronotype: chronotype,
                    sports: sports,
                    hourlyActivity: hourly,
                    averageDailySteps: steps
                )
                // Health writes no records, so nothing else records that it was
                // connected — `replace_source_records` is what does it for every
                // other source, and Health never reaches it.
                await SyncService.shared.pushConnection(source: "health", recordCount: 0)
            } else {
                await SyncService.shared.push(source: source, records: records)
            }
            // The ban list rides along, not only when it changes.
            //
            // Pushing solely on `bans.save()` meant anything struck off before
            // this device had an account — or before sync existed at all —
            // never reached the server. The removals themselves survive, baked
            // into each record's `extra`, but the *list* is what re-applies them
            // to a future distill, so without it a reinstall resurrects
            // everything the user rejected.
            await SyncService.shared.pushBans(currentBans)
        }
    }

    /// One location fix, the first time the dashboard needs it.
    ///
    /// Not part of a distillation run: nothing else asks for a permission when a
    /// screen appears, and this one does because the row it fills is meant to be
    /// there without being asked for. It runs once — a decline is remembered by
    /// the system, and re-asking on every appearance would be nagging.
    func captureLocationIfNeeded() {
        guard !isLocating, identity.place == nil, !location.isDenied else { return }
        isLocating = true
        Task {
            defer { isLocating = false }
            guard let record = try? await location.distill() else { return }
            replaceRecords(from: "location", with: [record])
        }
    }

    /// A birthday the user typed in, replacing whatever age Health reported.
    ///
    /// Stored as a record like everything else, so it exports with the rest and
    /// the ontology stage can see that this figure was entered rather than
    /// distilled. `nil` when the three fields don't make a real date — 31
    /// February is not a birthday, and `DateComponents` will happily build one
    /// unless it is asked to validate.
    @discardableResult
    func setBirthday(month: Int, day: Int, year: Int) -> Bool {
        var components = DateComponents()
        components.month = month
        components.day = day
        components.year = year

        let calendar = Calendar.current
        guard components.isValidDate(in: calendar),
              let birthday = calendar.date(from: components),
              let age = calendar.dateComponents([.year], from: birthday, to: Date()).year,
              (0...130).contains(age) else { return false }

        let record = DistilledRecord(
            source: "user", dataType: "age", itemID: "age",
            name: "\(age)", creator: "", detail: "",
            extra: "birth_year=\(year);entered_by_user=1", collectedAt: Date()
        )
        replaceRecords(from: "user", with: userRecords(replacing: "age", with: record))
        // Exact, because they typed it — this is the one path that knows the day
        // as well as the year, and `birth_date` wins over `birth_year` on read.
        Task.detached(priority: .utility) {
            await SyncService.shared.pushUserObject(birthDate: birthday, birthYear: year)
        }
        return true
    }

    /// A gender the user chose, which stands ahead of Health's biological sex.
    /// The two are not the same question, and only one of them was asked here.
    func setGender(_ label: String) {
        let record = DistilledRecord(
            source: "user", dataType: "gender", itemID: "gender",
            name: label, creator: "", detail: "", extra: "entered_by_user=1", collectedAt: Date()
        )
        replaceRecords(from: "user", with: userRecords(replacing: "gender", with: record))
        Task.detached(priority: .utility) {
            await SyncService.shared.pushUserObject(sex: label)
        }
    }

    /// Where the phone is, for centring the map. `nil` when location is off.
    func currentCoordinate() async -> CLLocationCoordinate2D? {
        try? await location.currentCoordinate()
    }

    /// Somewhere the user picked on the map, rather than where the phone is.
    func setPlace(at coordinate: CLLocationCoordinate2D) async {
        guard let record = try? await location.place(at: coordinate) else { return }
        replaceRecords(from: "location", with: [record])
        await SyncService.shared.pushUserObject(place: record.name)
    }

    /// `replaceRecords` clears a whole source, and the user source holds more
    /// than one kind of row — an age and a gender have to survive each other.
    private func userRecords(replacing dataType: String, with record: DistilledRecord) -> [DistilledRecord] {
        records.filter { $0.source == "user" && $0.dataType != dataType } + [record]
    }

    // MARK: - Editing

    /// Strike an artist off: they leave the dashboard, their songs stop counting
    /// toward anything, and the rows say so on the way out.
    ///
    /// The next artist down takes their place without any extra work — the
    /// rankings are computed from the records and only *then* cut to six, so
    /// removing one promotes whoever was seventh.
    func banArtist(_ name: String) {
        bans.add(.artist, name)
        bans.save()
        syncBans()
        records = records.map(applyingBans)
        recomputeDerived()
        // The removal is written into each record's `extra`, so the struck-off
        // state is part of the snapshot and has to be saved with it.
        RecordStore.save(records)
    }

    func banChannel(_ channel: MediaHighlights.Channel) {
        // Both, because liked videos identify their channel by id while
        // subscriptions and older records only carry the title.
        bans.add(.channel, channel.name)
        if !channel.channelID.isEmpty { bans.add(.channel, channel.channelID) }
        bans.save()
        syncBans()
        records = records.map(applyingBans)
        recomputeDerived()
        // The removal is written into each record's `extra`, so the struck-off
        // state is part of the snapshot and has to be saved with it.
        RecordStore.save(records)
    }

    func banSport(_ name: String) {
        bans.add(.sport, name)
        bans.save()
        syncBans()
        // Struck off the list directly, because there is no longer a workout row
        // to annotate: `topSports` skipped records marked removed, and the raw
        // workouts are discarded as soon as they have been read. The ban itself
        // is what persists, and it is re-applied to the next distillation by
        // `applyLifestyle`.
        sports.removeAll { bans.contains(.sport, $0.name) }
        records = records.map(applyingBans)
        recomputeDerived()
        RecordStore.save(records)
        // The lifestyle figures are no longer part of the record snapshot, so
        // the server needs telling separately that this sport is gone.
        syncLifestyle()
    }

    /// Marks a record removed if it belongs to something banned. Rows are kept
    /// and annotated rather than deleted — see `DistilledRecord.markedRemoved`.
    private func applyingBans(_ record: DistilledRecord) -> DistilledRecord {
        guard !bans.isEmpty, !record.isRemovedByUser else { return record }

        if Modality.music.sources.contains(record.source) {
            // Every artist credited on the track, so a banned artist's
            // collaborations go too.
            let credited = record.creator.split(separator: "|").map { String($0) }
            for artist in credited + [record.name] where bans.contains(.artist, artist) {
                return record.markedRemoved(reason: "banned_artist")
            }
        }

        if Modality.media.sources.contains(record.source) {
            let keys = [record.creator, record.name, record.itemID,
                        record.extraValue("channel_id") ?? ""]
            for key in keys where !key.isEmpty && bans.contains(.channel, key) {
                return record.markedRemoved(reason: "banned_channel")
            }
        }

        // Only the workout rows: banning "Yoga" should take the yoga sessions
        // out, not the day's step count that happens to include the walk there.
        if record.dataType == "workout", bans.contains(.sport, record.name) {
            return record.markedRemoved(reason: "banned_sport")
        }

        return record
    }

    /// Everything read off the records, in one pass, whenever they change.
    ///
    /// Re-distilling the same source with the same library produces an equal
    /// `TreeState`, so the tree won't re-animate for no reason.
    private func recomputeDerived() {
        var state = TreeMetrics.state(from: records)
        // Lifestyle is measured from the figures rather than the rows, because
        // its rows no longer exist — see `TreeMetrics.lifestyleMetrics`. Applied
        // after `state`, which would otherwise have found the two demographic
        // records and sized the branch on those.
        state.branches[.lifestyle] = TreeMetrics.lifestyleMetrics(
            sports: sports,
            chronotypeDays: chronotype?.days,
            hasSignals: chronotype != nil || averageDailySteps != nil || !hourlyActivity.isEmpty
        )
        treeState = state
        skeleton = TreeSkeleton.make(from: treeState, seed: Self.treeSeed)
        musicArtists = MusicHighlights.topArtists(in: records)
        musicGenres = MusicHighlights.genreShare(in: records)
        mediaChannels = MediaHighlights.topChannels(in: records)
        // The lifestyle figures are deliberately absent. They used to be
        // recomputed here like everything else, which stopped working the moment
        // the raw HealthKit rows were discarded rather than stored: this method
        // runs after *any* change — banning an artist, editing a birthday — so
        // it would have found no health records and silently blanked the whole
        // lifestyle card in response to something unrelated. They are set once,
        // by `applyLifestyle(from:)` at distill time and by the restore.
        identity = IdentitySummary.summary(in: records)
        // After `identity`, which it reads for the age offset and the district.
        let previousSong = exampleProfile.song
        exampleProfile = ExampleProfile.make(
            identity: identity, records: records, fetchedHook: fetchedHook
        )
        if exampleProfile.song != previousSong { resolveHook() }
        lastCollectedAt = records.map(\.collectedAt).max()
        returnedSources = Set(records.map(\.source))
    }

    /// Looks up the chorus of the current top song and re-publishes the profile
    /// with it.
    ///
    /// Fire-and-forget on purpose: the card is already on screen by the time
    /// this runs, and a caption that improves a moment later is far better than
    /// a screen that waits on a network call to draw. A failure changes nothing
    /// — the bundled hook or the "On repeat" line is already showing.
    private func resolveHook() {
        fetchedHook = nil
        guard let song = exampleProfile.song, song != fetchedHookSong else { return }
        fetchedHookSong = song

        Task { [song] in
            guard let hook = await LyricsService.shared.hook(
                artist: song.artist, title: song.title
            ) else { return }
            // The library may have moved on while the request was in flight.
            guard exampleProfile.song == song else { return }

            fetchedHook = hook
            exampleProfile = ExampleProfile.make(
                identity: identity, records: records, fetchedHook: hook
            )
        }
    }

#if DEBUG
    /// TEMPORARY — debug only. Steps the tree through its stages without
    /// connecting anything, so the growing animation can be watched end to end.
    /// It drives the same published state a real distillation does, so the
    /// watering, the dissolve and the redraw all run exactly as they would.
    ///
    /// Walks every `Modality`, not just the connectable ones, and wraps back to
    /// bare soil after the last.
    /// How far the preview stepper walks: the illustrated stages only. Past
    /// them the plant is generated geometry, which is not what the stepper is
    /// for — and connecting a fourth or fifth source is not a thing the app can
    /// do yet either.
    static let previewStages = SeedlingStage.allCases.count - 1

    func advancePreviewStage() {
        guard !isDistilling else { return }

        // Runs through a pretend distillation rather than snapping the state,
        // so the watering can appears and pours the way it does for a real
        // connection — the can is tied to `isDistilling`, so a straight state
        // change would skip it.
        youtubeStatus = .running
        let next = treeState.branches.count >= Self.previewStages ? 0 : treeState.branches.count + 1
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            applyPreview(connected: next)
            youtubeStatus = .idle
        }
    }

    /// Seeds the state as though the first `connected` modalities had been
    /// distilled. Snaps — no faked delay, no watering — because the launch
    /// argument exists to be screenshotted, not watched; the stepper above adds
    /// the pretend distillation when the animation is the thing being looked at.
    func applyPreview(connected: Int) {
        var branches: [Modality: ModalityMetrics] = [:]
        var seeded: [DistilledRecord] = []

        for (step, modality) in Modality.allCases.prefix(max(0, connected)).enumerated() {
            // A record per source, so the "Connected to …" bar has app marks to
            // show. Without them the preview walks the stages but never
            // exercises the thing the bar is for.
            for source in modality.sources {
                seeded += previewRecords(for: source)
            }
            branches[modality] = ModalityMetrics(
                volume: 60 + 45 * step,
                diversity: min(0.9, 0.35 + 0.13 * Double(step)),
                dominantShare: max(0.15, 0.55 - 0.08 * Double(step))
            )
        }

        records = seeded
        recomputeDerived()
        // Explicitly, because `recomputeDerived` no longer derives the lifestyle
        // figures — the real ones are worked out at distill time and the raw
        // rows discarded. The fixture health rows are the one place records and
        // lifestyle still coincide, so without this the preview grows a
        // lifestyle branch above an empty lifestyle card.
        applyLifestyle(from: seeded)
        knownConnections.formUnion(seeded.map(\.source))
        // The fixture's own branch metrics, not the ones the records imply:
        // the point of the stepper is to reach a stage, not to measure one.
        treeState = TreeState(branches: branches)
        skeleton = TreeSkeleton.make(from: treeState, seed: Self.treeSeed)
    }

    private static let previewDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Stand-in records for one source.
    ///
    /// Music sources get *songs*, not a single marker row: the dashboard ranks
    /// artists by song count, so a marker would leave its card empty and the
    /// layout unexaminable. Counts descend so the ranking has something to sort,
    /// and the names are a mix of scripts because the real libraries this is
    /// standing in for are — a card that only fits Latin names is broken.
    ///
    /// No `artwork=`: these are the monogram path, which is also what real
    /// records distilled before the distillers kept image URLs will show.
    private func previewRecords(for source: String) -> [DistilledRecord] {
        let now = Date()

        if source == "youtube" {
            // Subscriptions and likes, since the media card ranks one against
            // the other. Two of the five are subscribed, and one of those is
            // deliberately mid-table so the boost is visible in the order.
            let channels = [("LE SSERAFIM", 9, false), ("BABYMONSTER", 6, true),
                            ("DaftTaengk", 5, false), ("i-dle (아이들)", 3, true),
                            ("Rock Music", 2, false)]
            // Real-looking likes at the head of the list, standing in for the
            // shape of a real one: a music video, and a handful from one comedy
            // channel.
            //
            // The proportions are the point. The MV is first, so the profile has
            // to *skip* it to honour the two-ontology rule rather than merely
            // being assumed to. And the comedy clips are several rather than
            // one, because a single like no longer earns a line — see
            // `ExampleProfile.minimumLikesForInterest`. One stray clip sitting
            // at the top of the like list used to decide a whole bio line.
            var rows: [DistilledRecord] = [
                DistilledRecord(
                    source: source, dataType: "liked_video", itemID: "yt-mv",
                    name: "Official MV — 청춘 (Youth)", creator: "LE SSERAFIM",
                    detail: "The official music video.",
                    extra: "channel_id=chan-LE SSERAFIM", collectedAt: now
                )
            ]
            rows += ["Socially inept", "Group chats, ranked", "My roommate's start-up",
                     "The worst party I ever threw"].enumerated().map { index, title in
                DistilledRecord(
                    source: source, dataType: "liked_video", itemID: "yt-comedy-\(index)",
                    name: title, creator: "Socially Inept",
                    detail: "Stand-up comedy from a tech-adjacent basement.",
                    extra: "channel_id=chan-Socially Inept", collectedAt: now
                )
            }
            rows += channels.flatMap { name, likes, subscribed -> [DistilledRecord] in
                var channelRows: [DistilledRecord] = []
                if subscribed {
                    channelRows.append(
                        DistilledRecord(
                            source: source, dataType: "subscription", itemID: "chan-\(name)",
                            name: name, creator: name, detail: "",
                            extra: "subscribed_at=", collectedAt: now
                        )
                    )
                }
                channelRows += (0..<likes).map { index in
                    DistilledRecord(
                        source: source, dataType: "liked_video", itemID: "\(name)-\(index)",
                        name: "Preview video \(index + 1)", creator: name, detail: "",
                        extra: "channel_id=chan-\(name)", collectedAt: now
                    )
                }
                return channelRows
            }
            return rows
        }

        if source == "health" {
            // Age, sex and a district, so the identity card has something to
            // draw. The simulator has no Health characteristics and no GPS fix
            // worth reverse-geocoding, so this is the only way to see it.
            var rows: [DistilledRecord] = [
                DistilledRecord(source: "health", dataType: "age", itemID: "age",
                                name: "29", creator: "", detail: "",
                                extra: "birth_year=1997", collectedAt: now),
                DistilledRecord(source: "health", dataType: "biological_sex", itemID: "biological_sex",
                                name: "Male", creator: "", detail: "",
                                extra: "raw=2", collectedAt: now),
                DistilledRecord(source: "location", dataType: "place", itemID: "current",
                                name: "Clayton, St. Louis", creator: "", detail: "United States",
                                extra: "district=Clayton;city=St. Louis;region=MO;country=United States",
                                collectedAt: now)
            ]
            rows += healthActivityFixture(now: now)
            return rows
        }

        if Modality.music.sources.contains(source) {
            return musicFixture(for: source, now: now)
        }

        return [
            DistilledRecord(
                source: source, dataType: "preview", itemID: "preview",
                name: "Preview", creator: "", detail: "", extra: "", collectedAt: now
            )
        ]
    }

    /// The health branch's activity data, kept apart from the identity rows so
    /// each reads as one thing.
    private func healthActivityFixture(now: Date) -> [DistilledRecord] {
        let source = "health"
        // Four weeks of a fairly early riser, with a weekend lie-in and one
            // 05:00 outlier — enough for the median and the spread to be doing
            // visible work rather than echoing a single number. The simulator's
            // Health store is empty and can't be seeded from the command line,
            // so this is the only way to see the card without a device.
            let wakes = ["06:00", "07:00", "07:00", "06:00", "07:00", "09:00", "10:00",
                         "07:00", "06:00", "07:00", "07:00", "08:00", "09:00", "10:00",
                         "05:00", "07:00", "06:00", "07:00", "07:00", "09:00", "09:00",
                         "07:00", "07:00", "06:00", "08:00", "07:00", "10:00", "09:00"]
            var rows: [DistilledRecord] = wakes.enumerated().map { index, wake in
                let day = Calendar.current.date(byAdding: .day, value: -index, to: now) ?? now
                let label = Self.previewDayFormatter.string(from: day)
                return DistilledRecord(
                    source: source, dataType: "activity_day", itemID: label, name: label,
                    creator: "", detail: "",
                    extra: "exercise_min=\(20 + index % 25);active_kcal=\(320 + index * 7);"
                        + "steps=\(6000 + index * 130);first_move=\(wake)",
                    collectedAt: now
                )
            }

            // A day shaped like a commute, a lunch walk and an evening peak.
            let curve: [Double] = [0.2, 0.1, 0.1, 0.1, 0.2, 0.6, 1.8, 4.2, 6.0, 5.1, 4.4, 5.0,
                                   6.8, 5.4, 4.6, 4.9, 5.6, 7.4, 8.2, 6.1, 4.2, 2.8, 1.4, 0.6]
            let total = curve.reduce(0, +)
            rows += curve.enumerated().map { hour, weight in
                let label = String(format: "%02d:00", hour)
                return DistilledRecord(
                    source: source, dataType: "activity_hour", itemID: label, name: label,
                    creator: "", detail: "",
                    extra: "hour=\(hour);steps=\(Int(weight * 180));"
                        + String(format: "share=%.4f", weight / total),
                    collectedAt: now
                )
            }

        let sports = [("Running", 12, 42), ("Strength training", 8, 55),
                          ("Cycling", 5, 70), ("Yoga", 3, 30)]
            rows += sports.flatMap { name, count, minutes in
                (0..<count).map { index in
                    DistilledRecord(
                        source: source, dataType: "workout", itemID: "\(name)-\(index)",
                        name: name, creator: "Apple Watch", detail: "",
                        extra: "duration_min=\(minutes);energy_kcal=\(minutes * 9)",
                        collectedAt: now
                    )
                }
            }
        return rows
    }

    /// The music branch's artists.
    private func musicFixture(for source: String, now: Date) -> [DistilledRecord] {
        // Genres too, so the genre bar has something to draw. Only Apple Music
        // carries them, and it needs a physical device, so without this the
        // block cannot be seen in the simulator at all.
        let cast = [("周杰倫 Jay Chou", 9, "Mandopop|Pop"), ("David Tao", 7, "Mandopop|R&B"),
                    ("潮池蓝", 5, "C-Pop"), ("Leehom Wang", 4, "Mandopop"),
                    ("Joker Xue", 3, "C-Pop|Ballad"), ("Where Winds Meet", 2, "Soundtrack")]
        // Rank 1 is a real title with a real hook, so the example profile's
        // caption can be seen doing what it does rather than only its fallback.
        // Rank 2 onward stay generic — they feed the artist counts, and naming
        // sixty songs would be inventing a library rather than standing in for one.
        var rows: [DistilledRecord] = [
            DistilledRecord(
                source: source,
                dataType: "top_track",
                itemID: "\(source)-hooked",
                name: "青花瓷",
                creator: "周杰倫 Jay Chou",
                detail: "rank=0",
                extra: "album=我很忙;genres=Mandopop|Pop",
                collectedAt: now
            )
        ]
        rows += cast.flatMap { artist, songs, genres in
            (0..<songs).map { index in
                DistilledRecord(
                    source: source,
                    dataType: "top_track",
                    itemID: "\(source)-\(artist)-\(index)",
                    name: "Preview song \(index + 1)",
                    creator: artist,
                    detail: "rank=\(index + 1)",
                    extra: "album=Preview;genres=\(genres)",
                    collectedAt: now
                )
            }
        }
        return rows
    }
#endif

    // MARK: - Export

    func prepareExport() {
        exportDocument = CSVDocument(text: CSVExporter.makeCSV(from: records))
        isExporterPresented = true
    }

    func handleExportResult(_ result: Result<URL, Error>) {
        switch result {
        case .success:
            exportResultMessage = "CSV saved. \(records.count) distilled records exported."
        case .failure(let error):
            exportResultMessage = "Export failed: \(error.localizedDescription)"
        }
    }
}
