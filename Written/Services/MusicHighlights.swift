import Foundation

/// Turns distilled music records into the figures the dashboard's music card
/// shows: who the person listens to most, and how much.
///
/// Pure and stateless, like `TreeMetrics` — everything here is derived from
/// records that are already on the device, so it can be reasoned about (and
/// checked) against a saved distillation without running the app.
enum MusicHighlights {

    /// One artist's standing: how many distinct songs of theirs we found, and a
    /// cover to show for them.
    struct Artist: Identifiable, Hashable {
        var id: String { name }
        let name: String
        let songs: Int
        /// An album cover from one of their songs, or their own photo. `nil`
        /// for records distilled before the distillers kept image URLs — the
        /// dashboard draws a monogram instead.
        let artworkURL: URL?
    }

    /// Rows that mean "this person has or has played this song".
    ///
    /// Apple Music's `recommendation` rows are deliberately absent: those are
    /// Apple's suggestions, not listening, and counting them would credit
    /// artists the person has never chosen.
    /// **Internal, because `Ontology` has to agree with it.** Two lists of which
    /// rows count as listening is two lists that drift, and the drift already
    /// happened: `Ontology.subjects` filtered on `dataType == "song"`, which
    /// `AppleMusicDistiller` has never written, so it answered `[]` for every
    /// real library and `discovery_cards.top_subjects` was empty for reasons
    /// nobody had found.
    ///
    /// **`top_track` is Spotify's, and leaving it out made Spotify's best
    /// signal invisible.** Of the six types `SpotifyDistiller` emits only
    /// `recently_played` and `playlist_item` overlapped Apple Music's, so a
    /// Spotify library counted for almost nothing — while `top_track` carries
    /// an explicit `rank=N`, which is a stronger statement about listening than
    /// anything Apple Music returns. Named for what it is: a *top* track is not
    /// a *saved* one, and renaming it to match Apple's vocabulary would file a
    /// different fact under the same word.
    static let songTypes: Set<String> = [
        "library_song", "heavy_rotation", "playlist_item", "recently_played",
        "top_track"
    ]

    /// Rows that are about an artist rather than a song, used for cover art and
    /// nothing else. `top_artist` and `followed_artist` are Spotify's, and were
    /// absent for the same reason `top_track` was.
    private static let artistTypes: Set<String> = [
        "library_artist", "top_artist", "followed_artist"
    ]

    /// Artists ranked by how many of their songs appear, most first.
    ///
    /// Every artist credited on a song is counted, not just the first: the
    /// question is how many songs are *associated with* them, and a feature
    /// spot is still an association. Ties break on name so two artists on the
    /// same count don't swap places between renders.
    static func topArtists(in records: [DistilledRecord], limit: Int = 6) -> [Artist] {
        let songs = deduplicatedSongs(in: records)

        var counts: [String: Int] = [:]
        var covers: [String: URL] = [:]
        for song in songs {
            for artist in creditedArtists(of: song) {
                counts[artist, default: 0] += 1
                // First cover wins: songs arrive in the order the distiller
                // found them, which is roughly most-representative-first, rather
                // than a random album.
                if covers[artist] == nil, let cover = artworkURL(of: song) {
                    covers[artist] = cover
                }
            }
        }

        // An artist whose songs carry no cover can still borrow their own photo
        // from a `top_artist` / `followed_artist` row.
        for record in records where artistTypes.contains(record.dataType) && !record.isRemovedByUser {
            let name = record.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, covers[name] == nil, let photo = artworkURL(of: record) {
                covers[name] = photo
            }
        }

        var ranked: [Artist] = counts.map { name, songs in
            Artist(name: name, songs: songs, artworkURL: covers[name])
        }
        ranked.sort { left, right in
            left.songs == right.songs ? left.name < right.name : left.songs > right.songs
        }
        return Array(ranked.prefix(limit))
    }

    /// How many distinct songs the music distillation found in total.
    static func songCount(in records: [DistilledRecord]) -> Int {
        deduplicatedSongs(in: records).count
    }

    /// One song, named well enough to say something about it.
    struct Song: Hashable {
        let title: String
        /// The first credited artist, as the platform wrote it. A song with
        /// three names on it is still "a Jay Chou song" to the person who put
        /// it on.
        let artist: String
        let artworkURL: URL?
        let source: String

        /// The artist as a person would say it, which is once rather than twice.
        ///
        /// Streaming services bundle a name with its own translation —
        /// "周杰倫 Jay Chou", "i-dle (아이들)" — because they are indexing for
        /// everybody at once. A caption is not an index: it is one person
        /// talking, and nobody says both halves. The original script wins,
        /// because that is the name and the other half is the gloss.
        var displayArtist: String { Song.preferredName(artist) }

        /// Keeps only the non-Latin tokens, and only when the name is genuinely
        /// mixed.
        ///
        /// The mixed test is what makes this safe: "Leehom Wang" is two Latin
        /// tokens and neither is a translation of the other, so nothing is
        /// dropped. Only a name carrying two scripts is treated as carrying a
        /// name and its gloss.
        static func preferredName(_ artist: String) -> String {
            let tokens = artist.split(separator: " ").map {
                $0.trimmingCharacters(in: CharacterSet(charactersIn: "()[]（）【】"))
            }.filter { !$0.isEmpty }
            guard tokens.count > 1 else { return artist }

            let original = tokens.filter { isOriginalScript($0) }
            let latin = tokens.filter { !isOriginalScript($0) }
            guard !original.isEmpty, !latin.isEmpty else { return artist }

            return original.joined(separator: " ")
        }

        /// True when a token's letters are mostly *not* Latin — CJK, kana,
        /// Hangul, Cyrillic and the rest. `0x0250` is where Latin Extended ends,
        /// so accented Latin ("Beyoncé", "Sigur Rós") stays on the Latin side
        /// where it belongs.
        private static func isOriginalScript(_ token: String) -> Bool {
            var latin = 0, other = 0
            for scalar in token.unicodeScalars where CharacterSet.letters.contains(scalar) {
                if scalar.value < 0x0250 { latin += 1 } else { other += 1 }
            }
            return other > latin
        }
    }

    /// The one song to lead with — what they play most, preferring what they
    /// played most recently.
    ///
    /// There is no single field for this: each platform answers a slightly
    /// different question, so the ladder below walks them in order of how well
    /// each one answers *ours*, and takes the first that has an opinion.
    ///
    /// 1. The newest `recently_played` — not a considered ranking, but "just
    ///    now" is a strong claim on its own.
    /// 2. `heavy_rotation`, ordered by play count.
    /// 3. Any song at all, so a library-only distillation still gets a line.
    ///
    /// A fourth rung sat at the top until Spotify was dropped: its `top_track`
    /// rows carried an explicit `rank=N`, the only outright answer any platform
    /// gave us. Apple Music offers nothing equivalent.
    static func topSong(in records: [DistilledRecord]) -> Song? {
        let songs = deduplicatedSongs(in: records)
        guard !songs.isEmpty else { return nil }

        // Apple writes `last_played`; `played_at` is still read because the
        // grammar is shared and both are ISO-8601, so they compare as strings
        // without parsing either.
        let newest = songs
            .filter { $0.dataType == "recently_played" }
            .compactMap { record -> (DistilledRecord, String)? in
                guard let played = record.extraValue("played_at") ?? record.extraValue("last_played") else { return nil }
                return (record, played)
            }
            .max { $0.1 < $1.1 }?.0

        let played = songs
            .filter { $0.dataType == "heavy_rotation" }
            .compactMap { record -> (DistilledRecord, Int)? in
                guard let count = record.extraValue("play_count").flatMap(Int.init) else { return nil }
                return (record, count)
            }
            .max { $0.1 < $1.1 }?.0

        guard let winner = newest ?? played ?? songs.first else { return nil }
        let title = winner.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let artist = creditedArtists(of: winner).first else { return nil }

        return Song(
            title: title,
            artist: artist,
            artworkURL: artworkURL(of: winner),
            source: winner.source
        )
    }

    /// One slice of the genre bar.
    struct Genre: Identifiable, Hashable {
        var id: String { name }
        let name: String
        let songs: Int
        /// Of all genre credits, not of all songs: a song tagged both "Pop" and
        /// "Mandopop" is counted under each, so shares over songs would sum past
        /// 1 and the bar would overflow its own width.
        let fraction: Double
    }

    /// Where the music sits by genre, biggest share first, with the tail merged
    /// into "Other".
    ///
    /// Filled from Apple Music's `genreNames`. Empty is a real answer — the
    /// dashboard reads it as "draw nothing" rather than an error.
    static func genreShare(in records: [DistilledRecord], limit: Int = 5) -> [Genre] {
        var counts: [String: Int] = [:]
        for song in deduplicatedSongs(in: records) {
            for genre in genres(of: song) {
                counts[genre, default: 0] += 1
            }
        }
        guard !counts.isEmpty else { return [] }

        var ranked: [(name: String, songs: Int)] = counts.map { (name: $0.key, songs: $0.value) }
        ranked.sort { left, right in
            left.songs == right.songs ? left.name < right.name : left.songs > right.songs
        }

        let total = Double(ranked.reduce(0) { $0 + $1.songs })
        var slices = ranked.prefix(limit).map { entry in
            Genre(name: entry.name, songs: entry.songs, fraction: Double(entry.songs) / total)
        }

        let tail = ranked.dropFirst(limit).reduce(0) { $0 + $1.songs }
        if tail > 0 {
            slices.append(Genre(name: "Other", songs: tail, fraction: Double(tail) / total))
        }
        return slices
    }

    /// Genres as the distillers write them — pipe-separated inside `extra`.
    /// Cased for display and matched case-insensitively, so `hip-hop` from one
    /// source and `Hip-Hop` from another are one slice rather than two.
    private static func genres(of record: DistilledRecord) -> [String] {
        (record.extraValue("genres") ?? "")
            .split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { $0.capitalized }
    }

    // MARK: - Reading the records

    /// The same song reaches us more than once — as a library row, as recently
    /// played, and again inside every playlist it sits on. Counting the rows
    /// would rank an artist by how many lists their song is on rather than by
    /// their music.
    ///
    /// **Collapsed on title and artist, not on the platform's id**, and that is
    /// the correction rather than the original design. Ids only ever deduplicate
    /// *within* a source, and this app reads one library through two of them:
    /// `AppleMusicDistiller` and `MusicLibraryDistiller` both return the cloud
    /// library on a subscriber's phone, with different ids for the same track.
    /// Measured on a real export: 320 songs under each source, **320 title and
    /// artist pairs in common, and zero ids in common** — so every song counted
    /// twice and every artist total was double.
    ///
    /// The doubling was uniform, which is why it hid: rankings held and the
    /// shares in `Ontology.subjects` were unaffected, because the denominator
    /// doubled with the numerator. What was wrong was every absolute count, and
    /// the safety of the rest rested on two sources having identical coverage —
    /// the moment one cloud song is missing locally, the ranking skews with
    /// nothing on screen to say so.
    ///
    /// **The cost is a live version and a studio one collapsing** where the
    /// title and artist match exactly. That is the right trade against counting
    /// an entire library twice, and it is the same key the empty-id fallback
    /// already used — it simply stops being reached only in the rare case.
    ///
    /// Skipping cloud items in `MusicLibraryDistiller` was the alternative and is
    /// worse on this evidence: CLAUDE.md's own measurement found the sixteen
    /// non-cloud rows on that library were Apple Music downloads that merely read
    /// as local, so the flag cannot be trusted to tell owned music from streamed.
    ///
    /// **The collapse is scoped to one library read twice, not to two services.**
    /// It was written for `apple_music` against `music_library` — the same Apple
    /// metadata arriving by two routes, which is why matching on title and artist
    /// works there. Spotify is a different library with different metadata, and
    /// letting the key reach across would have been wrong in both directions at
    /// once: `AppleMusicDistiller` writes a single artist name while
    /// `SpotifyDistiller` pipe-joins every credit, so a single-artist track would
    /// collapse and discard the Spotify row, while a featured one — `Drake`
    /// against `Drake|Future|Kyla` — would not, and would count twice.
    /// Spelling-dependent, silent, and different for every track.
    ///
    /// So the key carries a *group* rather than a source: sources that read the
    /// same library share one, and anything else stands on its own. For the
    /// collection prototype that is also the answer we want — Apple Music and
    /// Spotify are meant to be legible side by side rather than merged into a
    /// figure that hides which service it came from.
    private static func dedupeGroup(for source: String) -> String {
        // One Apple library, two readers. Everything else is itself.
        ["apple_music", "music_library"].contains(source) ? "apple" : source
    }

    static func deduplicatedSongs(in records: [DistilledRecord]) -> [DistilledRecord] {
        var seen: Set<String> = []
        var songs: [DistilledRecord] = []
        for record in records where Modality.music.recordSources.contains(record.source)
            && songTypes.contains(record.dataType)
            // Struck off by the user. The row is still in the data, carrying the
            // note that says so; it just stops counting toward anything.
            && !record.isRemovedByUser {
            let group = dedupeGroup(for: record.source)
            let title = record.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let artist = record.creator.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            // A row with neither is not a song anybody can name; fall back to its
            // id so it is at least counted once rather than collapsing every
            // untitled row into one.
            let key = title.isEmpty && artist.isEmpty
                ? "\(group)|\(record.source)|\(record.itemID)"
                : "\(group)|\(title)|\(artist)"
            if seen.insert(key).inserted { songs.append(record) }
        }
        return songs
    }

    /// `creator` is pipe-joined when a song has several artists.
    private static func creditedArtists(of record: DistilledRecord) -> [String] {
        record.creator
            .split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func artworkURL(of record: DistilledRecord) -> URL? {
        record.extraValue("artwork").flatMap(URL.init(string:))
    }
}
