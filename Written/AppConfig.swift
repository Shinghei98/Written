import Foundation

/// Central configuration for Written's distillation sources.
enum AppConfig {

    // MARK: Spotify OAuth

    /// **Restored for the beta only.** Spotify was dropped when Postgres became
    /// the source of truth, and the reason has not gone away — see the note in
    /// CLAUDE.md. It is back so the data-collection beta has a second music
    /// source, and it comes out before the App Store build.
    ///
    /// Client ID from the Spotify Developer Dashboard
    /// (https://developer.spotify.com/dashboard → Create app).
    /// Add the exact redirect URI below to the app's Redirect URIs there,
    /// and enable the "iOS" platform with this app's bundle identifier.
    static let spotifyClientID = "3a0ed3c9d39c40c3bdc3c62b91f78e8b"

    static let spotifyRedirectScheme = "written"
    static let spotifyRedirectURI = "written://spotify-callback"

    /// Read-only scopes covering written_api.xlsx: top artists/tracks,
    /// recently played, followed artists, playlists.
    /// **`user-library-read` is the person's own saved library**, and its
    /// absence was the largest structural difference between the two music
    /// sources. Measured 2026-08-14: Apple Music's `library_song` is 641 rows
    /// and every one states a genre; the Spotify counterpart — `/v1/me/tracks`
    /// — had never been asked for, so what was being compared was Apple's
    /// *library* against Spotify's *top charts*. `/v1/me/albums` comes with the
    /// same scope and is `library_album`'s counterpart.
    ///
    /// **The cost is one reconnection each, and it is worth saying out loud.**
    /// A token already granted carries the scopes it was granted; widening the
    /// list does not widen an existing token. Everyone who has connected
    /// Spotify has to do it again, or the two new endpoints answer 403 and the
    /// source looks smaller than it is for no visible reason.
    ///
    /// Still one button and no extra tap — one more line on the same consent
    /// screen — but it is a permission, and the extraction rule does not
    /// license asking for those on its own. Decided deliberately (owner,
    /// 2026-08-14) for the data-collection prototype.
    static let spotifyScope = "user-top-read user-read-recently-played user-follow-read playlist-read-private user-library-read"

    // MARK: Supabase

    /// The project's REST and auth host.
    static let supabaseURL = URL(string: "https://fwnezkbesjoazlpaflbq.supabase.co")!

    /// The **anon** key, committed on purpose and by the same reasoning as the
    /// OAuth client IDs below: it is designed to ship inside clients, identifies
    /// the project rather than a person, and grants nothing on its own.
    ///
    /// What actually protects the data is **row-level security** — every table
    /// carries `auth.uid() = user_id`, so this key can only ever reach rows the
    /// signed-in user owns. That makes RLS load-bearing rather than defence in
    /// depth: a table with it switched off is readable in full by anyone holding
    /// this string. See `supabase/migrations/0001_initial.sql`.
    ///
    /// The `service_role` key bypasses all of that and must never appear here.
    /// The publishable key, which replaced the JWT `anon` key when the legacy
    /// keys were disabled on 2026-07-29.
    ///
    /// Committed on purpose, exactly as its predecessor was: it ships in the
    /// binary and row-level security is what protects the data. Its opposite
    /// number, `sb_secret_…`, must never appear here or anywhere else in this
    /// repo — the old `service_role` key had to be retired precisely because it
    /// was pasted into a working session.
    static let supabaseAnonKey = "sb_publishable_rKIU-q6beAiLawLkjEiMYA_vZNmC2aT"

    // MARK: Google / YouTube OAuth

    /// iOS OAuth client ID from Google Cloud Console
    /// (APIs & Services → Credentials → Create Credentials → OAuth client ID → iOS).
    /// Enable "YouTube Data API v3" for the project before creating the client.
    ///
    /// Replace the placeholder with your real client ID, e.g.
    /// "1234567890-abc123def456.apps.googleusercontent.com"
    static let googleClientID = "672788849005-kd5dkg6om726kf19gml7gn6qkikg13t4.apps.googleusercontent.com"

    /// Google iOS clients redirect to the reversed client ID as a custom URL scheme.
    /// "1234-abc.apps.googleusercontent.com" → "com.googleusercontent.apps.1234-abc"
    static var googleRedirectScheme: String {
        let parts = googleClientID.components(separatedBy: ".")
        return parts.reversed().joined(separator: ".")
    }

    static var googleRedirectURI: String {
        "\(googleRedirectScheme):/oauthredirect"
    }

    /// Read-only YouTube scope: subscriptions, liked videos, playlists.
    static let youtubeScope = "https://www.googleapis.com/auth/youtube.readonly"

    /// **Two narrow scopes rather than `calendar.readonly`, and that is the
    /// answer to a question the reviewer will ask.** Google's sensitive-scope
    /// verification requires a justification for each scope *and* an explanation
    /// of why a narrower one will not do — so asking for the two that name
    /// exactly what is read is worth more than the convenience of one broad one.
    ///
    /// The distiller needs the calendar list, to exclude generated and holiday
    /// calendars by name before reading anything, and the events themselves.
    /// Neither is restricted, so this stays a sensitive-scope review and no CASA
    /// assessment is triggered — unlike `fitness.*`, which is why Google health
    /// data was never a possibility here even before its API closed.
    static let googleCalendarScope = [
        "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
        "https://www.googleapis.com/auth/calendar.events.readonly",
    ].joined(separator: " ")

    // MARK: Microsoft (Outlook Calendar)

    /// The Entra application (client) id. **Paste it here after registering.**
    ///
    /// A public client, so there is no secret and none belongs in this binary —
    /// the same posture as the Google client ids above, and the reason
    /// `OAuthPKCEService` exists rather than an SDK. Microsoft's own guidance
    /// treats a mobile app as a public client that cannot hold a secret.
    /// Registered 2026-08-13 in a directory created for Written, under an
    /// account Written controls. **Not WashU's** — an application object cannot
    /// be moved between tenants, so registering in a university directory would
    /// have made their admins the permanent home of this integration.
    ///
    /// Audience is *any Entra tenant + personal Microsoft accounts*, which is
    /// what makes the `common` authority in `OAuthProvider.outlookCalendar`
    /// resolve for an Outlook.com account and a Microsoft 365 tenant alike.
    /// Committed deliberately, like the Google client ids above: an iOS OAuth
    /// client id is not a secret, and PKCE is what secures the flow.
    static let microsoftClientID = "05d95265-58c4-49ea-80a3-e144498c0153"

    /// Whether the Entra registration has actually been done.
    ///
    /// **Without it the Outlook row is not drawn at all**, through
    /// `SourceAvailability` — not disabled, absent. A placeholder client id
    /// does not fail at sign-in, which would at least be legible; it opens a
    /// Microsoft page reading *"Application with identifier
    /// 'YOUR_MICROSOFT_CLIENT_ID' was not found in the directory"*, which reads
    /// as the app being broken. This codebase's own rule: a button that does
    /// nothing is worse than an absent one.
    static var isMicrosoftConfigured: Bool {
        !microsoftClientID.hasPrefix("YOUR_")
    }

    /// MSAL's convention, kept even though this app does not use MSAL, because
    /// it is what the Entra portal generates when you add the iOS platform and
    /// enter the bundle id. Deviating would mean hand-editing the redirect in
    /// the portal for no gain.
    static var microsoftRedirectScheme: String { "msauth.com.written.datingapp" }

    static var microsoftRedirectURI: String { "\(microsoftRedirectScheme)://auth" }

    /// **`Calendars.Read`, and the narrower permission was not an option.**
    ///
    /// `Calendars.ReadBasic` is Microsoft's least-privileged calendar
    /// permission and excludes event bodies, attachments and extensions *by
    /// definition* — which is what this app wants and what it asked for first.
    /// **It is not available to personal Microsoft accounts.** Microsoft's
    /// permissions reference lists personal-account support for
    /// `Calendars.Read` and `Calendars.ReadWrite` and not for `.ReadBasic`,
    /// and the failure mode is silent: the consent screen is approved, a valid
    /// token is issued carrying no calendar permission, and Graph answers the
    /// first call **401 with no body and no `WWW-Authenticate` header**.
    /// Nothing in that sequence names a scope, which is why it survived four
    /// wrong diagnoses on 2026-08-13.
    ///
    /// **So the grant is now wider than what is read, and the restraint moved
    /// from the permission into our code.** `OutlookCalendarDistiller` asks for
    /// `$select=id,iCalUId,subject,start,end,isAllDay,isCancelled,sensitivity,
    /// categories,showAs,type,seriesMasterId` and never requests `body`,
    /// `bodyPreview`, `attendees`, `attachments`, `onlineMeeting` or `webLink`
    /// — so no event body ever reaches the device. That is a promise the
    /// `$select` keeps rather than one the scope enforces, which is a weaker
    /// guarantee and is recorded here as such.
    ///
    /// Still not `.ReadWrite`: this app has no reason to change somebody's
    /// diary, and that one is a real escalation rather than a forced one.
    ///
    /// `offline_access` yields the refresh token, so a later distillation costs
    /// no taps; `openid profile` let the token endpoint answer for `common`.
    static let outlookCalendarScope = [
        "openid",
        "profile",
        "offline_access",
        "Calendars.Read",
    ].joined(separator: " ")

    /// Graph's stable version. `beta` is explicitly not for production use.
    static let microsoftGraphBase = "https://graph.microsoft.com/v1.0"

    // MARK: The private semantic vault (v0.3.1, Phase 1)

    /// **Which sources dual-write to the vault. Apple Music, and nothing else.**
    ///
    /// Phase 1 of the v0.3.1 integration writes each distillation twice: the
    /// legacy path through `SyncService`, which the product depends on, and the
    /// typed envelope through `SemanticIngestionService`, which nothing reads
    /// yet. A source absent from this set does nothing at all — no queue, no
    /// request, no cost.
    ///
    /// **A set rather than a switch, because turning it on everywhere at once
    /// throws away the only thing shadow running is for.** Apple Music is the
    /// right first source: it is the largest real library (~2,540 rows, six
    /// batches), it exercises batching and the retry queue properly, and its
    /// legacy row count is a number to compare the receipt against. A source
    /// whose rows disagree between the two paths is exactly what this phase
    /// exists to find, and finding it in one source is a diagnosis while
    /// finding it in nine is a shrug.
    ///
    /// Note `music_library` is deliberately *not* here even though it emits the
    /// same `library_song` rows: on a subscriber's phone both sources return
    /// the same library, and the comparison wants one of them, not the
    /// doubling that cost `MusicHighlights.deduplicatedSongs` a rewrite.
    ///
    /// The endpoint itself is proven — a real device envelope round-tripped on
    /// 2026-08-11, and a second identical one stored nothing.
    /// **HealthKit is absent and cannot simply be added.**
    /// `guard_raw_healthkit_grant` refuses an active HealthKit row unless
    /// `semantic_private.healthkit_use_grants` holds an active grant for that
    /// person, and there are none — the schema is fail-closed on purpose. With
    /// the source enabled today every HealthKit batch would be refused, and
    /// `SemanticIngestionService` drops a permanent refusal, so the data would
    /// disappear quietly. A grant is a recorded consent decision with its own
    /// `consent_version`; writing one without asking anybody would be
    /// fabricating consent, which is the exact thing that guard prevents.
    static let semanticIngestionSources: Set<String> = [
        "apple_music",
        // **Spotify, for the training build only, and this is the line to
        // delete before launch.** IV.2.1.a forbids "using the Spotify Platform
        // or any Spotify Content to train a machine learning or AI model or
        // otherwise ingesting Spotify Content into" one — no carve-out, and
        // IV.2.5 closes the consent route explicitly, covering derived and
        // aggregate data "even if a user consents to such transfer or use". So
        // this is not a judgement that could go either way at launch; it is the
        // clause naming the thing being done here.
        //
        // Enabled because the training corpus comes from collaborators rather
        // than users, and because withholding it made the second real account
        // unreadable: measured 2026-08-13, she has no Apple Music, 593 Spotify
        // rows, and produced zero assertions because her only music source
        // never reached the vault — her whole vault was 50 YouTube observations
        // against another account's 575.
        //
        // **Removing it is one line here and nothing else.** The action map in
        // `SemanticSource`, the weights in `semantic_private.sources` and the
        // `music` independence group all predate this and stay correct either
        // way. What does *not* follow automatically is deleting what was
        // captured — that is `SyncService.deleteSource(_:)` and the vault's own
        // erasure, and it has to be done deliberately.
        "spotify",
        // **The two sources the encrypted vault exists for.** Their payloads
        // are whole calendar events — titles, locations, organisers — which is
        // why they are encrypted at rest and why `consent_purpose` derives to
        // `calendar_distillation` rather than the general one.
        //
        // They contribute **zero evidence**: the endpoint sends no
        // `normalized_payload` for them, because
        // `private_observation_projection_is_valid_v03` demands a sanitised
        // shape that is a classifier's output rather than a transcription, and
        // §7 permits only the current Calendar classifier over Calendar rows.
        // Captured broadly, promoted not at all — which is §10's Calendar gate
        // rather than a limitation.
        "apple_calendar",
        "google_calendar",
        // **Added once it had earned it, and once `0133` made it safe.**
        // Measured 2026-08-13 against a real account: Graph returned 44 events
        // where EventKit's copy of the same Exchange calendar had 16, and only
        // 13 overlapped — iOS syncs a limited window, so the device copy
        // stopped at 2023 while Graph reached to 2027. So this is coverage the
        // legacy path does not have rather than a second route to the same
        // rows, which is what the entry above assumed for a day.
        //
        // Safe only because `0133` replaced the literal calendar lists in five
        // `semantic_private` functions with `is_private_calendar_source` and
        // `is_private_lane_source`. Four of those are prohibitions, so before
        // that migration an `outlook_calendar` observation would have been
        // *permitted* into the generic mention lane and onto public surfaces
        // rather than merely unhandled.
        //
        // **Its rows will duplicate the Exchange events EventKit already
        // promotes** for anyone who has both, which the vault does not dedupe —
        // the same open gap Google Calendar has, where four flights were
        // promoted twice.
        "outlook_calendar",
        // **Only safe because `FitnessPurposePrimer` runs first.**
        // `guard_raw_healthkit_grant` refuses an active HealthKit row without a
        // recorded `fitness_connection` grant, and a refusal is permanent to
        // `SemanticIngestionService`, which drops it — so an ungranted account
        // would lose its rows quietly. `dualWriteToVault` therefore checks the
        // grant before building anything, and declining costs nothing: Health
        // still connects and distils, and only the encrypted copy is withheld.
        "health",

        // The rest, and none of them needs anything HealthKit needed: no
        // source-specific guard on `raw_source_records` exists except
        // HealthKit's, every connector/record pair is an identity row already
        // in the matrix, and every data type is mapped.
        "apple_podcasts",
        "music_library",
        "location",

        // **`user` produces no scopes at all**, because every one of its data
        // types is `notAnAction` — a bio, an occupation, a flirt level are
        // stated rather than observed. So a `user` run captures its rows and
        // finalizes nothing, which is exactly the shape `0056` exists for: a
        // run with nothing promotable keeps what it caught rather than rolling
        // it back.
        "user",

        // **YouTube, and it is the second independence group.**
        // `apple_music`, `music_library` and `spotify` all carry the group
        // `music` by design — three streaming services agreeing that somebody
        // played a song is one witness, not three — so no music source can ever
        // be the second, and `motif_rules` requires two as a check constraint.
        // Nothing in this system has ever had two.
        //
        // **What travels is labels, never text.** The endpoint projects
        // `topics`, `tags`, `category_id`, `channel_id` and `subscriber_count`
        // and copies no title, channel name or description;
        // `private_observation_projection_is_valid_v03` refuses the row if it
        // tries. The encrypted raw record keeps the whole payload and expires
        // at thirty days through `sweep_youtube_vault_retention` — which had to
        // exist before this line could be written, because
        // `guard_observation_immutable` freezes a projection and a title
        // landing there could never be removed.
        //
        // Its two mapping kinds are permitted differently: `provider_topic`
        // needs no approval, and `uploader_tag` is licensed by `0078`'s
        // recorded determination. `written_title_tag` — inferring a category
        // from a title — stays shut.
        "youtube",

        // **Spotify is deliberately absent, and is not in YouTube's position.**
        // Its Developer Terms IV.2.1.a forbid "ingesting Spotify Content into a
        // machine learning or AI model", and IV.2.5 closes the consent route in
        // its own words — even if a user consents. There is no narrow permitted
        // path to find: the clause names the use and offers no carve-out, where
        // YouTube's III.E.4.h prohibits *inferring* a category and leaves
        // reading one alone. It is still offered as a *source* for the
        // collection prototype; what it may not do is feed the semantic system.
    ]

    /// Whether the vault path does anything at all this build.
    static var semanticIngestionEnabled: Bool { !semanticIngestionSources.isEmpty }

    /// Whether this build asks the server for semantic surfaces at all.
    ///
    /// **The build half of a pair, and the pair is deliberate.** This ships with
    /// the binary and decides whether the app *asks*; the server's
    /// `memories_reads` flag decides whether it *answers*, and is §9's rollback
    /// contract — throwable without an App Store release, which is the whole
    /// reason it exists. Either being off leaves the legacy Memories page
    /// drawing exactly as it does today.
    ///
    /// **The `api` schema is exposed as of 2026-08-12**, confirmed by request
    /// rather than by the dashboard saying so: with `Content-Profile: api` the
    /// RPCs resolve, and without it PostgREST still searches `public` and
    /// answers `PGRST202`. So the profile header is load-bearing rather than
    /// belt-and-braces.
    ///
    /// `anon` is refused with *"permission denied for schema api"* and
    /// `authenticated` is not, which is the intended posture and also the
    /// reason `SemanticSurfaceService` cannot read `42501` as "switched off".
    static let semanticSurfacesEnabled = true

    /// `aws/ingestion` — API Gateway in front of the Lambda. Not a secret: it
    /// authenticates every request against the caller's Supabase access token,
    /// so knowing the address buys nothing, exactly as the OAuth client ids
    /// below are committed deliberately.
    static let semanticIngestionURL = URL(
        string: "https://c2u0avzqti.execute-api.us-east-1.amazonaws.com/v1/ingest"
    )

    /// Envelopes per request.
    ///
    /// **Must not exceed the endpoint's own ceiling**, which is 500: it refuses
    /// a larger batch outright rather than truncating it. One real Apple Music
    /// library is about 2,540 rows, so a full distillation is several requests
    /// — which is wanted anyway, since API Gateway caps a request at 10 MB.
    static let semanticIngestionBatchSize = 500

    // MARK: The raw archive

    /// Whether each source's own answer is kept beside what Written made of it.
    ///
    /// **The response was parsed and dropped, and that is what this turns on.**
    /// `DistilledRecord` is eight columns and a `key=value;key=value` string;
    /// a field the parse did not read is unrecoverable without asking somebody
    /// to open the app again, which the project's own rule calls a bug report
    /// about us. `RawArchive` keeps the body so a re-projection is a query.
    ///
    /// **A switch rather than a build flag**, because it governs what leaves
    /// the device and that has to be answerable in one place — the same reason
    /// `semanticSurfacesEnabled` and `memories_reads` are two switches and not
    /// one. Turning it off stops capture; it does not delete what is already
    /// staged, which `RawArchive.forget()` does.
    static let rawArchiveEnabled = true

    /// The ceiling one account's staged archive may reach before capture stops.
    ///
    /// **Measured rather than guessed is the goal; this is the guard until
    /// then.** A library of a few thousand rows is a handful of megabytes of
    /// gzipped JSON, but a pathological account is exactly the one nobody
    /// tests, and an archive that fills a phone is worse than no archive.
    /// Capture refuses past this and says so in `RawArchive.refusals`; it never
    /// deletes to make room, because choosing which of somebody's data to drop
    /// is not a decision a size limit should be making.
    static let rawArchiveMaxBytes = 256 * 1024 * 1024

    // MARK: Distillation limits (MVP guardrails so a distill finishes quickly)

    /// Maximum pages fetched per paginated endpoint (50 items/page for YouTube,
    /// 100 items/page for most Apple Music endpoints).
    static let maxPagesPerEndpoint = 10

    /// Maximum playlists whose individual tracks are expanded.
    static let maxPlaylistsExpanded = 15

    /// Maximum library songs checked for a like/dislike rating.
    ///
    /// The only term in a distillation that scaled with the size of someone's
    /// library: ratings are asked for a hundred ids at a time, so an unbounded
    /// library meant an unbounded number of round trips, and Apple Music took
    /// far longer to connect than YouTube or Health for no visible reason. The
    /// songs are read most-recent-first, and ratings are a weak signal next to
    /// heavy rotation and play counts, so the tail is worth little.
    static let maxSongsRated = 1_000

    /// Ceiling on songs read from the *device* library — see
    /// `MusicLibraryDistiller`, which is what covers people with no Apple Music
    /// subscription. Higher than `maxSongsRated` because this costs no round
    /// trips at all: it is a local query, not a thousand ids over the network.
    static let maxLibrarySongs = 3_000

    /// Ceiling on Spotify tracks looked up in Apple Music's catalog for a
    /// composer — see `ComposerService`.
    ///
    /// **The same hazard `maxSongsRated` describes, one service further out.**
    /// Spotify returns no composer, so a classical listener's whole library is
    /// eligible, and without a ceiling this would scale with the size of it.
    /// Two things already bound it before this does: the lookup is batched a
    /// hundred ISRCs to a request, and it only runs for people whose own artist
    /// rows say they listen to classical at all — which is nobody, for most
    /// libraries. So this is the backstop rather than the mechanism, and it is
    /// set where 500 tracks costs five requests.
    static let maxComposerLookups = 500

    // MARK: Apple Calendar

    /// How far back events are read. Five years.
    ///
    /// It was a year, matching the Health windows, on the reasoning that a year
    /// covers the seasonal shape of a life — a festival every August, a season
    /// ticket. True as far as it goes, and it was measured wrong in the other
    /// direction: the thing this source exists to catch is the trip somebody
    /// booked, and those are exactly the entries that sit outside a year.
    static let calendarLookbackDays = 1825

    /// And how far forward, now the same. It was 180 days on the argument that a
    /// booked gig sits weeks out and repeating entries scheduled years ahead say
    /// nothing about the next few months.
    ///
    /// **A flight to Los Angeles is what disproved it.** It was in the calendar,
    /// it was the strongest single row in the whole distillation — booked, paid
    /// for, a place and a date — and 180 days is precisely the window that
    /// excludes the holiday somebody planned in advance while including the
    /// dentist. A repeating entry is a solved problem: `record(for:)` marks it
    /// `recurring=1` and the fetch keeps one occurrence per identifier.
    static let calendarLookaheadDays = 1825

    /// Ceiling on events kept, so a shared work calendar with a decade of
    /// meetings can't turn one distillation into a hundred thousand rows.
    ///
    /// Doubled with the windows, which grew tenfold — but the number matters far
    /// less than **which** events survive it. See `CalendarDistiller.events`:
    /// the fetch is chunked by year and the chunks are walked outward from
    /// today, so a cap reached in a decade of meetings costs the furthest year
    /// rather than the next one.
    static let maxCalendarEvents = 6_000

    // MARK: Apple Health

    /// How far back HealthKit is read. A year covers seasonal habits — someone
    /// who only skis, someone who only swims in summer — without turning the
    /// distill into a decade-long export.
    static let healthWorkoutLookbackDays = 365

    /// How far back steps, active energy and exercise minutes are read.
    ///
    /// Far shorter than the workout window, and that gap is deliberate — it is
    /// the difference between a distill that takes seconds and one that looks
    /// hung. Workouts are sparse; quantity samples are not. An Apple Watch
    /// writes active energy every few minutes, so a year is hundreds of
    /// thousands of samples per type, and `HKStatisticsCollectionQuery` scans
    /// every one of them before it can bucket anything.
    ///
    /// Back to a year, deliberately. This was cut to thirty days while chasing a
    /// distillation that appeared to hang — wrongly, as it turned out: the hang
    /// was the authorization request never returning, and no query had run at
    /// all. The reach is worth having, so it is restored.
    ///
    /// It stays a separate constant rather than folding back into one window,
    /// because the underlying asymmetry is still true — workouts are sparse and
    /// quantity samples are dense — and this is the dial to turn first if a
    /// distillation ever *is* slow.
    static let healthActivityLookbackDays = 365

    /// Steps in an hour before it counts as "up and about". A three-step trip to
    /// the bathroom at 4am is not getting up, and without a floor it would be
    /// recorded as the day's wake time.
    static let wakeStepThreshold = 100

    /// Where one day ends and the next begins, for the purpose of "when did they
    /// get up". Not midnight: a night owl's 1am walk belongs to the evening
    /// before, and dated by the calendar it would make them the earliest riser
    /// on record.
    static let dayBoundaryHour = 3

    /// Ceiling on individual workouts kept. Beyond this the daily activity rows
    /// carry the shape of the habit anyway, and an athlete with thousands of
    /// sessions shouldn't make the distill crawl.
    static let maxWorkouts = 400

    /// Shows and episodes kept from Apple Podcasts.
    ///
    /// Generous on shows and tighter on episodes, because they answer different
    /// questions. The *show* is the taste and there are only ever so many of
    /// them; the *episodes* are instances of it, and past a point another fifty
    /// of the same podcast tell the ontology stage nothing it did not already
    /// have from the first ten. Same argument as `maxSongsRated`.
    static let maxPodcastShows = 200
    static let maxPodcastEpisodes = 500
}
