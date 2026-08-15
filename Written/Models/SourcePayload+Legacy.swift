import Foundation

/// Deriving a typed payload from a `DistilledRecord`.
///
/// **This whole file is scaffolding for the shadow phase and is meant to be
/// deleted.** The end state §4 describes is distillers emitting `SourcePayload`
/// directly; until then, dual-write needs some way to produce one, and
/// rewriting nine distillers is not Phase 1.
///
/// It inherits everything wrong with `extra`, and the inheritance is worth
/// naming rather than discovering later: `key=value;key=value` cannot represent
/// a value containing `;` or `=`, so a track called "Symphony No. 5; II" lost
/// its tail long before this file saw it. Nothing here can recover that. What
/// this file *can* do is stop the loss compounding — every key below is read
/// once, in one place, instead of each consumer inventing its own idea of which
/// keys exist.

// MARK: - Reading the legacy row

extension DistilledRecord {
    /// When the thing itself happened, as opposed to when Written read it.
    ///
    /// **Each source names this differently and none of them names it the
    /// same as the others**, which is precisely why it is worked out here once
    /// rather than at each call site. A missing answer is `nil` and not
    /// `collectedAt`: defaulting to the read time is how a five-year-old
    /// calendar entry becomes something that happened this afternoon.
    var sourceEventAt: Date? {
        for key in ["played_at", "start", "started_at", "last_played", "subscribed_at", "published_at"] {
            if let raw = extraValue(key), let parsed = DistilledRecord.parseDate(raw) {
                return parsed
            }
        }
        return nil
    }

    /// The formats the distillers actually write, tried in turn.
    ///
    /// Three, because there genuinely are three: Apple Music passes Apple's own
    /// strings through untouched (ISO 8601, sometimes with fractional seconds,
    /// and `yyyy-MM-dd` for a release date), HealthKit and Calendar write
    /// `ISO8601DateFormatter` output, and Podcasts writes day-only. Guessing
    /// one and dropping the rest would silently empty two sources.
    static func parseDate(_ raw: String) -> Date? {
        if let parsed = isoWithFractional.date(from: raw) { return parsed }
        if let parsed = iso.date(from: raw) { return parsed }
        return dayOnly.date(from: raw)
    }

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let isoWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Fixed to POSIX and UTC on purpose. A day string is parsed the same way
    /// on a phone set to a Buddhist calendar in Bangkok as on one in London,
    /// which `DateFormatter`'s defaults do not promise.
    private static let dayOnly: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// A pipe-separated list out of `extra` — `genres`, and `creator` on a
    /// track with several credits. Empty rather than `[""]` for an absent key.
    func extraList(_ key: String) -> [String] {
        guard let raw = extraValue(key) else { return [] }
        return raw.split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    func extraInt(_ key: String) -> Int? { extraValue(key).flatMap(Int.init) }
    func extraDouble(_ key: String) -> Double? { extraValue(key).flatMap(Double.init) }

    /// The hour out of an `HH:MM` extra, for `first_move`.
    ///
    /// **`extraInt` silently answered nil for every one of these.**
    /// `HealthKitDistiller` writes `first_move=06:00` (`"%02d:00"`), and
    /// `Int("06:00")` refuses the colon — so `FitnessPayload.firstMoveHour` was
    /// null on all 366 `activity_day` rows in the vault. The chronotype signal,
    /// which is the most distinctive thing an activity day carries, was dropped
    /// at the envelope boundary with nothing anywhere saying so. A typed field
    /// reading a string shape it cannot parse is the same defect as *two columns
    /// that accept the same words*, one level down.
    ///
    /// The minutes are always `00`, so an `Int` hour is lossless here and the
    /// classifier's `HH:MM` is reconstructible from it.
    func extraHour(_ key: String) -> Int? {
        guard let raw = extraValue(key) else { return nil }
        let hour = raw.split(separator: ":").first.flatMap { Int($0) }
        guard let hour, (0...23).contains(hour) else { return nil }
        return hour
    }

    /// `nil` for absent, so "not stated" and "stated false" stay apart. The
    /// distillers only ever write `1`, which makes the distinction free.
    func extraFlag(_ key: String) -> Bool? {
        guard let raw = extraValue(key) else { return nil }
        return raw == "1" || raw == "true"
    }
}

// MARK: - Building the payload

extension SourcePayload {
    init(record: DistilledRecord, source: SemanticSource) {
        switch source {
        case .appleMusic, .musicLibrary, .spotify:
            self = .music(MusicPayload(record: record))
        case .applePodcasts, .podcast:
            self = .podcast(PodcastPayload(record: record))
        case .appleCalendar, .googleCalendar, .outlookCalendar:
            self = .calendar(CalendarPayload(record: record))
        case .healthKit:
            // Age and biological sex are not fitness readings and do not fit
            // that shape. They are `notAnAction(.demographic)` on the mapping
            // side, and `biological_sex` never leaves the device at all.
            if record.dataType == "age" || record.dataType == "biological_sex" {
                self = .profile(ProfilePayload(record: record))
            } else {
                self = .fitness(FitnessPayload(record: record))
            }
        case .youTube:
            self = .video(VideoPayload(record: record))
        case .location:
            self = .place(PlacePayload(record: record))
        case .user:
            self = .profile(ProfilePayload(record: record))
        }
    }
}

extension MusicPayload {
    init(record: DistilledRecord) {
        let credits = record.creator
            .split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        self.init(
            title: record.name,
            // Spotify pipe-joins every credit; Apple Music writes one name. The
            // first element is the performer under both, which is the only
            // reason one field can serve both.
            primaryPerformer: credits.first,
            creditedArtists: credits,
            composer: record.extraValue("composer"),
            album: record.extraValue("album"),
            // **The same defect as `tags`/`keywords` below, third and fourth
            // and fifth instances.** `AppleMusicDistiller` writes `genres=`,
            // `play_count=` and `date_added=`; `MusicLibraryDistiller` writes
            // `genre=`, `plays=` and `added=` for the same three facts, and this
            // read knew only the cloud spelling. So every song in a device
            // library reached the vault with no genre, no play count and no
            // added date — and genre is what feeds sphere, scene and era, so the
            // loss is not one field but the whole reading of that library.
            //
            // A union, for the reason the `tags` comment gives: today each key
            // belongs to exactly one distiller, and if either ever gained the
            // other's spelling a union keeps it where a branch would drop it.
            // `genre=` is one name rather than a list, which `extraList` returns
            // as a list of one.
            genres: record.extraList("genres") + record.extraList("genre"),
            releaseDate: record.extraValue("released"),
            durationSeconds: record.extraDouble("duration_s"),
            isrc: record.extraValue("isrc"),
            resourceType: record.extraValue("resource_type"),
            playCount: record.extraInt("play_count") ?? record.extraInt("plays"),
            lastPlayedAt: record.extraValue("last_played").flatMap(DistilledRecord.parseDate),
            rank: record.extraInt("rank"),
            // Apple Music's like/dislike arrives as `value=1` / `value=-1` on a
            // `rating` row. Kept as the source's own word rather than turned
            // into a bool: a source that adds a third rating would otherwise
            // land silently as "not a like".
            rating: record.dataType == "rating" ? record.extraValue("value") : nil,
            playlistName: record.extraValue("playlist"),
            shelf: record.extraValue("shelf"),
            contentRating: record.extraValue("content_rating"),
            hasLyrics: record.extraFlag("has_lyrics"),
            addedAt: (record.extraValue("date_added") ?? record.extraValue("added"))
                .flatMap(DistilledRecord.parseDate),
            artworkURL: record.extraValue("artwork")
        )
    }
}

extension PodcastPayload {
    init(record: DistilledRecord) {
        let isEpisode = record.dataType == "podcast_episode"
        self.init(
            // An episode row names the episode and credits the show; a show row
            // names the show. Reading `name` for both would file every episode
            // as its own programme.
            showTitle: isEpisode ? record.creator : record.name,
            episodeTitle: isEpisode ? record.name : nil,
            publisher: isEpisode ? nil : record.creator,
            releaseDate: record.extraValue("released"),
            addedAt: record.extraValue("added").flatMap(DistilledRecord.parseDate),
            durationSeconds: record.extraDouble("duration_s"),
            resumeSeconds: record.extraDouble("resume_s"),
            progress: record.extraDouble("progress"),
            episodesOnDevice: record.extraInt("episodes_on_device")
        )
    }
}

extension CalendarPayload {
    init(record: DistilledRecord) {
        self.init(
            title: record.name,
            calendarName: record.extraValue("calendar"),
            calendarType: record.extraValue("cal_type"),
            startsAt: record.extraValue("start").flatMap(DistilledRecord.parseDate),
            endsAt: record.extraValue("end").flatMap(DistilledRecord.parseDate),
            isAllDay: record.extraFlag("all_day"),
            isRecurring: record.extraFlag("recurring"),
            isCancelled: record.extraFlag("cancelled"),
            isBooked: record.extraFlag("booked"),
            // `creator` holds the organizer *or* the calendar title, whichever
            // existed — one field carrying two meanings, which is why the
            // structured `organizer=` key is preferred and `creator` is not a
            // fallback for it.
            organizer: record.extraValue("organizer"),
            location: record.detail.isEmpty ? nil : record.detail,
            url: record.extraValue("url"),
            durationMinutes: record.extraDouble("duration_min"),
            hour: record.extraInt("hour"),
            weekday: record.extraInt("weekday"),
            isWeekend: record.extraFlag("weekend")
        )
    }
}

extension FitnessPayload {
    init(record: DistilledRecord) {
        self.init(
            kind: record.dataType,
            sport: record.dataType == "workout" ? record.name : nil,
            startedAt: record.extraValue("started_at").flatMap(DistilledRecord.parseDate),
            durationMinutes: record.extraDouble("duration_min"),
            energyKcal: record.extraDouble("energy_kcal"),
            distanceKm: record.extraDouble("distance_km"),
            // Which watch or app logged it. A Strava-tracked ride and a
            // Watch-tracked one are the same sport recorded by different
            // habits.
            recordingApp: record.dataType == "workout" && !record.creator.isEmpty
                ? record.creator : nil,
            date: record.dataType == "activity_day" ? record.name : nil,
            exerciseMinutes: record.extraDouble("exercise_min"),
            activeKcal: record.extraDouble("active_kcal"),
            steps: record.extraDouble("steps"),
            firstMoveHour: record.extraHour("first_move"),
            hourOfDay: record.dataType == "activity_hour" ? record.extraInt("hour") : nil,
            hourShare: record.dataType == "activity_hour" ? record.extraDouble("share") : nil
        )
    }
}

extension VideoPayload {
    init(record: DistilledRecord) {
        self.init(
            title: record.name,
            channelTitle: record.creator.isEmpty ? nil : record.creator,
            // **A subscription's `item_id` *is* the channel id**, so it needs no
            // `channel_id=` in `extra` and never had one — `YouTubeDistiller`
            // writes `itemID: channelID` for that row. Reading only `extra`
            // therefore gave every subscription a null channel, which is
            // invisible until something tries to use it: measured 2026-08-13,
            // 941 liked videos carried a channel id and all 430 subscriptions
            // carried none, so `channel_identity` terms could only ever come
            // from likes. A subscription is the stronger signal of the two —
            // somebody chose the channel rather than a single video — and it
            // was the half being dropped.
            channelID: record.dataType == "subscription"
                ? (record.itemID.isEmpty ? nil : record.itemID)
                : record.extraValue("channel_id"),
            publishedAt: record.extraValue("published_at").flatMap(DistilledRecord.parseDate),
            description: record.detail.isEmpty ? nil : record.detail,
            // Read, never computed. See `VideoPayload`.
            topics: record.extraList("topics"),
            // **A channel's keywords arrive under `keywords=`, and reading only
            // `tags` is the whole of why they have never reached the vault.**
            // The same defect as `channelID` above, in the same initializer and
            // for the same reason: `YouTubeDistiller` writes the field under
            // the name that fits the row it came from — `tags=` on a liked
            // video (`snippet.tags`), `keywords=` on a subscription
            // (`brandingSettings.channel.keywords`) — and this read knew one
            // name. Measured 2026-08-14 on the owner's account: 2,134
            // `uploader_tag` mappings from liked videos and **zero** from
            // subscriptions, across 466 subscription observations that carry
            // keywords in `distilled_records` and none in the vault.
            //
            // The distiller already intended one lane — it pipe-joins the
            // keywords "to match `tags=` on liked videos, so one parser serves
            // both" — so this is that parser finally serving both. Both fields
            // are the uploader's own keyword list, which is what `uploader_tag`
            // is licensed to read under `0078`; neither is a category anybody
            // inferred.
            //
            // A union rather than a branch on `dataType`. Today it is exact —
            // a liked video never carries `keywords=` and a subscription never
            // carries `tags=` — and if either row ever gains the other field a
            // union keeps it, where a branch would drop it silently, which is
            // the failure this comment exists to describe.
            tags: record.extraList("tags") + record.extraList("keywords"),
            categoryID: record.extraValue("category_id"),
            playlistTitle: record.extraValue("playlist"),
            subscriberCount: record.extraValue("subscriber_count")
        )
    }
}

extension PlacePayload {
    init(record: DistilledRecord) {
        self.init(name: record.name, detail: record.detail.isEmpty ? nil : record.detail)
    }
}

extension ProfilePayload {
    init(record: DistilledRecord) {
        self.init(
            field: record.dataType,
            value: record.name,
            detail: record.detail.isEmpty ? nil : record.detail
        )
    }
}
