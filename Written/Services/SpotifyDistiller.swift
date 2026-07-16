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
            record(
                dataType: "top_artist",
                itemID: artist["id"] as? String ?? "",
                name: artist["name"] as? String ?? "",
                creator: artist["name"] as? String ?? "",
                detail: "rank=\(index + 1)",
                extra: "genres=\((artist["genres"] as? [String] ?? []).joined(separator: "|"))"
            )
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
            record(
                dataType: "followed_artist",
                itemID: artist["id"] as? String ?? "",
                name: artist["name"] as? String ?? "",
                creator: artist["name"] as? String ?? "",
                detail: "",
                extra: "genres=\((artist["genres"] as? [String] ?? []).joined(separator: "|"))"
            )
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

        return records
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
        let artists = (track["artists"] as? [[String: Any]] ?? [])
            .compactMap { $0["name"] as? String }
            .joined(separator: "|")
        var extra = "album=\(albumName(of: track))"
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
