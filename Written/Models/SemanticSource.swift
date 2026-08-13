import Foundation

/// The vocabulary the semantic system speaks, and the seam between it and the
/// one this app has always spoken.
///
/// **Phase 1 of the v0.3.1 integration, and it ships no behaviour.** Nothing
/// reads these types yet. They exist so the typed envelope in
/// `SourceEnvelope.swift` has a vocabulary that is checked against the server's
/// rather than guessed at, and so that adding a `data_type` to a distiller is a
/// decision somebody makes rather than a row that quietly lands with no action.
///
/// **The authority is `semantic_private.sources`, not this file.** Every name
/// here is one the database already knows: `source_code` for the cases below,
/// and the keys of that row's `action_weights` for `SemanticAction`.
/// `semantic/tests/test_ios_envelope_contract.py` reads both out of the
/// migrations and fails if this file invents one — which is the only reason it
/// is safe to write the vocabulary down twice.

// MARK: - Sources

/// One row of `semantic_private.sources`.
///
/// Eleven, and the app emits ten of them. `podcast` is the odd one out: it is a
/// `written`-provider source for a show resolved from a shared link through the
/// iTunes Search API, which the share extension could produce and nothing does
/// today. It is here because the database has it, not because we write it.
enum SemanticSource: String, CaseIterable, Codable, Sendable {
    case appleMusic = "apple_music"
    case musicLibrary = "music_library"
    case spotify
    case applePodcasts = "apple_podcasts"
    case podcast
    case appleCalendar = "apple_calendar"
    case googleCalendar = "google_calendar"
    /// **Present so the vocabulary is complete, and not yet ingested.** Six
    /// functions in `semantic_private` name the other two calendars by literal
    /// — including `guard_private_source_generic_lane_v03`, which bars them and
    /// HealthKit from the generic mention and feedback lanes. Until those learn
    /// this source code, `outlook_calendar` must stay out of
    /// `AppConfig.semanticIngestionSources`: an Outlook observation would not be
    /// barred from the lane the other calendars are kept out of, which is a
    /// privacy regression rather than a missing feature.
    case outlookCalendar = "outlook_calendar"
    case healthKit = "healthkit"
    case youTube = "youtube"
    case location
    case user
}

extension SemanticSource {
    /// The string `DistilledRecord.source` carries for this source, which is
    /// the same word in every case but one.
    ///
    /// **`health` against `healthkit` is the whole of this function.** The app
    /// has written `source: "health"` since the distiller was added and the
    /// semantic schema was adapted with `healthkit`; neither is wrong and
    /// renaming either would rewrite history in a table that is append-only by
    /// design. So the two vocabularies are translated in one place, and this is
    /// it. A second translation anywhere else is a bug waiting for the day the
    /// two disagree.
    var appSourceCode: String {
        switch self {
        case .healthKit: return "health"
        default: return rawValue
        }
    }

    /// `nil` for a source string the semantic schema has never heard of, which
    /// is a refusal rather than a default: filing an unknown source under a
    /// known one is how an observation ends up attributed to the wrong service.
    static func forAppSource(_ appSourceCode: String) -> SemanticSource? {
        allCases.first { $0.appSourceCode == appSourceCode }
    }

    /// The `data_type` the semantic schema knows this row by.
    ///
    /// **`event` against `calendar_event`, and it is the same seam as
    /// `appSourceCode`.** `CalendarDistiller` has written `event` since it was
    /// added; the contract calls a calendar row `calendar_event` and says so in
    /// two places that must agree —
    /// `private_observation_projection_is_valid_v03` demands it of the
    /// observation, and `guard_ingestion_run_item_v031` demands that the raw
    /// record, the scope manifest and the observation all carry the *same*
    /// data type. So an observation cannot hold a vocabulary of its own; the
    /// whole row has to speak the schema's language, and renaming the
    /// distiller's would rewrite the legacy path for a name only the vault
    /// cares about.
    ///
    /// One translation, in one place, pinned by a test — for the reason
    /// `appSourceCode` gives.
    func semanticDataType(for appDataType: String) -> String {
        switch (self, appDataType) {
        case (.appleCalendar, "event"), (.googleCalendar, "event"),
             (.outlookCalendar, "event"):
            return "calendar_event"
        default:
            return appDataType
        }
    }
}

// MARK: - Actions

/// A key of `semantic_private.sources.action_weights` — what the person *did*,
/// as distinct from what the item *is*.
///
/// The server weighs these; a saved track is worth more than a library row and
/// a recommendation is worth nothing at all, because Apple chose it. Only the
/// members this app can actually produce are listed. The server's vocabulary is
/// wider, and staying a subset is checked rather than assumed.
enum SemanticAction: String, Codable, Sendable {
    case librarySong = "library_song"
    case libraryAlbum = "library_album"
    case libraryArtist = "library_artist"
    case libraryPlaylist = "library_playlist"
    case playlistItem = "playlist_item"
    case rating
    case recentlyAdded = "recently_added"
    case recentlyPlayed = "recently_played"
    case recommendation
    case followedArtist = "followed_artist"
    case followed
    case saved
    case booked
    /// **Not `entered_by_user`, which the schema knows but the Calendar
    /// projection refuses.** `private_observation_projection_is_valid_v03`
    /// allows a calendar observation only `scheduled` or `booked`, and
    /// `guard_ingestion_run_item_v031` requires the observation's action to
    /// equal its scope's — so `entered_by_user` can be captured and can never
    /// become evidence. The distinction it carried is kept: `booked` is still
    /// what a ticketing site wrote in, and `scheduled` is everything a person
    /// put there themselves.
    case scheduled
    case workout
    case activityDay = "activity_day"
    case activityHour = "activity_hour"
    case likedVideo = "liked_video"
    case subscription
    case playlist
    /// **Spotify's report of what somebody actually played most**, weighted by
    /// `0139` after a whole distillation proved what leaving them unweighted
    /// costs: 500 `top_track` and 60 `top_artist` observations at 0.0 against
    /// 20 `followed_artist` at 0.55, so every one of the nine mappings a
    /// 593-row library produced came from the twenty. An account whose only
    /// music source is Spotify could distil it all and assert nothing.
    ///
    /// `topTrack` carries an explicit `rank=N` in the projection, which is kept
    /// and not yet used — a rank-1 track and a rank-500 track weigh the same.
    case topTrack = "top_track"
    case topArtist = "top_artist"
}

/// Why a row carries no action, when the absence is structural rather than an
/// omission somebody forgot to fix.
enum NonActionReason: String, Codable, Sendable {
    /// A playlist, a calendar, a show — the row describes a container. Its
    /// *contents* are the acts, and they arrive as their own rows.
    case container

    /// Whether somebody has an Apple Music subscription. A fact about an
    /// account, not about a taste.
    case accountState

    /// Age and biological sex. A protected characteristic is not an act, and
    /// `health/biological_sex` never leaves the device at all —
    /// `SyncService.localOnlyTypes` refuses it at the wire.
    case demographic

    /// A `user` row: a bio, an occupation, a flirt level. `sources` gives this
    /// source `evidence_channel = 'explicit_profile'` and
    /// `default_reliability = 1.00` — it is stated rather than observed, so
    /// weighing it as behaviour would be a category error.
    case explicitProfileFact
}

/// What one `(source, data_type)` pair means to the semantic system.
enum ActionMapping: Equatable, Sendable {
    /// Every action this pair can produce. More than one when the act is
    /// decided by the *row* rather than by its kind — a calendar event is
    /// `booked` or `scheduled` depending on whether a ticketing site wrote it
    /// in.
    case actions([SemanticAction])

    /// A real behavioural signal the server has no weight for yet. Carried in
    /// the envelope under this name so the coverage comparison Phase 1 asks for
    /// can see it; scored as nothing until somebody decides what it is worth.
    ///
    /// **This is deliberately not the same as `notAnAction`.** One says "we
    /// have not decided", the other says "there is nothing to decide", and
    /// collapsing them would lose the list of things still owed a decision.
    case unweighted(String)

    /// Structurally not an act. See `NonActionReason`.
    case notAnAction(NonActionReason)
}

// MARK: - The mapping

extension SemanticSource {
    /// Every `data_type` this app can emit, and what it means.
    ///
    /// **Exhaustive by test, not by inspection.**
    /// `test_ios_envelope_contract.py` parses every `dataType: "…"` literal out
    /// of the distillers and fails if one is missing here — so a new
    /// `data_type` cannot reach the vault as an unattributed row. That is the
    /// extraction rule pointed the other way: keeping a field costs nothing,
    /// and a field kept with no meaning attached is how a row becomes
    /// unreadable to everything downstream.
    static let actionsByDataType: [SemanticSource: [String: ActionMapping]] = [
        .appleMusic: [
            "library_song": .actions([.librarySong]),
            "library_album": .actions([.libraryAlbum]),
            "library_artist": .actions([.libraryArtist]),
            "library_playlist": .actions([.libraryPlaylist]),
            "playlist_item": .actions([.playlistItem]),
            "rating": .actions([.rating]),
            "recently_added": .actions([.recentlyAdded]),
            "recently_played": .actions([.recentlyPlayed]),
            // Weighted 0 on purpose: Apple chose it, the listener did not. The
            // rows are still kept — an absent recommendation and a rejected one
            // are different facts, and only one of them is recoverable later.
            "recommendation": .actions([.recommendation]),
            // Apple's own "most played", which is the strongest listening claim
            // this source returns and has no weight on the server.
            "heavy_rotation": .unweighted("heavy_rotation"),
            "library_music_video": .unweighted("library_music_video"),
            "apple_music_subscription": .notAnAction(.accountState),
        ],
        .musicLibrary: [
            "library_song": .actions([.librarySong]),
        ],
        .spotify: [
            "recently_played": .actions([.recentlyPlayed]),
            "playlist_item": .actions([.playlistItem]),
            "followed_artist": .actions([.followedArtist]),
            // `top_track` carries an explicit `rank=N` and is the strongest
            // listening signal either music source returns. It joined
            // `MusicHighlights.songTypes` for exactly that reason, and `0139`
            // finally gave both a weight — 0.78 and 0.55, `recently_played`
            // and `followed_artist` respectively. They were `.unweighted` here
            // for as long as the server had no number for them, which is what
            // that case is for; leaving them there now would make this file
            // say the server ignores what it weighs.
            "top_track": .actions([.topTrack]),
            "top_artist": .actions([.topArtist]),
            "playlist": .notAnAction(.container),
        ],
        .applePodcasts: [
            // **Both of these are readings, and they are the least certain
            // entries in this table.** The library returns downloaded episodes
            // and nothing else — measured, not assumed: 304 cloud items sat
            // beside zero cloud podcasts, and following a show does not
            // enumerate its back catalogue. So an episode is something somebody
            // deliberately pulled down, which is `saved`, and a show present at
            // all is one they follow. If Apple Podcasts turns out to
            // auto-download for followed shows — the open question in the
            // Podcasts section of CLAUDE.md — `saved` becomes wrong and this is
            // the line to change.
            "podcast_show": .actions([.followed]),
            "podcast_episode": .actions([.saved]),
        ],
        .podcast: [
            "podcast_show": .actions([.followed]),
            "podcast_episode": .actions([.saved]),
        ],
        .appleCalendar: [
            "event": .actions([.booked, .scheduled]),
            "calendar": .notAnAction(.container),
        ],
        .googleCalendar: [
            "event": .actions([.booked, .scheduled]),
            "calendar": .notAnAction(.container),
        ],
        // **`scheduled` alone, and the absence of `booked` is the source
        // telling on itself.** `booked` is decided by an organiser and a
        // ticketing url — the two fields that separate a booking somebody paid
        // for from a reminder they typed — and `Calendars.ReadBasic` returns
        // neither. Listing `booked` here would let `action(for:)` reach for a
        // `booked=1` that this distiller can never stamp, which is a candidate
        // nothing can satisfy rather than a distinction being drawn.
        .outlookCalendar: [
            "event": .actions([.scheduled]),
            "calendar": .notAnAction(.container),
        ],
        .healthKit: [
            "workout": .actions([.workout]),
            "activity_day": .actions([.activityDay]),
            "activity_hour": .actions([.activityHour]),
            "age": .notAnAction(.demographic),
            "biological_sex": .notAnAction(.demographic),
        ],
        .youTube: [
            "liked_video": .actions([.likedVideo]),
            "subscription": .actions([.subscription]),
            "playlist_item": .actions([.playlistItem]),
            "playlist": .actions([.playlist]),
        ],
        .location: [
            // `sources` gives location `default_reliability = 0.00` and no
            // weights at all, so this is unweighted by the server's own
            // decision rather than by an oversight of ours.
            "place": .unweighted("place"),
        ],
        .user: [
            "age": .notAnAction(.explicitProfileFact),
            "gender": .notAnAction(.explicitProfileFact),
            "gender_preference": .notAnAction(.explicitProfileFact),
            "education": .notAnAction(.explicitProfileFact),
            "occupation": .notAnAction(.explicitProfileFact),
            "bio": .notAnAction(.explicitProfileFact),
            "flirt_level": .notAnAction(.explicitProfileFact),
            "response_time": .notAnAction(.explicitProfileFact),
            "apple_music_subscription": .notAnAction(.accountState),
        ],
    ]

    /// What this pair means, or `nil` for a `data_type` this source has never
    /// been recorded emitting — which is a refusal, for the reason
    /// `forAppSource` refuses an unknown source.
    func mapping(for dataType: String) -> ActionMapping? {
        Self.actionsByDataType[self]?[dataType]
    }
}

extension SemanticSource {
    /// The action a *particular row* represents, where the kind alone does not
    /// settle it.
    ///
    /// Only calendars need this today, and the distinction is the reason the
    /// Calendar source exists at all: a booking a ticketing site wrote in cost
    /// money and a Saturday, while a typed entry is somebody's own hand. See
    /// `booked=1` in `extra`, stamped by `CalendarDistiller`.
    func action(for record: DistilledRecord) -> SemanticAction? {
        switch mapping(for: record.dataType) {
        case .actions(let candidates):
            guard candidates.count > 1 else { return candidates.first }
            if candidates.contains(.booked), record.extraValue("booked") == "1" {
                return .booked
            }
            if candidates.contains(.scheduled) { return .scheduled }
            return candidates.first
        case .unweighted, .notAnAction, .none:
            return nil
        }
    }
}

// MARK: - Purpose and lifecycle

/// `raw_source_records.consent_purpose`. Three values, and the schema refuses a
/// fourth.
///
/// **The split is not cosmetic.** Calendar and HealthKit are separated from
/// everything else because their raw payloads are the whole point of the
/// encrypted vault, and because the v0.3.1 contract gates HealthKit transfer on
/// a recorded `fitness_connection` grant — `semantic_private.healthkit_use_grants`
/// exists to hold one and nothing in Swift writes it yet.
enum DataUsePurpose: String, Codable, Sendable {
    case sourceDistillation = "source_distillation"
    case calendarDistillation = "calendar_distillation"
    case fitnessConnection = "fitness_connection"
}

extension SemanticSource {
    /// The purpose a row from this source is captured under.
    var dataUsePurpose: DataUsePurpose {
        switch self {
        case .appleCalendar, .googleCalendar, .outlookCalendar:
            return .calendarDistillation
        case .healthKit: return .fitnessConnection
        default: return .sourceDistillation
        }
    }
}

/// `raw_source_records.lifecycle_state`.
///
/// `deleted` is a real deletion with the payload gone — the schema enforces it,
/// refusing a `deleted` row that still holds ciphertext. It is not the app's
/// `markedRemoved`, which strikes a row off and *keeps* it: "collected then
/// struck off" and "never collected" stay distinguishable, and the website says
/// never used, never shown, never counted rather than deleted.
enum SemanticLifecycleState: String, Codable, Sendable {
    case active
    case expired
    case deleted
}
