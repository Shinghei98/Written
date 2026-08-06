import CoreLocation
import Foundation
import SwiftUI
import UIKit

@MainActor
final class DistillViewModel: ObservableObject {

    @Published var youtubeStatus: SourceStatus = .idle
    @Published var appleMusicStatus: SourceStatus = .idle
    @Published var podcastStatus: SourceStatus = .idle
    @Published var healthStatus: SourceStatus = .idle
    @Published var calendarStatus: SourceStatus = .idle
    @Published var googleCalendarStatus: SourceStatus = .idle
    /// Beta only; removed before the App Store build. See `Modality.sources`.
    @Published var spotifyStatus: SourceStatus = .idle
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
    /// The three cards added alongside Media's channels. Derived on the same
    /// terms as everything above: once when the records change, never in a body.
    @Published private(set) var podcastShows: [ListeningHighlights.Show] = []
    /// **The events, not the shape.** The card printed readings — how many were
    /// arranged, how many booked, the busiest day — and a person does not
    /// recognise their own year in a count. They recognise "Chichen Itza Premier
    /// Tour" and "Flight to Los Angeles". One row per distinct title, since a
    /// calendar is mostly repetition and fifty copies of "Gym" would bury the
    /// three things worth reading.
    @Published private(set) var events: [ListeningHighlights.Event] = []
    @Published private(set) var chronotype: LifestyleHighlights.Chronotype?
    @Published private(set) var hourlyActivity: [Double] = []
    @Published private(set) var sports: [LifestyleHighlights.Sport] = []
    @Published private(set) var averageDailySteps: Int?

    /// Who the profile belongs to: age and sex from Health, district and city
    /// from one location fix.
    @Published private(set) var identity = IdentitySummary()

    /// Why the last biographics edit didn't take, or `nil` if it did.
    ///
    /// The rows that own a column on `public.users` — name, age, gender,
    /// location — write the server first and the device only if it accepted, so
    /// that nothing is ever shown that Postgres never heard of. The cost of that
    /// trade was that a refusal looked *exactly* like the confirm button not
    /// working: the sheet closed, the row stayed empty, and nothing said why.
    /// Somebody hit it during onboarding and had no way to tell a rejected write
    /// from a broken button.
    ///
    /// So the trade keeps its good half and loses its bad one. The value still
    /// doesn't appear until the server has it; the *reason* it didn't appear now
    /// does. `SyncService.lastError` was already recorded for exactly this and
    /// simply never read — see the known gap in CLAUDE.md.
    ///
    /// **Named for the failure, not for the row.** It began as the biographics
    /// rows' banner and now carries the photographs' too, because they are the
    /// same event: something the user changed did not reach the server, and one
    /// banner in one place beats a second that can disagree with it.
    @Published var saveError: String?

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
    /// **A second service on the same Google client**, because the scopes and
    /// therefore the grants are different. Its refresh token is filed under a
    /// key derived from the provider's name, so the two cannot overwrite each
    /// other — see `OAuthProvider.googleCalendar`.
    private let googleCalendarOAuth = OAuthPKCEService(provider: .googleCalendar)
    private let spotifyOAuth = OAuthPKCEService(provider: .spotify)

    init() {
        // The last snapshot, before anything draws. A connection is a durable
        // fact — "has been connected", not "is listening" — so the tree and the
        // connected bars have to be right on the first frame rather than
        // appearing a beat later or, as they used to, not at all.
        records = RecordStore.load()
        // Health's figures come from their own file: its rows are discarded, so
        // unlike every other source there is nothing in `records` to rebuild the
        // branch from. Before `recomputeDerived`, which reads them.
        if let cached = LifestyleStore.load() {
            chronotype = cached.chronotype
            hourlyActivity = cached.hourlyActivity
            sports = cached.sports
            averageDailySteps = cached.averageDailySteps
            // **And it counts as a connection.** This cache exists precisely so
            // Health does not have to wait for a round trip — see its own note —
            // but the figures were being restored without the *fact* that Health
            // was ever connected, and `connectedSources` reads that fact rather
            // than these values. Health leaves no rows in `records`, so unlike
            // every other source it has nothing else to be inferred from: its
            // mark was absent from the connected bar on every launch until
            // `source_connections` came back over the network, which is the
            // second or two somebody watches it appear in.
            knownConnections.insert("health")
        }
        // And every other source's connections, for the same reason Health
        // needed its own file: a source that returned nothing leaves nothing in
        // `records` to be inferred from, so without this it reads as never
        // connected until the server answers — and not at all offline.
        knownConnections.formUnion(ConnectionStore.load())
        if !records.isEmpty || !knownConnections.isEmpty || chronotype != nil { recomputeDerived() }

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
            || healthStatus.isRunning || calendarStatus.isRunning
            || googleCalendarStatus.isRunning
            || podcastStatus.isRunning
            || spotifyStatus.isRunning
    }

    func status(for source: String) -> SourceStatus {
        switch source {
        case "youtube": return youtubeStatus
        case "apple_music": return appleMusicStatus
        case "health": return healthStatus
        case "apple_podcasts": return podcastStatus
        case "apple_calendar": return calendarStatus
        case "google_calendar": return googleCalendarStatus
        case "spotify": return spotifyStatus
        default: return .idle
        }
    }

    /// Beta only; removed before the App Store build. Shaped like the other
    /// OAuth distillers, and its records sync like every other source's — which
    /// is the part Spotify's Developer Terms do not allow and the reason this
    /// has a removal date rather than a home. See CLAUDE.md.
    func distillSpotify() {
        guard !spotifyStatus.isRunning else { return }
        spotifyStatus = .running
        Task {
            do {
                let distiller = SpotifyDistiller(oauth: spotifyOAuth)
                let newRecords = try await distiller.distill()
                replaceRecords(from: "spotify", with: newRecords)
                spotifyStatus = .done(count: newRecords.count)
            } catch {
                spotifyStatus = .failed(message: error.localizedDescription)
            }
        }
    }

    /// Entry point for the tree UI, which thinks in sources rather than methods.
    func distill(source: String) {
        switch source {
        case "youtube": distillYouTube()
        case "apple_music": distillAppleMusic()
        case "health": distillHealth()
        case "apple_podcasts": distillPodcasts()
        case "apple_calendar": distillCalendar()
        case "google_calendar": distillGoogleCalendar()
        case "spotify": distillSpotify()
        default: break
        }
    }

    /// How deep the dashboard's ranked lists go, now that they scroll.
    static let rankedEntries = 60

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
        LifestyleStore.clear()
        ConnectionStore.clear()
        // The chat cache holds *other people's* words, which makes it the one
        // store on this device with somebody else's data in it. If this line is
        // ever dropped it becomes the only thing that survives a sign-out.
        ChatStore.clear()
        UserDefaults.standard.removeObject(forKey: Self.treeSeedKey)
        // Unsent work rather than a cache, so keeping it would be defensible —
        // but signing out leaves nothing on this device, and of everything here
        // a photograph is the last thing to make an exception for. What makes
        // that acceptable is that sign-out flushes first, while the token is
        // still good; this discards only what a failure left behind.
        PendingPhotoStore.clear()
        pendingPhotos = [:]
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
        // Written down, not just held: this is the restore that reinstates a
        // reinstalled phone, and the *next* launch should not have to wait for
        // the network to learn the same thing again. Nothing else writes this
        // file for a source that left no rows.
        ConnectionStore.save(knownConnections)

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

        // Before `recomputeDerived`, and that order is the whole point.
        //
        // The lifestyle branch is the one part of the tree not derived from the
        // records — its rows are discarded, so `recomputeDerived` sizes it from
        // these four figures instead. Assigning them *after* the recompute meant
        // the tree was rebuilt from whatever they held a moment earlier, which on
        // a cold launch is nothing: the branch came out nil, nothing recomputed
        // it afterwards, and Apple Health read as disconnected on every relaunch
        // even though the restore had just fetched its signals successfully.
        if let lifestyle = snapshot.lifestyle {
            chronotype = lifestyle.chronotype
            hourlyActivity = lifestyle.hourlyActivity
            sports = lifestyle.sports.filter { !bans.contains(.sport, $0.name) }
            averageDailySteps = lifestyle.averageDailySteps
            cacheLifestyle()
        }

        recomputeDerived()

        // Age and sex live on the user object; district still arrives as a
        // record, so only fill what `recomputeDerived` couldn't.
        if identity.age == nil { identity.age = snapshot.identity.age }
        if identity.sex == nil { identity.sex = snapshot.identity.sex }
        if identity.place == nil { identity.place = snapshot.identity.place }

        RecordStore.save(records)
    }

    /// Pulls the account down, replacing whatever the cache had.
    /// True until the server's snapshot has landed (or failed to).
    ///
    /// **The garden needs this to tell a restore from a growth.** `GrowProfileView`
    /// animates whenever `treeState` changes, which is right for a source being
    /// connected and wrong for the moment a signed-in account's own plant
    /// arrives. Without it the sequence on sign-in is: draw the seedling because
    /// nothing has hydrated yet, mark that as the first draw, then hydrate — and
    /// the second draw is treated as *growth*, so the plant dissolves, regrows
    /// and pops its badges in on their timers. Reported as the plant
    /// reassembling with the icons moving around until they land.
    @Published private(set) var isHydrating = SupabaseAuth.hasStoredSession

    func restoreFromServer() {
        Task {
            guard let snapshot = await RestoreService.shared.hydrate() else {
                isHydrating = false
                return
            }
            apply(snapshot)
            isHydrating = false
            // After the server's version has landed, not before: adopting first
            // would compare against an empty cache, write two rows, and then be
            // overwritten by the very snapshot it should have been checked
            // against. Idempotent, so the shell's own call costs nothing here.
            adoptStoredCommunicationStyle()
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

    /// Why this source cannot work *before* it is tried, where that is knowable.
    ///
    /// Only Calendar today, and only because EventKit will report its
    /// authorization without prompting. HealthKit will not: read authorization
    /// is hidden by design, so a declined Health read and an empty Health app
    /// are the same answer — which is exactly why `HealthError.noData` is named
    /// for the symptom. There is no equivalent here and inventing one would mean
    /// guessing.
    func blockedMessage(for modality: Modality) -> String? {
        guard modality.sources.contains("apple_calendar"), CalendarDistiller.isBlocked else {
            return nil
        }
        return CalendarDistiller.CalendarError.notAuthorized.localizedDescription
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

    /// Apple Podcasts, through the media library. Shaped like Apple Music
    /// because it is the same framework family and the same one system dialog.
    func distillPodcasts() {
        guard !podcastStatus.isRunning else { return }
        podcastStatus = .running
        Task {
            do {
                let newRecords = try await PodcastDistiller().distill()
                replaceRecords(from: "apple_podcasts", with: newRecords)
                podcastStatus = .done(count: newRecords.count)
            } catch {
                podcastStatus = .failed(message: Self.detail(of: error))
            }
        }
    }

    func distillAppleMusic() {
        guard !appleMusicStatus.isRunning else { return }
        appleMusicStatus = .running
        Task {
            // **Two libraries behind one tap.** MusicKit reads the Apple Music
            // account and needs a subscription to return anything at all;
            // `MusicLibraryDistiller` reads the device library and needs none.
            // They share the "Media & Apple Music" grant, so this is one dialog
            // and one picker row — see that distiller for why the hole it fills
            // is invisible from a developer's phone.
            //
            // Run and reported independently: somebody with no subscription must
            // still get their device library, and a MusicKit failure that took
            // the local songs down with it would be the exact bug this is here
            // to fix.
            var collected = 0
            var failure: String?

            do {
                let newRecords = try await AppleMusicDistiller().distill()
                replaceRecords(from: "apple_music", with: newRecords)
                collected += newRecords.count
            } catch {
                failure = Self.detail(of: error)
            }

            do {
                let libraryRecords = try await MusicLibraryDistiller().distill()
                // Replaced under its own source, or a second distillation would
                // append these again rather than replace them.
                replaceRecords(from: "music_library", with: libraryRecords)
                collected += libraryRecords.count
            } catch {
                failure = failure ?? Self.detail(of: error)
            }

            // **A failure only counts if nothing came back at all.** Not being
            // subscribed is not a refusal and does not stop anything: the
            // device library reads without one, and somebody with three hundred
            // songs on their phone has a music branch whether or not they pay
            // Apple monthly. So a subscription is never checked *before*
            // distilling — only afterwards, and only to explain an empty result.
            if collected > 0 {
                appleMusicStatus = .done(count: collected)
            } else {
                let reason = await Self.emptyMusicReason()
                appleMusicStatus = .failed(message: failure ?? reason)
            }
        }
    }

    /// Why a music distillation came back with nothing, said as precisely as
    /// the frameworks allow.
    ///
    /// Reached only when **both** libraries returned zero rows, so it is
    /// explaining an absence rather than a refusal — a refused permission throws
    /// `MusicError.notAuthorized` long before this and carries its own sentence
    /// about Settings.
    ///
    /// The subscription is checked *here* and nowhere earlier, which is the
    /// whole shape of this: not paying Apple monthly is not a reason to refuse
    /// somebody a music branch, it is only ever a reason a particular kind of
    /// data is missing.
    private static func emptyMusicReason() async -> String {
        switch await AppleMusicDistiller.subscriptionState() {
        case .authorizedNoSubscription:
            return "No subscribed Apple Music account on this device, and no music saved to the phone either. Subscribe or add some music, then try again."
        case .subscribed:
            return "Apple Music is connected but your library came back empty."
        case .unknown:
            // Deliberately vague, because the state is. This fires for a region
            // that cannot use Apple Music and for a request that never left the
            // device, and naming either would be a guess.
            return "Couldn't read anything from Apple Music. Try again."
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

    /// **A Health retry always runs, even though it cannot grant anything.**
    ///
    /// A guard here once refused to re-distil after an empty run, on the
    /// reasoning that HealthKit shows its permission sheet only once so nothing
    /// could change. True of the *permission* and wrong about the *point*: the
    /// sequence that matters is read the message, go and turn the categories on
    /// in Health, come back and tap. Blocking the retry breaks precisely the
    /// person who did what they were told.
    func distillHealth() {
        guard !healthStatus.isRunning else { return }
        healthStatus = .running
        // Stamped here, on the main actor, at the moment the tap is handled —
        // the distiller cannot see this and the gap between the two is the
        // thing under suspicion. See `HealthKitDistiller.requestAuthorization`.
        let requestedAt = Date()
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
                    try await HealthKitDistiller().distill(requestedAt: requestedAt)
                }.value

                // HealthKit reports a declined read as no data rather than as an
                // error, so a zero-record distill is the one case worth naming —
                // otherwise the branch grows on an empty permission and the user
                // is told nothing. **That check now lives in the distiller**,
                // which is the only place that knows whether the user was ever
                // shown the sheet, and so the only place that can say which of
                // the two empty results this is. It arrives through `catch`.

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
        cacheLifestyle()
    }

    /// The four figures to disk, so the branch survives a relaunch without
    /// waiting on the network — the only source that needs this, because it is
    /// the only one whose rows are thrown away. See `LifestyleStore`.
    private func cacheLifestyle() {
        LifestyleStore.save(
            LifestyleStore.Cached(
                chronotype: chronotype,
                hourlyActivity: hourlyActivity,
                sports: sports,
                averageDailySteps: averageDailySteps
            )
        )
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

    /// Apple Calendar: the events someone keeps, and the calendars they sit in.
    ///
    /// Unlike Health, the rows are kept and synced — the titles are the signal
    /// here rather than something to reduce to a count. See `CalendarDistiller`
    /// for what that means for other people's names.
    func distillCalendar() {
        guard !calendarStatus.isRunning else { return }
        calendarStatus = .running
        Task {
            do {
                let newRecords = try await CalendarDistiller().distill()
                // A granted permission over an empty calendar returns the
                // calendars and no events, which is a real answer but not a
                // useful one — and it looks identical to a permission that was
                // declined, the way an empty HealthKit read does.
                guard newRecords.contains(where: { $0.dataType == "event" }) else {
                    calendarStatus = .failed(message: CalendarDistiller.CalendarError.noData.localizedDescription)
                    return
                }
                replaceRecords(from: "apple_calendar", with: newRecords)
                calendarStatus = .done(count: newRecords.count)
            } catch {
                calendarStatus = .failed(message: error.localizedDescription)
            }
        }
    }

    /// Google Calendar, for people whose phone is not already supplying it.
    ///
    /// **Not offered where a Google account is already on the device** — see
    /// `CalendarDistiller.hasGoogleAccountOnDevice`. This is the guard behind
    /// that, because a hidden row is a drawing and not a rule: somebody who adds
    /// the account to their phone *after* connecting here would otherwise start
    /// collecting every event twice.
    func distillGoogleCalendar() {
        guard !googleCalendarStatus.isRunning else { return }
        googleCalendarStatus = .running
        Task {
            do {
                let newRecords = try await GoogleCalendarDistiller(oauth: googleCalendarOAuth).distill()
                // An account with calendars and no events is a real answer and
                // not a useful one, and it looks exactly like a refused grant —
                // the same reason Apple Calendar and Health both fail loudly on
                // nothing.
                guard newRecords.contains(where: { $0.dataType == "event" }) else {
                    googleCalendarStatus = .failed(
                        message: "No events in that Google Calendar."
                    )
                    return
                }
                replaceRecords(from: "google_calendar", with: newRecords)
                googleCalendarStatus = .done(count: newRecords.count)
            } catch OAuthPKCEService.OAuthError.cancelled {
                // Closing the browser sheet is not a failure.
                googleCalendarStatus = .idle
            } catch {
                googleCalendarStatus = .failed(message: error.localizedDescription)
            }
        }
    }

    private func replaceRecords(from source: String, with newRecords: [DistilledRecord]) {
        // **Reaching here is what "connected" means**, and it is deliberately
        // not "left some rows behind". A YouTube account with no likes and no
        // subscriptions distils perfectly and returns nothing; so does a
        // Podcasts library with nothing downloaded, which is the *normal* case
        // rather than an edge one. Inferring the connection from the row count
        // left those people with an ungrown branch, a prompt still asking for
        // the same modality, and no error to explain either — reported as the
        // flow never moving on.
        //
        // Calendar and Health never reach this line on an empty result: both
        // throw first, because for them an empty answer and a refused
        // permission are indistinguishable and saying so is right. That
        // difference is why this belongs here rather than in each distiller.
        if !knownConnections.contains(source) {
            knownConnections.insert(source)
            ConnectionStore.save(knownConnections)
        }
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

        publishDiscoveryCard()
    }

    /// Puts this person into the pool other people are shown from.
    ///
    /// **This is the half of discovery that never existed.** `DiscoveryService`
    /// reads `discovery_cards`, `tools/seed_synthetic.py` writes six of them
    /// with the secret key, and the app wrote none — so the synthetic accounts
    /// were discoverable and every real signup was invisible. `0007` has carried
    /// the `own row` insert and update policies since the beginning; only the
    /// caller was missing.
    ///
    /// Called from `sync` so it rides the same moment as everything else that
    /// leaves the device — a card is only worth publishing once there is a
    /// distillation behind it, and this is where one has just landed.
    ///
    /// **Subjects only.** Things a sentence can be *about*. The songs and
    /// videos they came from stay behind the policy that has always guarded
    /// them. See the header of `0007_discovery.sql` — this table is readable by
    /// every signed-in user, which is true of nothing else in this schema, and
    /// it stays worth that only by staying this thin.
    ///
    /// **Which is also why it is narrower than "subjects".** Being publishable
    /// takes two things, not one: the subject has to be something a sentence
    /// can be about *and* something the source's terms allow a stranger to see.
    /// Apple Music artists pass both. YouTube channels pass the first and fail
    /// the second — see the note at the call site. Any source added here needs
    /// the second question asked as well, and it is the one that is easy to
    /// forget, because nothing in the schema or the type system asks it.
    func publishDiscoveryCard() {
        guard let name = SupabaseAuth.shared.firstName, !name.isEmpty else { return }

        let age = identity.age
        let district = identity.place
        var interests: [(domain: String, subject: String, source: String)] = []
        interests += musicArtists.map {
            (Ontology.Domain.music.rawValue, $0.name, "applemusic")
        }
        // **YouTube channels are deliberately absent, and this is a rule rather
        // than a simplification.** The YouTube API Services Developer Policies
        // III.E.3.b: an API Client "must not display or allow access to
        // Authorized Data to anyone other than the authorizing user or agents
        // expressly approved by that user". A subscription list is Authorized
        // Data, and a channel name lifted straight out of it does not stop being
        // Authorized Data by being called a subject — `discovery_cards` is the
        // one table in this schema every signed-in user may read, so a channel
        // written here is shown to strangers by construction.
        //
        // It used to append `mediaChannels` as `(domain, channel.name,
        // "youtube")`, so every real card carried them.
        //
        // **This is the interim shape of what the hub design fixes properly.**
        // Once YouTube records are summarised into keyword hubs and each is put
        // to the user for approval, what travels is Written's own vocabulary
        // rather than a copy of a YouTube record, and it can be published — the
        // test being whether a reader can recover the channel from the keyword.
        // "Long-form science" cannot; "Kurzgesagt-style space animation" can,
        // and is still Authorized Data wearing a different hat.
        //
        // Apple Music is untouched: `applemusic` subjects are covered by no
        // such term. `podcastShows` is the obvious substitute for the lost
        // richness and is deliberately *not* added here — publishing a new
        // category of subject about somebody is its own decision, not a
        // consolation prize for this one.

        Task.detached(priority: .utility) { [weak self] in
            // Read from the server rather than from anything local: the photos
            // may have been uploaded on a different device, or in a session
            // before this one. `PhotoService.paths` is the authority, and an
            // empty answer is what keeps somebody with no face out of the pool.
            //
            // **`nil` is not an empty answer, and conflating the two un-listed
            // people who had photographs.** An empty list is a decision — no
            // face, no card — while a failed read is no information at all. Ask
            // again on the next distillation or photo flush rather than
            // concluding from a dropped request that somebody has no face.
            guard let photoPaths = await PhotoService.shared.paths() else { return }

            let card = DiscoveryCardService.Card(
                displayName: name,
                age: age,
                district: district,
                interests: interests,
                photoPaths: photoPaths
            )
            let published = await DiscoveryCardService.shared.publish(card)

            // **The third time this project has recorded an error nobody
            // reads.** `SyncService.lastError` and `PhotoService.lastError`
            // were the first two, and both cost a session to find. Being
            // absent from discovery is invisible *and* consequential — nobody
            // can find you — so a genuine refusal from the server is worth
            // saying.
            //
            // Only a genuine one: `publish` returns false with `lastError` nil
            // when it declines to publish a faceless card, which is a decision
            // rather than a fault and must not raise a banner on every
            // distillation.
            if !published, let reason = await DiscoveryCardService.shared.lastError {
                await MainActor.run { self?.saveError = "Couldn't update your profile card — \(reason)" }
            }
        }
    }

    /// Photographs changed on the dashboard, owed to the server.
    ///
    /// Position to what should happen to it. A dictionary rather than a list of
    /// events so **the last write to a slot wins**: pick, swap, then remove
    /// collapses to one delete, and the intermediate pictures are never uploaded
    /// at all. That is the whole point of batching.
    ///
    /// Mirrored to disk by `PendingPhotoStore` as it is written, so it survives
    /// the app dying — this map is the working copy, not the record.
    private var pendingPhotos: [Int: PendingPhotoStore.Entry] = [:]

    /// Staging encodes, which takes a moment, and leaving the tab must not
    /// outrun it. `flushPhotos` awaits these before deciding it has nothing to
    /// do — otherwise a picture chosen and immediately walked away from would
    /// be missed by the very flush that its own departure fired.
    private var stagingTasks: [Task<Void, Never>] = []

    /// Two triggers can arrive together — leaving the tab and backgrounding are
    /// one gesture apart — and both would otherwise take the same entries.
    private var isFlushingPhotos = false

    /// Keeps the app running long enough to finish, when the flush is the last
    /// thing it does. See `beginPhotoBackgroundTask`.
    private var photoBackgroundTask: UIBackgroundTaskIdentifier = .invalid

    /// A photograph added or removed on the dashboard. Recorded, not sent.
    ///
    /// **Onboarding has a Continue button and this page does not**, which is why
    /// the two surfaces differ at all. `RootView` uploaded on Continue and that
    /// was the app's only call site, so for a while the dashboard's grid edited
    /// an array that led nowhere. Saving on every edit fixed that and overshot:
    /// somebody rearranging six pictures paid an upload for each intermediate
    /// state. The save belongs at the moment they are finished, which is
    /// `flushPhotos`.
    func stagePhoto(_ media: PickedMedia?, at position: Int) {
        let task = Task { @MainActor in
            guard let media else {
                pendingPhotos[position] = .remove
                PendingPhotoStore.stage(nil, at: position)
                return
            }
            // Encoded here rather than at send time, so what lands on disk is
            // exactly what will be uploaded — a retry after a crash sends the
            // same bytes rather than re-deriving them from an image that is
            // gone.
            guard let data = await PhotoService.shared.encoded(media) else {
                saveError = "Couldn't prepare that photo."
                return
            }
            pendingPhotos[position] = .upload(data)
            PendingPhotoStore.stage(data, at: position)
        }
        stagingTasks.append(task)
    }

    /// Whether a slot is waiting to be saved — read by the hydration pass, which
    /// must not refill a photograph somebody has just removed.
    func hasPendingPhoto(at position: Int) -> Bool {
        pendingPhotos[position] != nil
    }

    /// Work left over from a previous launch, put back in the queue.
    ///
    /// Returns the pictures among it, so the grid can draw what the user last
    /// intended rather than what the server last accepted. Without this a photo
    /// added offline and then force-quit would come back missing, be silently
    /// re-uploaded by the retry, and reappear a moment later — which reads as
    /// the app losing it and then finding it.
    func restorePendingPhotos() -> [Int: Data] {
        var images: [Int: Data] = [:]
        for (position, entry) in PendingPhotoStore.load() {
            // Anything staged this launch is newer than anything on disk.
            guard pendingPhotos[position] == nil else { continue }
            pendingPhotos[position] = entry
            if case .upload(let data) = entry { images[position] = data }
        }
        return images
    }

    /// Sends what was staged. Called on leaving Memories, on the app going away,
    /// and before signing out.
    ///
    /// **Driven by staged edits, never by the array's contents.** A grid that has
    /// not hydrated yet is six empty slots, and anything that reconciled the
    /// array against the server would read that as "delete everything". Nothing
    /// here infers intent from what the grid holds.
    ///
    /// A failed entry goes back into the queue rather than being dropped, so the
    /// next departure retries it — but the reason is shown now, because a save
    /// that will be attempted again is still a save that has not happened.
    func flushPhotos(announcing: Bool = true) async {
        // Before the emptiness check, not after: a picture picked a moment ago
        // may still be encoding, and this is the flush its departure fired.
        let staging = stagingTasks
        stagingTasks = []
        for task in staging { await task.value }

        guard !isFlushingPhotos, !pendingPhotos.isEmpty else { return }
        isFlushingPhotos = true
        beginPhotoBackgroundTask()
        defer {
            isFlushingPhotos = false
            endPhotoBackgroundTask()
        }

        let work = pendingPhotos
        pendingPhotos = [:]

        var firstFailure: String?
        var landed = false

        // Sorted so the order is the order of the grid rather than the
        // dictionary's, which makes a failure mid-run comprehensible.
        for position in work.keys.sorted() {
            guard let entry = work[position] else { continue }
            let reason: String?
            switch entry {
            case .upload(let data):
                reason = await PhotoService.shared.upload(data, at: position)
            case .remove:
                reason = await PhotoService.shared.remove(position: position)
            }

            if let reason {
                firstFailure = firstFailure ?? reason
                // Back in the queue — unless the user has since changed this
                // slot again, in which case their newer intent is the one that
                // should survive, and its file has already replaced this one's.
                if pendingPhotos[position] == nil { pendingPhotos[position] = entry }
            } else {
                landed = true
                PendingPhotoStore.clear(position: position)
            }
        }

        // **Silent when nobody asked.** The retry on launch is not a thing the
        // user just did, and opening the app to a complaint about a photograph
        // chosen yesterday explains nothing they can act on. It still retries;
        // it just doesn't announce. A departure they performed does.
        if let firstFailure {
            if announcing { saveError = "Couldn't save that photo — \(firstFailure)" }
        } else {
            saveError = nil
        }
        // Once per flush, not once per photograph: the card carries all the
        // paths, so republishing per file is six writes to say one thing.
        if landed { publishDiscoveryCard() }
    }

    /// Time to finish after the app leaves the foreground.
    ///
    /// **Taken here rather than around the call**, which is where it was and
    /// where it protected nothing: a flush already running from the tab change
    /// turned the backgrounding call away at the re-entrancy guard, so the
    /// assertion was taken and released around a function that returned
    /// immediately while the real work went unprotected. Around the work, every
    /// trigger's flush is covered and a re-entrant call adds nothing.
    ///
    /// An unclaimed background gives a few seconds; this gives closer to thirty,
    /// which is the difference between an upload finishing and being cut off.
    /// The expiration handler is not optional — a task that runs out with no
    /// handler takes the app down with it. Ending it there leaves whatever is
    /// still queued for the next departure, which is what the retry is for.
    private func beginPhotoBackgroundTask() {
        guard photoBackgroundTask == .invalid else { return }
        photoBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "photos") {
            Task { @MainActor [weak self] in self?.endPhotoBackgroundTask() }
        }
    }

    private func endPhotoBackgroundTask() {
        guard photoBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(photoBackgroundTask)
        photoBackgroundTask = .invalid
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

        // The server first, and the local copy only if it took. Postgres is the
        // record; a device that showed an age the server never received would be
        // telling the user something untrue, and it would survive right up until
        // the next restore quietly replaced it.
        //
        // The `Bool` this returns is still only about the date being a real
        // date, so an impossible one keeps the sheet open exactly as before. A
        // rejected *write* is not the sheet's problem: it closes, and the row
        // keeps the value the server still holds.
        //
        // Exact, because they typed it — this is the one path that knows the day
        // as well as the year, and `birth_date` wins over `birth_year` on read.
        Task {
            guard await accepted(
                SyncService.shared.pushUserObject(birthDate: birthday, birthYear: year)
            ) else { return }
            let record = DistilledRecord(
                source: "user", dataType: "age", itemID: "age",
                name: "\(age)", creator: "", detail: "",
                extra: "birth_year=\(year);entered_by_user=1", collectedAt: Date()
            )
            replaceRecords(from: "user", with: userRecords(replacing: "age", with: record))
        }
        return true
    }

    /// A gender the user chose, which stands ahead of Health's biological sex.
    /// The two are not the same question, and only one of them was asked here.
    func setGender(_ label: String) {
        Task {
            guard await accepted(SyncService.shared.pushUserObject(sex: label)) else { return }
            let record = DistilledRecord(
                source: "user", dataType: "gender", itemID: "gender",
                name: label, creator: "", detail: "", extra: "entered_by_user=1", collectedAt: Date()
            )
            replaceRecords(from: "user", with: userRecords(replacing: "gender", with: record))
        }
    }

    /// The two onboarding sliders, written as one pass.
    ///
    /// One `replaceRecords` rather than two `setUserFact` calls: that would sync
    /// the `user` source twice for a single act, and the second run would send
    /// the first's row up again for the change-only trigger to discard. Same
    /// result, twice the round trips.
    ///
    /// Local-first and instant, like `setEducation` and for the same reason —
    /// neither owns a column on `public.users`, so there is no server value for
    /// a local one to contradict. That matters more here than there: this is
    /// collected during onboarding, and onboarding must not depend on a network.
    func setCommunicationStyle(_ style: CommunicationStyle) {
        let flirt = DistilledRecord(
            source: "user", dataType: "flirt_level", itemID: "flirt_level",
            name: style.flirt.rawValue, creator: "", detail: "",
            // The position rides in `extra`, which is where platform-specific
            // context belongs rather than widening the schema. It restores the
            // slider; the band is the answer.
            extra: "position=\(String(format: "%.3f", style.flirtPosition));entered_by_user=1",
            collectedAt: Date()
        )
        let response = DistilledRecord(
            source: "user", dataType: "response_time", itemID: "response_time",
            name: style.response.rawValue, creator: "", detail: "",
            extra: "position=\(String(format: "%.3f", style.responsePosition));entered_by_user=1",
            collectedAt: Date()
        )
        let untouched = records.filter {
            $0.source == "user" && !["flirt_level", "response_time"].contains($0.dataType)
        }
        replaceRecords(from: "user", with: untouched + [flirt, response])
    }

    /// Copies what onboarding collected into the record system, once.
    ///
    /// The sliders are answered before `AppShell` exists, so they land in
    /// `CommunicationStyleStore` with no view model to put them in. This is the
    /// hand-off, and it runs on every launch because it is also the repair: a
    /// sync that failed, or a reinstall whose restore has not yet landed, leaves
    /// the store holding an answer the records don't have.
    ///
    /// Guarded on the records already agreeing, so a launch that has nothing to
    /// do writes nothing — otherwise every launch would push two rows for the
    /// change-only trigger to throw away.
    func adoptStoredCommunicationStyle() {
        guard let stored = CommunicationStyleStore.saved else { return }
        guard identity.flirtLevel != stored.flirt || identity.responseTime != stored.response
        else { return }
        setCommunicationStyle(stored)
    }

    /// Every school somebody has attended, as they wrote it.
    func setEducation(_ text: String) { setUserFact("education", text) }

    /// What they do now — "Student" included, which is why the sheet says so.
    func setOccupation(_ text: String) { setUserFact("occupation", text) }

    /// The shared half of the two rows above.
    ///
    /// **No `pushUserObject` here, unlike `setGender` and `setPlace`.** Those
    /// mirror a column on `public.users` and so have to wait for the server to
    /// accept before showing anything. These two have no column: they travel as
    /// ordinary `user` records, which `replaceRecords` already syncs through
    /// `append_source_records` — so they need no migration, and the change-only
    /// trigger means retyping the same answer writes nothing.
    ///
    /// The consequence is that they apply locally first and reconcile after,
    /// which is the opposite trade from the biographics that own a column. It is
    /// the right one here: there is no column for a stale value to contradict.
    private func setUserFact(_ dataType: String, _ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let record = DistilledRecord(
            source: "user", dataType: dataType, itemID: dataType,
            name: trimmed, creator: "", detail: "", extra: "entered_by_user=1",
            collectedAt: Date()
        )
        replaceRecords(from: "user", with: userRecords(replacing: dataType, with: record))
    }

    /// Something the distillation missed, typed in by the person themselves.
    ///
    /// **Added rather than replaced**, unlike `setUserFact` above: education and
    /// occupation are single answers that a second one corrects, and a favourite
    /// is a list — somebody naming a second band has not changed their mind
    /// about the first. So the item id is the answer itself, which also makes
    /// naming the same thing twice a no-op rather than a duplicate.
    ///
    /// Travels as a `user` record for the same reason those two do: it owns no
    /// column, so it needs no migration, and the change-only trigger means
    /// re-entering an answer writes nothing.
    ///
    /// **Kept apart from the distilled rows it sits beside**, by `entered_by_user`
    /// — the ontology stage should be able to tell what somebody's phone
    /// observed from what they claimed about themselves, and those are different
    /// kinds of evidence.
    func addFavourite(kind: String, _ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let dataType = "favorite_\(kind)"
        let record = DistilledRecord(
            source: "user",
            dataType: dataType,
            itemID: "\(dataType):\(trimmed.lowercased())",
            name: trimmed,
            creator: "",
            detail: "",
            extra: "entered_by_user=1",
            collectedAt: Date()
        )
        var kept = records.filter { $0.source == "user" }
        kept.removeAll { $0.itemID == record.itemID }
        kept.append(record)
        replaceRecords(from: "user", with: kept)
    }

    /// What the user has named for a kind, most recent last.
    func favourites(kind: String) -> [String] {
        records
            .filter { $0.source == "user" && $0.dataType == "favorite_\(kind)" && !$0.isRemovedByUser }
            .map(\.name)
    }

    /// Where the phone is, for centring the map. `nil` when location is off.
    func currentCoordinate() async -> CLLocationCoordinate2D? {
        try? await location.currentCoordinate()
    }

    /// Somewhere the user picked on the map, rather than where the phone is.
    func setPlace(at coordinate: CLLocationCoordinate2D) async {
        guard let record = try? await location.place(at: coordinate) else {
            saveError = "Couldn't look that place up. Try again."
            return
        }
        guard await accepted(SyncService.shared.pushUserObject(place: record.name)) else { return }
        replaceRecords(from: "location", with: [record])
    }

    /// Records why a biographics write was refused, and answers whether it was.
    ///
    /// Written as a filter over the push's own result so the call sites keep
    /// reading as one line — `guard await accepted(...) else { return }` — and so
    /// there is exactly one place that decides what a failure says.
    private func accepted(_ didPush: Bool) async -> Bool {
        guard !didPush else {
            saveError = nil
            return true
        }
        // `lastError` is the transport or PostgREST message. It is absent when
        // the push never got as far as trying — no session, or nothing to send —
        // which from the outside is the same "it didn't save" and wants saying.
        let reason = await SyncService.shared.lastError
        saveError = reason.map { "Couldn't save that — \($0)" }
            ?? "Couldn't save that. Check your connection and try again."
        return false
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

    /// Strikes a podcast show off, and every episode of it with it.
    func banShow(_ show: ListeningHighlights.Show) {
        // Both, exactly as channels do: the show row carries an id and the
        // episodes only ever carry the name.
        bans.add(.show, show.name)
        if !show.showID.isEmpty { bans.add(.show, show.showID) }
        bans.save()
        syncBans()
        records = records.map(applyingBans)
        recomputeDerived()
        RecordStore.save(records)
    }

    /// Strikes a calendar event off by its title.
    ///
    /// **Nothing calls this today, and it is kept deliberately.** It was written
    /// when the dashboard listed event titles; that card now shows only the
    /// shape — how much was arranged, how much booked ahead, evenings, weekends
    /// — so there is no row to long-press and nothing to strike.
    ///
    /// It stays because the *ban* still works: `applyingBans` honours
    /// `BanList.Kind.event`, the list is synced and restored, and a ban set on
    /// another device or in an earlier build still hides those rows here. Losing
    /// this method would leave that kind unreachable while its effects remained,
    /// which is worse than an uncalled function. If titles ever come back to a
    /// screen, the strike-off is already built.
    ///
    /// By title rather than id, so a recurring appointment stays gone when next
    /// week's occurrence arrives with a new id — see `BanList.Kind.event`.
    func banEvent(_ event: ListeningHighlights.Event) {
        bans.add(.event, event.name)
        bans.save()
        syncBans()
        records = records.map(applyingBans)
        recomputeDerived()
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

    /// Blocks a person: they leave Explore and the chat list, for good.
    ///
    /// **Nothing touches the records**, unlike the other three. Those strike
    /// content out of your own distillation, so each has to re-map the rows and
    /// re-save the snapshot; this one hides somebody else, which no record of
    /// yours mentions. The ban list is the whole of the state.
    ///
    /// **One-sided, and that is a gap rather than a simplification.** Their side
    /// is untouched, so somebody you reported can still write into a thread you
    /// can no longer see. Making it mutual needs a policy that lets one account
    /// affect another's reads, which this schema does not have anywhere — see
    /// the Discovery section of CLAUDE.md for why that bar is set where it is.
    func banPerson(_ personID: String) {
        bans.add(.person, personID)
        bans.save()
        syncBans()
    }

    func hasBanned(_ personID: String) -> Bool { bans.contains(.person, personID) }

    /// Marks a record removed if it belongs to something banned. Rows are kept
    /// and annotated rather than deleted — see `DistilledRecord.markedRemoved`.
    private func applyingBans(_ record: DistilledRecord) -> DistilledRecord {
        guard !bans.isEmpty, !record.isRemovedByUser else { return record }

        if Modality.music.recordSources.contains(record.source) {
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

        // A show and every episode of it. The show row carries the name, an
        // episode row carries it in `creator` — so one strike takes the whole
        // programme rather than leaving its episodes behind under a heading that
        // no longer exists.
        if record.source == "apple_podcasts" {
            let keys = [record.name, record.creator, record.itemID]
            for key in keys where !key.isEmpty && bans.contains(.show, key) {
                return record.markedRemoved(reason: "banned_show")
            }
        }

        // By title, so a recurring appointment stays struck off when next week's
        // occurrence arrives with a new id — see `BanList.Kind.event`.
        if record.dataType == "event", bans.contains(.event, record.name) {
            return record.markedRemoved(reason: "banned_event")
        }

        return record
    }

    /// Everything read off the records, in one pass, whenever they change.
    ///
    /// Re-distilling the same source with the same library produces an equal
    /// `TreeState`, so the tree won't re-animate for no reason.
    private func recomputeDerived() {
        // Before the branches, because the loop below asks `connectedSources`
        // what is connected and this is half of its answer. It sat at the foot
        // of this method while nothing here read it.
        returnedSources = Set(records.map(\.source))

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
        // **A connected source grows its branch whether or not it left rows.**
        // `TreeMetrics` measures records and answers `nil` for none, which is
        // right as a measurement and wrong as an answer to "has this been
        // connected" — the two questions had been one, and a legitimately empty
        // YouTube was therefore indistinguishable from an untouched one. Every
        // consumer reads `branches`: `nextModality` kept offering the same
        // modality, no `ConnectedBar` appeared, the badge ring stayed empty and
        // the plant stayed at stage zero.
        //
        // Zero volume rather than a fabricated size, so the branch is short and
        // sparse — which is the honest picture. `TreeSkeleton` handles it: the
        // log scale takes volume 0 to a minimum-length limb at two levels
        // rather than to nothing.
        //
        // Lifestyle is set above and may be `nil` while Health is connected —
        // it goes through this too, which is the same answer its own cache
        // gives and one fewer special case.
        for modality in Modality.allCases where state.branches[modality] == nil {
            guard !connectedSources(for: modality).isEmpty else { continue }
            // **`ModalityMetrics.none` spelled out, never `.none`.** The
            // subscript's type is `ModalityMetrics?`, so a leading-dot `.none`
            // resolves to `Optional.none` — it compiles, assigns nil, and does
            // exactly nothing. Written that way first, and the branch still
            // refused to grow with the connection sitting in the store.
            state.branches[modality] = ModalityMetrics.none
        }
        treeState = state
        skeleton = TreeSkeleton.make(from: treeState, seed: Self.treeSeed)
        // **Sixty, not six.** The cards ranked six and stopped, which was right
        // while the list ran down the page — it is now a bounded scroller, so
        // the ceiling is about what is worth ranking rather than what fits.
        // Sixty is deep enough that somebody can find a band they half remember
        // and shallow enough that the tail of one-play artists stays out.
        musicArtists = MusicHighlights.topArtists(in: records, limit: Self.rankedEntries)
        musicGenres = MusicHighlights.genreShare(in: records)
        mediaChannels = MediaHighlights.topChannels(in: records, limit: Self.rankedEntries)
        podcastShows = ListeningHighlights.shows(in: records)
        events = ListeningHighlights.events(in: records)
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

        if source == "apple_calendar" {
            // Two booked and two typed, because telling those apart is the whole
            // point of the source: `booked=1` is set from a `url`, which
            // ticketing sites write back and a person typing an entry does not.
            let events: [(String, String, Bool, Int)] = [
                ("Laufey — The Bewitched Tour", "The Pageant", true, 7),
                ("St. Louis CITY SC vs Austin FC", "Energizer Park", true, 1),
                ("Climbing with Sam", "Upper Limits", false, 3),
                ("Book club", "", false, 4)
            ]
            return events.enumerated().map { index, event in
                let (title, place, booked, weekday) = event
                var extra = "calendar=Personal;weekday=\(weekday);weekend=\(weekday == 1 || weekday == 7 ? 1 : 0);hour=19"
                if booked { extra += ";booked=1;url=https://example.com/tickets/\(index)" }
                return DistilledRecord(
                    source: "apple_calendar", dataType: "event", itemID: "preview_event_\(index)",
                    name: title, creator: "", detail: place, extra: extra, collectedAt: now
                )
            }
        }

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
