import Foundation

/// Distills the signals listed for YouTube in written_api.xlsx:
/// subscriptions, liked videos, playlists (and their contents).
struct YouTubeDistiller {

    let oauth: OAuthPKCEService

    private static let baseURL = "https://www.googleapis.com/youtube/v3"

    // MARK: - API response shapes (only the fields we distill)

    private struct Page: Decodable {
        let nextPageToken: String?
        let items: [Item]
    }

    private struct Item: Decodable {
        struct Snippet: Decodable {
            let title: String?
            let description: String?
            let channelTitle: String?
            let publishedAt: String?
            let resourceId: ResourceID?
        }
        struct ResourceID: Decodable {
            let channelId: String?
            let videoId: String?
        }
        struct ContentDetails: Decodable {
            let itemCount: Int?
        }
        let id: String?
        let snippet: Snippet?
        let contentDetails: ContentDetails?
    }

    // MARK: - Distillation

    func distill() async throws -> [DistilledRecord] {
        let token = try await oauth.validAccessToken()
        var records: [DistilledRecord] = []

        // 1. Subscriptions — the channels this user chose to follow.
        let subscriptions = try await fetchAllPages(
            token: token,
            path: "subscriptions",
            query: ["part": "snippet", "mine": "true", "maxResults": "50"]
        )
        records += subscriptions.map { item in
            record(
                dataType: "subscription",
                itemID: item.snippet?.resourceId?.channelId ?? item.id ?? "",
                name: item.snippet?.title ?? "",
                creator: item.snippet?.title ?? "",
                detail: snippetPrefix(item.snippet?.description),
                extra: "subscribed_at=\(item.snippet?.publishedAt ?? "")"
            )
        }

        // 2. Liked videos.
        let liked = try await fetchAllPages(
            token: token,
            path: "videos",
            query: ["part": "snippet", "myRating": "like", "maxResults": "50"]
        )
        records += liked.map { item in
            record(
                dataType: "liked_video",
                itemID: item.id ?? "",
                name: item.snippet?.title ?? "",
                creator: item.snippet?.channelTitle ?? "",
                detail: snippetPrefix(item.snippet?.description),
                extra: "published_at=\(item.snippet?.publishedAt ?? "")"
            )
        }

        // 3. Playlists the user created, then the videos inside each.
        let playlists = try await fetchAllPages(
            token: token,
            path: "playlists",
            query: ["part": "snippet,contentDetails", "mine": "true", "maxResults": "50"]
        )
        records += playlists.map { item in
            record(
                dataType: "playlist",
                itemID: item.id ?? "",
                name: item.snippet?.title ?? "",
                creator: item.snippet?.channelTitle ?? "",
                detail: snippetPrefix(item.snippet?.description),
                extra: "item_count=\(item.contentDetails?.itemCount.map(String.init) ?? "")"
            )
        }

        for playlist in playlists.prefix(AppConfig.maxPlaylistsExpanded) {
            guard let playlistID = playlist.id else { continue }
            let playlistName = playlist.snippet?.title ?? playlistID
            // Best effort per playlist; one bad playlist must not sink the distill.
            guard let items = try? await fetchAllPages(
                token: token,
                path: "playlistItems",
                query: ["part": "snippet", "playlistId": playlistID, "maxResults": "50"]
            ) else { continue }

            records += items.map { item in
                record(
                    dataType: "playlist_item",
                    itemID: item.snippet?.resourceId?.videoId ?? item.id ?? "",
                    name: item.snippet?.title ?? "",
                    creator: item.snippet?.channelTitle ?? "",
                    detail: "playlist=\(playlistName)",
                    extra: "added_at=\(item.snippet?.publishedAt ?? "")"
                )
            }
        }

        return records
    }

    // MARK: - Helpers

    private func fetchAllPages(
        token: String,
        path: String,
        query: [String: String]
    ) async throws -> [Item] {
        var items: [Item] = []
        var pageToken: String?

        for _ in 0..<AppConfig.maxPagesPerEndpoint {
            var components = URLComponents(string: "\(Self.baseURL)/\(path)")!
            var queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
            if let pageToken {
                queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            components.queryItems = queryItems

            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? ""
                throw NSError(
                    domain: "YouTubeDistiller",
                    code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                    userInfo: [NSLocalizedDescriptionKey: "YouTube API error on \(path): \(body.prefix(200))"]
                )
            }

            let page = try JSONDecoder().decode(Page.self, from: data)
            items += page.items
            guard let next = page.nextPageToken else { break }
            pageToken = next
        }
        return items
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
            source: "youtube",
            dataType: dataType,
            itemID: itemID,
            name: name,
            creator: creator,
            detail: detail,
            extra: extra,
            collectedAt: Date()
        )
    }

    private func snippetPrefix(_ text: String?) -> String {
        guard let text, !text.isEmpty else { return "" }
        return String(text.replacingOccurrences(of: "\n", with: " ").prefix(120))
    }
}
