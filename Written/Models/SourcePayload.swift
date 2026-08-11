import Foundation

/// The typed half of `SourceEnvelope` — what the row actually says, in fields
/// rather than in a semicolon string.
///
/// **Phase 1 of the v0.3.1 integration, and it ships no behaviour.** Nothing
/// reads these types yet.
///
/// §4 of the integration plan asks for "a source/action-specific Codable enum,
/// not a semicolon string and not arbitrary JSON", and the reason is the one
/// this codebase keeps paying for from the other direction: `extra` is
/// `key=value;key=value`, so every consumer re-parses it, every consumer
/// invents its own idea of which keys exist, and a key that stops being written
/// is discovered by something rendering blank. A field either exists on a
/// struct or it does not.
///
/// **Optional means the source did not return it, never that it is
/// unimportant.** Apple Music fills `composerName` on pop tracks and returns
/// nothing for plenty of classical ones; Spotify returns no composer at all.
/// Keeping the distinction between absent and empty is the whole reason these
/// are `String?` rather than `String`.

// MARK: - The payload

enum SourcePayload: Codable, Equatable, Sendable {
    case music(MusicPayload)
    case podcast(PodcastPayload)
    case calendar(CalendarPayload)
    case fitness(FitnessPayload)
    case video(VideoPayload)
    case place(PlacePayload)
    case profile(ProfilePayload)

    /// A row whose `data_type` this app emits and whose shape nothing has
    /// modelled yet. It carries the original `extra` verbatim.
    ///
    /// **It exists so that capture is never blocked on modelling**, which is
    /// the extraction rule applied to this layer: a row that cannot be typed is
    /// still a row worth keeping, and a pipeline that drops what it cannot
    /// parse loses data that can only be recovered by re-distilling everybody.
    /// `test_ios_envelope_contract.py` reports how many `data_type`s land here,
    /// so it stays a known list rather than a quiet default.
    case untyped(UntypedPayload)
}

// MARK: - Music

/// Apple Music, the on-device music library, and Spotify.
///
/// One shape for all three deliberately: they describe the same objects, and
/// three shapes would mean three sets of consumers and three places for a
/// composer to go missing.
struct MusicPayload: Codable, Equatable, Sendable {
    /// Track, album, artist or playlist name, depending on the action.
    var title: String

    /// The first credit — the artist a recording is *by*, before any features.
    /// Spotify pipe-joins every credit into one string and Apple Music does
    /// not, which is why this is extracted rather than passed through.
    var primaryPerformer: String?

    /// Every credit, in the order the source gave them.
    var creditedArtists: [String]

    /// **Present far more often than the shipping product suggests.** It is
    /// what tells a Bach partita from whoever performed it, and
    /// `AppleMusicDistiller` fetched it and discarded it at one line for
    /// months, making classical listening invisible.
    var composer: String?

    var album: String?
    var genres: [String]
    var releaseDate: String?
    var durationSeconds: Double?
    var isrc: String?

    /// Apple Music's `resource_type` — `songs`, `albums`, `library-songs`.
    /// Which endpoint the object came back from, which is not the same question
    /// as what the person did with it.
    var resourceType: String?

    var playCount: Int?
    var lastPlayedAt: Date?

    /// Spotify's `rank=N` on a top track or artist: 1 is the most listened to.
    var rank: Int?

    /// Apple Music's like/dislike, as the source words it.
    var rating: String?

    /// The playlist a `playlist_item` came from.
    var playlistName: String?

    /// Apple Music's `shelf` — which recommendation row a suggestion sat in.
    var shelf: String?

    var contentRating: String?
    var hasLyrics: Bool?
    var addedAt: Date?
    var artworkURL: String?
}

// MARK: - Podcasts

/// Apple Podcasts, which returns downloaded episodes and nothing else.
///
/// The empty fields are as informative as the full ones and are recorded in
/// CLAUDE.md: `playCount` was 0 and `lastPlayedDate` nil on episodes
/// demonstrably played, so **there is no play history here**. `resumeSeconds`
/// is the only behavioural fact the source returns and it is real.
struct PodcastPayload: Codable, Equatable, Sendable {
    var showTitle: String
    var episodeTitle: String?
    /// `artist`/`albumArtist` on the media item, which is the publisher.
    var publisher: String?
    var releaseDate: String?
    var addedAt: Date?
    var durationSeconds: Double?
    /// `bookmarkTime` — how far in somebody got.
    var resumeSeconds: Double?
    var progress: Double?
    /// How many episodes of this show are on the device, which is the closest
    /// thing to a following signal the library offers.
    var episodesOnDevice: Int?
}

// MARK: - Calendar

/// Apple Calendar and Google Calendar.
///
/// **This is the most sensitive payload in the app and the reason the vault is
/// encrypted at all.** Titles are other people's names, medical appointments
/// and addresses; they are kept whole because the titles *are* the signal, and
/// `PrivacyInfo.xcprivacy` says so.
struct CalendarPayload: Codable, Equatable, Sendable {
    var title: String
    var calendarName: String?
    /// `EKCalendarType` — `caldav`, `local`, `subscription`, `birthday`. Not a
    /// filter: `CalendarDistiller.isGenerated` already drops generated
    /// calendars, and this records what survived.
    var calendarType: String?

    var startsAt: Date?
    var endsAt: Date?
    var isAllDay: Bool?
    var isRecurring: Bool?
    var isCancelled: Bool?

    /// Whether a ticketing site wrote this in by itself. The single most
    /// load-bearing field on this struct — it is what separates a booking that
    /// cost money and a Saturday from a dentist appointment, and it decides the
    /// envelope's action.
    var isBooked: Bool?

    var organizer: String?
    var location: String?
    var url: String?
    var durationMinutes: Double?

    /// Kept as the source's own reading rather than recomputed downstream: the
    /// hour and weekday an event sits on are what "evenings and weekends" is
    /// made of, and recomputing from `startsAt` in another timezone is how that
    /// quietly stops being true.
    var hour: Int?
    var weekday: Int?
    var isWeekend: Bool?
}

// MARK: - Fitness

/// HealthKit. Four shapes in one struct, because they share an owner and a
/// consent purpose and splitting them would put four cases in the enum for one
/// permission sheet.
///
/// **`activityHour` is 24 rows for the whole window, not 8,760** — the question
/// is which hours somebody moves in, not what they did at 3pm last March. The
/// distiller buckets before it makes a record, which is why a year of Health is
/// 400–700 rows against 2,540 from one real Apple Music library.
struct FitnessPayload: Codable, Equatable, Sendable {
    /// `workout`, `activity_day`, `activity_hour` — which shape this is.
    var kind: String

    /// The workout's sport, as HealthKit names it.
    var sport: String?
    var startedAt: Date?
    var durationMinutes: Double?
    var energyKcal: Double?
    var distanceKm: Double?
    /// Which app recorded it, which is a real signal about how somebody trains.
    var recordingApp: String?

    /// `activity_day`.
    var date: String?
    var exerciseMinutes: Double?
    var activeKcal: Double?
    var steps: Double?
    /// The hour of the first movement of the day — the chronotype signal.
    var firstMoveHour: Int?

    /// `activity_hour`: which hour of the day this row aggregates.
    var hourOfDay: Int?
}

// MARK: - Video

/// YouTube, which is archived. Kept compiled for the reason every archived
/// source is: restoring it should be an edit rather than a rewrite.
///
/// **`topics`, `tags` and `categoryID` are read, never computed.** III.E.4.h
/// prohibits inferring or estimating the content category of a video or
/// channel, and its remedy is its own heading — only offer metrics available
/// via the API. So these three fields are YouTube's own words, and there is no
/// field here for a label this app worked out.
struct VideoPayload: Codable, Equatable, Sendable {
    var title: String
    var channelTitle: String?
    var channelID: String?
    var publishedAt: Date?
    var description: String?
    /// `topicDetails.topicCategories`, reduced to the last path component.
    var topics: [String]
    /// `snippet.tags`, matched whole and lowercased downstream — never as
    /// substrings, since recognising `physics` is translation and matching
    /// `phys` inside a title is a guess wearing the same clothes.
    var tags: [String]
    var categoryID: String?
    var playlistTitle: String?
}

// MARK: - Place and profile

struct PlacePayload: Codable, Equatable, Sendable {
    var name: String
    var detail: String?
}

/// A `user` row: something somebody typed or chose about themselves.
///
/// Stated rather than observed, which is why `sources` gives this source
/// `default_reliability = 1.00` and no action weights at all.
struct ProfilePayload: Codable, Equatable, Sendable {
    /// The `data_type`: `bio`, `occupation`, `flirt_level`, and so on.
    var field: String
    var value: String
    var detail: String?
}

/// The escape hatch. See `SourcePayload.untyped`.
struct UntypedPayload: Codable, Equatable, Sendable {
    var name: String
    var creator: String?
    var detail: String?
    /// The original `key=value;key=value`, verbatim and unparsed.
    var extra: String
}
