import Foundation

/// Distills the signals listed for Spotify in written_api.xlsx:
/// top artists and tracks, recently played tracks, followed artists,
/// and playlists (plus their contents).
struct SpotifyDistiller {

    let oauth: OAuthPKCEService

    private static let baseURL = "https://api.spotify.com"

    func distill() async throws -> [DistilledRecord] {
        let token = try await oauth.validAccessToken()
        var records: [DistilledRecord] = []

        // 1. Top artists — Spotify's own ranking of the user's taste.
        let topArtists = try await fetchAllPages(
            token: token,
            path: "/v1/me/top/artists?time_range=medium_term&limit=50",
            itemsKey: ["items"]
        )
        // **`rank` goes in `extra`, which is where it is read.** It was written
        // into `detail` and `MusicPayload` reads `record.extraInt("rank")`,
        // which only searches `extra` — so the one outright ranking any music
        // platform gives us has been nil in every payload since the field was
        // added. Same key-mismatch family as `keywords` against `tags`, and
        // nothing reads `rank` out of `detail`, so this moves rather than
        // duplicates.
        records += topArtists.enumerated().map { index, artist in
            artistRecord(artist, dataType: "top_artist", rank: index + 1)
        }

        // 2. Top tracks.
        let topTracks = try await fetchAllPages(
            token: token,
            path: "/v1/me/top/tracks?time_range=medium_term&limit=50",
            itemsKey: ["items"]
        )
        records += topTracks.enumerated().map { index, track in
            trackRecord(
                track, dataType: "top_track", detail: albumName(of: track),
                extraSuffix: "rank=\(index + 1)"
            )
        }

        // 3. Recently played (items wrap the track with a played_at timestamp).
        if let recentlyPlayed = try? await fetchAllPages(
            token: token,
            path: "/v1/me/player/recently-played?limit=50",
            itemsKey: ["items"]
        ) {
            records += recentlyPlayed.compactMap { item in
                guard let track = item["track"] as? [String: Any] else { return nil }
                return trackRecord(
                    track,
                    dataType: "recently_played",
                    detail: albumName(of: track),
                    extraSuffix: "played_at=\(item["played_at"] as? String ?? "")"
                )
            }
        }

        // 3b. Saved tracks — the person's own library, and the counterpart of
        // Apple Music's `library_song`.
        //
        // **The largest thing this source was missing, and it was a scope
        // rather than a field.** Measured 2026-08-14: Apple's `library_song` is
        // 641 rows and every one states a genre, while Spotify's library had
        // never been asked for at all — so what was being compared was Apple's
        // library against Spotify's top charts. `user-library-read` is what
        // opens it; see `AppConfig.spotifyScope` for what that costs.
        //
        // `added_at` is stamped as `date_added=`, which is the key
        // `MusicPayload` already reads and `AppleMusicDistiller` already
        // writes. Writing it under Spotify's own name would be the
        // `keywords`/`tags` defect a second time: a field present in the record
        // and invisible to everything downstream.
        if let saved = try? await fetchAllPages(
            token: token,
            path: "/v1/me/tracks?limit=50",
            itemsKey: ["items"]
        ) {
            records += saved.compactMap { item in
                guard let track = item["track"] as? [String: Any] else { return nil }
                return trackRecord(
                    track,
                    dataType: "saved_track",
                    detail: albumName(of: track),
                    extraSuffix: added(from: item)
                )
            }
        }

        // 3c. Saved albums, the counterpart of `library_album`.
        //
        // **An album object states its own genres**, unlike a track, so these
        // rows can carry one without the catalogue lookup. Apple leaves the
        // field populated more often than Spotify does, and an empty list is
        // dropped rather than stamped — an unstated genre and a stated empty
        // one are different facts and only the first is true here.
        if let albums = try? await fetchAllPages(
            token: token,
            path: "/v1/me/albums?limit=50",
            itemsKey: ["items"]
        ) {
            records += albums.compactMap { item in
                guard let album = item["album"] as? [String: Any] else { return nil }
                return albumRecord(album, added: added(from: item))
            }
        }

        // 4. Followed artists (cursor pagination nested under "artists").
        let followed = try await fetchAllPages(
            token: token,
            path: "/v1/me/following?type=artist&limit=50",
            itemsKey: ["artists", "items"]
        )
        records += followed.map { artist in
            artistRecord(artist, dataType: "followed_artist")
        }

        // 5. Playlists, then the items inside each.
        //
        // **`items`, not `tracks`, in both places — Spotify renamed the field
        // and the endpoint underneath us.** Measured 2026-08-14: every playlist
        // on every account has ever reached the vault with `track_count=0`, and
        // **not one `playlist_item` row has ever existed**, on either account,
        // at any time. The listing call succeeded throughout — the names,
        // owners and descriptions are all intact — so a renamed key is the
        // whole of it. Same family as `keywords` read as `tags`, and the third
        // time this shape has cost this project something.
        //
        // The old names are still read as a fallback: `tracks` is documented as
        // present-but-deprecated on the object, and a source that stops
        // answering costs a re-distill, which is somebody's afternoon.
        let playlists = try await fetchAllPages(
            token: token,
            path: "/v1/me/playlists?limit=50",
            itemsKey: ["items"]
        )

        // Which playlists we actually got the contents of, so the rows can say
        // so — see `expanded=` below. Built before the playlist rows, which is
        // why those are appended after this loop rather than before it.
        var expanded: [String: Bool] = [:]
        // **The status code the refusal came back with, because "it failed" is
        // not a diagnosis.** `fetchAllPages` puts the HTTP status in the
        // error's `code`, and three of thirteen playlists refused on the run
        // that proved this — all three owned by somebody else, while a fourth
        // owned by somebody else succeeded. Recording the code is what lets the
        // next person tell a 404 from a 403 without shipping a build to find out.
        var refusal: [String: Int] = [:]
        for playlist in playlists.prefix(AppConfig.maxPlaylistsExpanded) {
            guard let playlistID = playlist["id"] as? String else { continue }
            let playlistName = playlist["name"] as? String ?? playlistID
            let items: [[String: Any]]
            do {
                // Best effort per playlist; one bad playlist must not sink the distill.
                items = try await fetchAllPages(
                    token: token,
                    path: "/v1/playlists/\(playlistID)/items?limit=100",
                    itemsKey: ["items"]
                )
            } catch {
                expanded[playlistID] = false
                refusal[playlistID] = (error as NSError).code
                continue
            }
            expanded[playlistID] = true

            records += items.compactMap { entry in
                // **`item`, not `track` — the third name Spotify changed in one
                // endpoint family.** The field on the playlist object, the path,
                // and now the wrapper around each element: all three deprecated
                // in favour of `item`, none of them announced in the 2024-11-27
                // post. Fixing the first two made the fetch *succeed* and still
                // produce nothing, which is the same silence the 404 gave and
                // the reason `expanded=` is worth having.
                guard let track = (entry["item"] as? [String: Any])
                    ?? (entry["track"] as? [String: Any]) else { return nil }
                // A playlist may hold podcast episodes, which carry no artist,
                // album or ISRC and would land as a row with an empty creator.
                // Excluded only when Spotify *says* episode: an unrecognised
                // type stays a track, which is what every row here was until
                // this endpoint learned to return anything else.
                if track["type"] as? String == "episode" { return nil }
                return trackRecord(
                    track,
                    dataType: "playlist_item",
                    detail: "playlist=\(playlistName)",
                    // Free, on a response already fetched, and the same key
                    // `AppleMusicDistiller` writes and `MusicPayload` reads.
                    extraSuffix: added(from: entry)
                )
            }
        }

        records += playlists.map { playlist in
            let playlistID = playlist["id"] as? String ?? ""
            // **The refusal is written down rather than swallowed.** A `continue`
            // nobody counts is exactly why this went unreported for the whole
            // life of the source: "thirteen playlists, no contents" and
            // "thirteen empty playlists" read identically off the rows, and only
            // the first is a defect. Throwing instead would discard the eleven
            // hundred good rows beside these, which is the worse trade — so it
            // goes in `extra`, where platform quirks go.
            var extra = "track_count=\(playlistTotal(playlist))"
            if let wasExpanded = expanded[playlistID] {
                extra += ";expanded=\(wasExpanded ? 1 : 0)"
            }
            if let code = refusal[playlistID] { extra += ";refused=\(code)" }
            return record(
                dataType: "playlist",
                itemID: playlistID,
                name: playlist["name"] as? String ?? "",
                creator: (playlist["owner"] as? [String: Any])?["display_name"] as? String ?? "",
                detail: String((playlist["description"] as? String ?? "").prefix(120)),
                extra: extra
            )
        }

        return await withComposers(records)
    }

    // MARK: - Composers

    /// Fills in the composer and genres Spotify does not return.
    ///
    /// **Only for rows that could change, and only up to a ceiling.** Looking
    /// every track up would be the shape CLAUDE.md warns about — a per-item
    /// fetch with no ceiling — even batched. The gate costs nothing: the artist
    /// rows fetched moments ago carry `genres`, so a library with no classical
    /// artist in it asks the catalog nothing at all, which is most people.
    ///
    /// A row the lookup misses is left exactly as it was. Its subject stays the
    /// performer, which is what it would have been anyway, so a failure here
    /// costs nothing that was not already lost.
    private func withComposers(_ records: [DistilledRecord]) async -> [DistilledRecord] {
        // Which artists this person's own library says are classical. Built from
        // the artist rows rather than guessed from a name, because "is this
        // classical" is a question Spotify answers about artists even though it
        // will not answer it about tracks.
        var classicalArtists: Set<String> = []
        for record in records where record.dataType == "top_artist"
            || record.dataType == "followed_artist" {
            let genres = (record.extraValue("genres") ?? "").lowercased()
            if Self.classicalHints.contains(where: genres.contains) {
                classicalArtists.insert(record.name.lowercased())
            }
        }
        guard !classicalArtists.isEmpty else { return records }

        var isrcs: [String] = []
        for record in records {
            guard let isrc = record.extraValue("isrc"), !isrc.isEmpty else { continue }
            let credited = record.creator.split(separator: "|")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            guard credited.contains(where: classicalArtists.contains) else { continue }
            isrcs.append(isrc)
            if isrcs.count >= AppConfig.maxComposerLookups { break }
        }
        guard !isrcs.isEmpty else { return records }

        let credits = await ComposerService.shared.credits(forISRCs: isrcs)
        guard !credits.isEmpty else { return records }

        return records.map { record in
            guard let isrc = record.extraValue("isrc"),
                  let found = credits[isrc] else { return record }
            // **Stamp the ingredients, not the conclusion.** `musicSubject` is
            // the one implementation of "composer for classical, performer
            // otherwise" and it stays that way — this hands it the genre and the
            // composer it was missing and lets it decide, rather than deciding
            // here and having two copies of the rule to keep in step.
            let subject = Ontology.musicSubject(
                genres: found.genres,
                composer: found.composer,
                performer: record.creator.split(separator: "|").first
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            )
            var extra = record.extra
            extra += ";composer=\(found.composer)"
            if !found.genres.isEmpty {
                extra += ";genres=\(found.genres.joined(separator: "|"))"
            }
            // Replace the stamp rather than append a second one: `extraValue`
            // takes the first match, so a stale `subject=` would win.
            extra = Self.replacingSubject(in: extra, with: subject)
            return DistilledRecord(
                source: record.source, dataType: record.dataType, itemID: record.itemID,
                name: record.name, creator: record.creator, detail: record.detail,
                extra: extra, collectedAt: record.collectedAt
            )
        }
    }

    /// Matched against Spotify's own artist genres, lowercased. Incomplete by
    /// construction and deliberately generous — the cost of a false positive is
    /// one wasted entry in a batched request, and the cost of a false negative
    /// is a composer nobody ever sees.
    private static let classicalHints = [
        "classical", "baroque", "romantic", "opera", "orchestra", "choral",
        "early music", "renaissance", "chamber music"
    ]

    private static func replacingSubject(in extra: String, with subject: String) -> String {
        var pairs = extra.split(separator: ";").map(String.init)
            .filter { !$0.hasPrefix("subject=") }
        if !subject.isEmpty { pairs.append("subject=\(subject)") }
        return pairs.joined(separator: ";")
    }

    // MARK: - Fetching

    /// Fetches a paginated Spotify endpoint, following "next" links
    /// (full URLs). `itemsKey` is the path to the items array, since the
    /// followed-artists endpoint nests it one level deeper.
    private func fetchAllPages(
        token: String,
        path: String,
        itemsKey: [String]
    ) async throws -> [[String: Any]] {
        var items: [[String: Any]] = []
        var nextURL = URL(string: Self.baseURL + path)

        for _ in 0..<AppConfig.maxPagesPerEndpoint {
            guard let url = nextURL else { break }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)
            // **Storing is permitted; feeding a model is not.** IV.2.5 allows
            // Postgres explicitly, and IV.2.1.a forbids ingestion into an ML
            // model even with consent — so this archive may exist and may never
            // become training input. The corpus query at the foot of `0041` is
            // where that exclusion lives and is unchanged by this file.
            await RawArchive.shared.captureResponse(
                source: "spotify", endpoint: url.path, request: request, data: data
            )
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? ""
                throw NSError(
                    domain: "SpotifyDistiller",
                    code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                    userInfo: [NSLocalizedDescriptionKey: "Spotify API error: \(body.prefix(200))"]
                )
            }

            guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { break }
            for key in itemsKey.dropLast() {
                json = json[key] as? [String: Any] ?? [:]
            }
            items += json[itemsKey.last ?? "items"] as? [[String: Any]] ?? []
            nextURL = (json["next"] as? String).flatMap(URL.init(string:))
        }
        return items
    }

    // MARK: - Normalization

    private func trackRecord(
        _ track: [String: Any],
        dataType: String,
        detail: String,
        extraSuffix: String = ""
    ) -> DistilledRecord {
        let names = (track["artists"] as? [[String: Any]] ?? [])
            .compactMap { $0["name"] as? String }
        // Every credit, because a feature spot is still an association and
        // `MusicHighlights.creditedArtists` splits this back apart.
        let artists = names.joined(separator: "|")

        var extra = "album=\(albumName(of: track))"
        // **The album's release date, which is on every track object we already
        // fetch and was never copied off it.** `AppleMusicDistiller` stamps
        // `released=` and `MusicPayload` reads it, so the name is the one the
        // rest of the schema already speaks — this is a field taken, not a
        // schema widened.
        //
        // **What it buys, stated honestly, because it is less than it looks.**
        // `music_works.artist_eras` takes `released[:4]`, so a bare `1998` and a
        // full `1998-12-19` both work — Spotify's `release_date_precision` can
        // be `year`, `month` or `day` and all three are fine. That gives
        // `era:*`, which is scored and **never asserted**
        // (`NEVER_ASSERTED_KEY_PREFIXES`). The thing worth having is `scene:*`,
        // which crosses an era with a *sphere* — and a sphere is read off a
        // genre. Spotify states no genre on a track, so on this source a date
        // alone reaches nothing a person can see.
        //
        // Kept anyway, and the extraction rule is why: it is free, it is inside
        // a response already fetched, and a row that never carried the date
        // cannot be revisited without a re-distill — which is somebody's
        // afternoon. The day artist genres arrive, every row that already
        // carries a date becomes a scene without asking anybody for anything.
        if let released = releaseDate(of: track), !released.isEmpty {
            extra += ";released=\(released)"
        }
        // **The one identifier Spotify and Apple Music share.** Spotify returns
        // no composer and no track genre, so the classical rule cannot fire on
        // anything this API gives — but Apple's catalog carries both for the
        // same recording, and an ISRC is how to ask it. Stamped on every track
        // rather than only the classical-looking ones, because which rows are
        // worth asking about is a decision made later, over the whole library,
        // and a row that never carried the id cannot be revisited without a
        // re-distill.
        //
        // Present on full track objects, which is what `/v1/me/top/tracks` and
        // playlist items return. `recently-played` is the one to watch: if it
        // ever returns simplified objects this comes back empty and those rows
        // simply keep their performer.
        if let isrc = (track["external_ids"] as? [String: Any])?["isrc"] as? String,
           !isrc.isEmpty {
            extra += ";isrc=\(isrc)"
        }
        // **Three fields that were in the response all along.** Each is read
        // downstream and was nil for every Spotify row: `artwork` by
        // `MediaHighlights`, `MusicHighlights` and `Ontology`; `duration_s` by
        // `MusicPayload`. Seconds rather than milliseconds, because every other
        // duration in this schema is in seconds and a second unit would be a
        // second thing to remember.
        if let artwork = artworkURL(of: (track["album"] as? [String: Any]) ?? [:]) {
            extra += ";artwork=\(artwork)"
        }
        if let millis = track["duration_ms"] as? Int {
            extra += ";duration_s=\(millis / 1000)"
        }
        // **The subject is the first credit, never the joined string.**
        // `Ontology.storedSubject` falls back to `creator` when no `subject=` is
        // stamped, and `creator` here is pipe-joined — so an unstamped Spotify
        // row produced the subject `Drake|Future|Tems`, which then became a
        // discovery-card term, a ban value and a Memories chip, and could never
        // match an artwork lookup keyed on a real name.
        //
        // Spotify tracks carry no composer, so the classical rule cannot fire:
        // `musicSubject` is still the one implementation of that rule and is
        // called rather than reimplemented, but on this source it always
        // resolves to the performer. A Bach partita from Spotify is filed under
        // whoever played it — which is exactly what the rule exists to prevent
        // and cannot be helped without a field Spotify does not return.
        let subject = Ontology.musicSubject(
            genres: [], composer: nil, performer: names.first ?? ""
        )
        if !subject.isEmpty { extra += ";subject=\(subject)" }
        // Written for the semantic export adapter, which drops every Spotify row
        // that carries no resource type. Nothing in the app reads it today.
        extra += ";resource_type=track"
        if !extraSuffix.isEmpty { extra += ";\(extraSuffix)" }

        return record(
            dataType: dataType,
            itemID: track["id"] as? String ?? "",
            name: track["name"] as? String ?? "",
            creator: artists,
            detail: detail,
            extra: extra
        )
    }

    /// An artist row — `top_artist` or `followed_artist`.
    ///
    /// `creator` is a single name here rather than the pipe-joined credit list a
    /// track carries, so `subject=` and `creator` agree; it is stamped anyway so
    /// the value is stated rather than inferred from a fallback.
    private func artistRecord(
        _ artist: [String: Any],
        dataType: String,
        rank: Int? = nil
    ) -> DistilledRecord {
        let name = artist["name"] as? String ?? ""
        let genres = (artist["genres"] as? [String] ?? []).filter { !$0.isEmpty }
        // **Only when Spotify said something.** `genres=` with an empty value
        // disappears when `extra` is parsed, so an artist Spotify has no genres
        // for and an artist we never asked about read identically downstream —
        // which is how `withComposers` came to be dead for everybody without
        // anything reporting it. Measured 2026-08-14: 0 of 80 artist rows on a
        // real account carried one.
        //
        // Assembled as pairs and joined, rather than appended to a string that
        // may now be empty: `";subject=…"` onto `""` leaves a leading separator
        // and an empty first pair for whatever parses it.
        var pairs: [String] = []
        if !genres.isEmpty { pairs.append("genres=\(genres.joined(separator: "|"))") }
        // The rule, not a copy of it — even though on an artist row it can only
        // resolve to the performer, since Spotify returns no composer anywhere.
        let subject = Ontology.musicSubject(genres: genres, composer: nil, performer: name)
        if !subject.isEmpty { pairs.append("subject=\(subject)") }
        pairs.append("resource_type=artist")
        if let rank { pairs.append("rank=\(rank)") }
        let extra = pairs.joined(separator: ";")

        return record(
            dataType: dataType,
            itemID: artist["id"] as? String ?? "",
            name: name,
            creator: name,
            detail: "",
            extra: extra
        )
    }

    /// A saved album — Spotify's `library_album`.
    ///
    /// `creator` is pipe-joined across every credit exactly as a track's is, so
    /// `MusicPayload.creditedArtists` splits it back apart and the subject is
    /// the first name rather than the joined string.
    private func albumRecord(_ album: [String: Any], added: String) -> DistilledRecord {
        let names = (album["artists"] as? [[String: Any]] ?? [])
            .compactMap { $0["name"] as? String }
        var extra = "resource_type=album"
        // Stated by the album object and by nothing else Spotify returns — a
        // track carries no genre at all, which is the gap
        // `ontology.external_entities` exists to fill.
        let genres = (album["genres"] as? [String] ?? []).filter { !$0.isEmpty }
        if !genres.isEmpty { extra += ";genres=\(genres.joined(separator: "|"))" }
        if let released = album["release_date"] as? String, !released.isEmpty {
            extra += ";released=\(released)"
        }
        if let artwork = artworkURL(of: album) { extra += ";artwork=\(artwork)" }
        if !added.isEmpty { extra += ";\(added)" }
        let subject = Ontology.musicSubject(
            genres: genres, composer: nil, performer: names.first ?? ""
        )
        if !subject.isEmpty { extra += ";subject=\(subject)" }

        return record(
            dataType: "saved_album",
            itemID: album["id"] as? String ?? "",
            name: album["name"] as? String ?? "",
            creator: names.joined(separator: "|"),
            detail: "",
            extra: extra
        )
    }

    /// `added_at` under the name the rest of the schema already uses.
    ///
    /// **`date_added=`, not `added_at=`.** `MusicPayload` reads `date_added` and
    /// `AppleMusicDistiller` writes it; a third spelling would be a field
    /// present in the record and invisible to everything downstream, which is
    /// the defect `keywords` against `tags` already cost this project once.
    private func added(from item: [String: Any]) -> String {
        guard let value = item["added_at"] as? String, !value.isEmpty else { return "" }
        return "date_added=\(value)"
    }

    /// The largest artwork Spotify offers for a track's album or an album.
    ///
    /// `images` is ordered widest first, which is what Apple's 300×300 template
    /// substitution reaches for by another route. Kept because the card draws a
    /// cover and a Spotify row has never had one — `MediaHighlights`,
    /// `MusicHighlights` and `Ontology` all read `artwork` and all found it nil
    /// for every Spotify row.
    private func artworkURL(of container: [String: Any]) -> String? {
        let images = container["images"] as? [[String: Any]] ?? []
        return images.first?["url"] as? String
    }

    /// The album's release date, as Spotify states it.
    ///
    /// Returned verbatim rather than normalised to a year. `release_date_precision`
    /// says whether the string is `1998`, `1998-12` or `1998-12-19`, and every
    /// reader downstream takes `[:4]` — so trimming here would throw away a
    /// month and a day that cost nothing to keep, in a store that cannot be
    /// rewritten.
    private func releaseDate(of track: [String: Any]) -> String? {
        (track["album"] as? [String: Any])?["release_date"] as? String
    }

    /// How many items a playlist holds, under whichever name states it.
    ///
    /// `items` first, `tracks` second. Spotify deprecated `tracks` in favour of
    /// `items` and in practice stopped populating it — every playlist this app
    /// has ever collected carries `track_count=0` because of it — but the
    /// deprecated key is documented as still present, so it is read rather than
    /// dropped. Neither being there is 0, which is what the old code always
    /// answered.
    private func playlistTotal(_ playlist: [String: Any]) -> Int {
        let container = (playlist["items"] as? [String: Any])
            ?? (playlist["tracks"] as? [String: Any])
        return container?["total"] as? Int ?? 0
    }

    private func albumName(of track: [String: Any]) -> String {
        (track["album"] as? [String: Any])?["name"] as? String ?? ""
    }

    private func record(
        dataType: String,
        itemID: String,
        name: String,
        creator: String,
        detail: String,
        extra: String
    ) -> DistilledRecord {
        DistilledRecord(
            source: "spotify",
            dataType: dataType,
            itemID: itemID,
            name: name,
            creator: creator,
            detail: detail,
            extra: extra,
            collectedAt: Date()
        )
    }
}
