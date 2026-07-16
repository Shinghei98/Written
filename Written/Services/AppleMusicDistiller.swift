import Foundation
import MusicKit

/// Distills the signals listed for Apple Music in written_api.xlsx:
/// library songs / albums / artists / music videos, user playlists and their
/// contents, recently added, recently played, heavy rotation, personalized
/// recommendations, and like/dislike ratings.
///
/// Friction profile: a single system permission dialog (no login — the
/// device's Apple Music account is used), then everything is fetched silently
/// through MusicKit, which manages the developer and user tokens itself.
struct AppleMusicDistiller {

    enum MusicError: LocalizedError {
        case notAuthorized

        var errorDescription: String? {
            "Apple Music access was not granted. You can enable it in Settings → Written."
        }
    }

    private static let apiBase = "https://api.music.apple.com"

    func distill() async throws -> [DistilledRecord] {
        let status = await MusicAuthorization.request()
        guard status == .authorized else { throw MusicError.notAuthorized }

        var records: [DistilledRecord] = []
        var librarySongIDs: [String] = []

        // 1. Library songs (also collect ids for the ratings pass).
        let songs = try await fetchAllPages(path: "/v1/me/library/songs?limit=100")
        librarySongIDs = songs.compactMap { $0["id"] as? String }
        records += songs.map { makeRecord(dataType: "library_song", resource: $0) }

        // 2–4. Library albums, artists, music videos.
        records += (try await fetchAllPages(path: "/v1/me/library/albums?limit=100"))
            .map { makeRecord(dataType: "library_album", resource: $0) }
        records += (try await fetchAllPages(path: "/v1/me/library/artists?limit=100"))
            .map { makeRecord(dataType: "library_artist", resource: $0) }
        if let videos = try? await fetchAllPages(path: "/v1/me/library/music-videos?limit=100") {
            records += videos.map { makeRecord(dataType: "library_music_video", resource: $0) }
        }

        // 5. Playlists, then the tracks inside each.
        let playlists = try await fetchAllPages(path: "/v1/me/library/playlists?limit=100")
        records += playlists.map { makeRecord(dataType: "library_playlist", resource: $0) }

        for playlist in playlists.prefix(AppConfig.maxPlaylistsExpanded) {
            guard let playlistID = playlist["id"] as? String else { continue }
            let playlistName = attribute("name", of: playlist)
            // Best effort: empty playlists return 404, which must not sink the distill.
            guard let tracks = try? await fetchAllPages(
                path: "/v1/me/library/playlists/\(playlistID)/tracks?limit=100"
            ) else { continue }
            records += tracks.map {
                makeRecord(dataType: "playlist_item", resource: $0, detailOverride: "playlist=\(playlistName)")
            }
        }

        // 6. Recently added (endpoint max limit is 25 per page).
        if let recentlyAdded = try? await fetchAllPages(path: "/v1/me/library/recently-added?limit=25") {
            records += recentlyAdded.map { makeRecord(dataType: "recently_added", resource: $0) }
        }

        // 7. Recently played tracks (endpoint max limit is 30).
        if let recentlyPlayed = try? await fetchAllPages(path: "/v1/me/recent/played/tracks?limit=30") {
            records += recentlyPlayed.map { makeRecord(dataType: "recently_played", resource: $0) }
        }

        // 8. Heavy rotation — strongest current-taste signal.
        if let heavyRotation = try? await fetchAllPages(path: "/v1/me/history/heavy-rotation?limit=10") {
            records += heavyRotation.map { makeRecord(dataType: "heavy_rotation", resource: $0) }
        }

        // 9. Personalized recommendations (items live in relationships.contents).
        if let recommendations = try? await fetchAllPages(path: "/v1/me/recommendations?limit=30") {
            for recommendation in recommendations {
                let reason = attribute("title", of: recommendation)
                let contents = ((recommendation["relationships"] as? [String: Any])?["contents"] as? [String: Any])?["data"] as? [[String: Any]] ?? []
                records += contents.map {
                    makeRecord(dataType: "recommendation", resource: $0, detailOverride: "shelf=\(reason)")
                }
            }
        }

        // 10. Like/dislike ratings for library songs, in id batches (best effort;
        // the endpoint only returns entries for songs the user actually rated).
        for batch in librarySongIDs.chunked(into: 100) {
            let ids = batch.joined(separator: ",")
            guard let rated = try? await fetchAllPages(
                path: "/v1/me/ratings/library-songs?ids=\(ids)"
            ) else { continue }
            records += rated.map { resource in
                let value = (resource["attributes"] as? [String: Any])?["value"] as? Int ?? 0
                return DistilledRecord(
                    source: "apple_music",
                    dataType: "rating",
                    itemID: resource["id"] as? String ?? "",
                    name: "",
                    creator: "",
                    detail: value > 0 ? "liked" : "disliked",
                    extra: "value=\(value)",
                    collectedAt: Date()
                )
            }
        }

        return records
    }

    // MARK: - Fetching

    /// Fetches a paginated Apple Music API endpoint, following `next` links.
    /// Resources are returned as raw dictionaries because each endpoint mixes
    /// resource types (songs, albums, playlists, stations...).
    private func fetchAllPages(path: String) async throws -> [[String: Any]] {
        var resources: [[String: Any]] = []
        var nextPath: String? = path

        for _ in 0..<AppConfig.maxPagesPerEndpoint {
            guard let currentPath = nextPath,
                  let url = URL(string: Self.apiBase + currentPath)
            else { break }

            let request = MusicDataRequest(urlRequest: URLRequest(url: url))
            let response = try await request.response()

            guard let json = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else { break }
            resources += json["data"] as? [[String: Any]] ?? []
            nextPath = json["next"] as? String
            if nextPath == nil { break }
        }
        return resources
    }

    // MARK: - Normalization

    private func makeRecord(
        dataType: String,
        resource: [String: Any],
        detailOverride: String? = nil
    ) -> DistilledRecord {
        let name = attribute("name", of: resource).isEmpty
            ? attribute("title", of: resource)
            : attribute("name", of: resource)
        let creator = [attribute("artistName", of: resource), attribute("curatorName", of: resource)]
            .first { !$0.isEmpty } ?? ""

        var extras: [String] = []
        extras.append("resource_type=\(resource["type"] as? String ?? "")")
        if let attributes = resource["attributes"] as? [String: Any] {
            if let genres = attributes["genreNames"] as? [String], !genres.isEmpty {
                extras.append("genres=\(genres.joined(separator: "|"))")
            }
            if let dateAdded = attributes["dateAdded"] as? String {
                extras.append("date_added=\(dateAdded)")
            }
            if let lastPlayed = attributes["lastPlayedDate"] as? String {
                extras.append("last_played=\(lastPlayed)")
            }
            if let playCount = attributes["playCount"] as? Int {
                extras.append("play_count=\(playCount)")
            }
        }

        return DistilledRecord(
            source: "apple_music",
            dataType: dataType,
            itemID: resource["id"] as? String ?? "",
            name: name,
            creator: creator,
            detail: detailOverride ?? attribute("albumName", of: resource),
            extra: extras.joined(separator: ";"),
            collectedAt: Date()
        )
    }

    private func attribute(_ key: String, of resource: [String: Any]) -> String {
        (resource["attributes"] as? [String: Any])?[key] as? String ?? ""
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
