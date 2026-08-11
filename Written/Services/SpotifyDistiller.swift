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
        records += topArtists.enumerated().map { index, artist in
            artistRecord(artist, dataType: "top_artist", detail: "rank=\(index + 1)")
        }

        // 2. Top tracks.
        let topTracks = try await fetchAllPages(
            token: token,
            path: "/v1/me/top/tracks?time_range=medium_term&limit=50",
            itemsKey: ["items"]
        )
        records += topTracks.enumerated().map { index, track in
            trackRecord(track, dataType: "top_track", detail: "rank=\(index + 1)")
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

        // 4. Followed artists (cursor pagination nested under "artists").
        let followed = try await fetchAllPages(
            token: token,
            path: "/v1/me/following?type=artist&limit=50",
            itemsKey: ["artists", "items"]
        )
        records += followed.map { artist in
            artistRecord(artist, dataType: "followed_artist", detail: "")
        }

        // 5. Playlists, then the tracks inside each.
        let playlists = try await fetchAllPages(
            token: token,
            path: "/v1/me/playlists?limit=50",
            itemsKey: ["items"]
        )
        records += playlists.map { playlist in
            record(
                dataType: "playlist",
                itemID: playlist["id"] as? String ?? "",
                name: playlist["name"] as? String ?? "",
                creator: (playlist["owner"] as? [String: Any])?["display_name"] as? String ?? "",
                detail: String((playlist["description"] as? String ?? "").prefix(120)),
                extra: "track_count=\((playlist["tracks"] as? [String: Any])?["total"] as? Int ?? 0)"
            )
        }

        for playlist in playlists.prefix(AppConfig.maxPlaylistsExpanded) {
            guard let playlistID = playlist["id"] as? String else { continue }
            let playlistName = playlist["name"] as? String ?? playlistID
            // Best effort per playlist; one bad playlist must not sink the distill.
            guard let items = try? await fetchAllPages(
                token: token,
                path: "/v1/playlists/\(playlistID)/tracks?limit=100",
                itemsKey: ["items"]
            ) else { continue }

            records += items.compactMap { item in
                guard let track = item["track"] as? [String: Any] else { return nil }
                return trackRecord(track, dataType: "playlist_item", detail: "playlist=\(playlistName)")
            }
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
        detail: String
    ) -> DistilledRecord {
        let name = artist["name"] as? String ?? ""
        let genres = (artist["genres"] as? [String] ?? [])
        var extra = "genres=\(genres.joined(separator: "|"))"
        // The rule, not a copy of it — even though on an artist row it can only
        // resolve to the performer, since Spotify returns no composer anywhere.
        let subject = Ontology.musicSubject(genres: genres, composer: nil, performer: name)
        if !subject.isEmpty { extra += ";subject=\(subject)" }
        extra += ";resource_type=artist"

        return record(
            dataType: dataType,
            itemID: artist["id"] as? String ?? "",
            name: name,
            creator: name,
            detail: detail,
            extra: extra
        )
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
