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
            /// The channel a *video* belongs to. Liked videos name their channel
            /// but nothing else identifies it, so without this the dashboard has
            /// to join likes to subscriptions on the title string — which breaks
            /// the moment a channel is renamed.
            let channelId: String?
            let publishedAt: String?
            let resourceId: ResourceID?
            let thumbnails: Thumbnails?
            /// YouTube's own category for a video — 10 is Music, 20 Gaming, 28
            /// Science & Technology. **The most ontology-shaped field this API
            /// offers**, and it was already inside the snippet being decoded
            /// and thrown away at the parse.
            let categoryId: String?
            /// Uploader-supplied keywords. Returned to the video's owner for
            /// certain; whether a third party sees them is **unverified**, so
            /// this is decoded and recorded when present rather than relied on.
            let tags: [String]?
        }
        struct ResourceID: Decodable {
            let channelId: String?
            let videoId: String?
        }
        /// `default` is a keyword, and the small size is 88px — too soft for a
        /// 40pt tile at 3×. Medium and high are enough.
        struct Thumbnails: Decodable {
            let medium: Thumbnail?
            let high: Thumbnail?

            var url: String? { medium?.url ?? high?.url }
        }
        struct Thumbnail: Decodable {
            let url: String?
        }
        struct ContentDetails: Decodable {
            let itemCount: Int?
            /// ISO 8601, "PT12M31S". Kept raw: parsing it here would invent a
            /// unit the API did not state, and `extra` is where platform quirks
            /// belong.
            let duration: String?
        }
        /// Wikipedia and Freebase topic URLs — YouTube's own classification of
        /// what a video is *about*, which is a different and better question
        /// than what category it was filed under.
        struct TopicDetails: Decodable {
            let topicCategories: [String]?
        }
        struct Statistics: Decodable {
            let subscriberCount: String?
        }
        let id: String?
        let snippet: Snippet?
        let contentDetails: ContentDetails?
        let topicDetails: TopicDetails?
        let statistics: Statistics?
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
        // **What each channel is about, in YouTube's own words.**
        // `subscriptions.list` has no `topicDetails` part, so this is a second
        // call against `channels.list` — 1 unit per 50 channels, and squarely
        // the "second query against a library already open" the extraction rule
        // prefers over guessing.
        //
        // It is not an enrichment for its own sake. The compliance guide's
        // don't-list includes *"Infer or estimate the content category/type of a
        // video or channel"*, and the heading over it is *"Only offer metrics
        // that are available via YouTube's API services"* — so the category has
        // to come from YouTube rather than from a term list of ours. Liked
        // videos already carried theirs; subscriptions arrived unlabelled and
        // were being classified by name.
        let subscribedIDs = subscriptions.compactMap { $0.snippet?.resourceId?.channelId }
        let channelTopics = await channelTopics(token: token, channelIDs: subscribedIDs)

        records += subscriptions.map { item in
            let channelID = item.snippet?.resourceId?.channelId ?? item.id ?? ""
            // Pulled out as locals rather than inlined into the array literal:
            // Swift's type checker times out on long heterogeneous lists of
            // optionals, and this one was already close to the edge.
            let subscribedAt = "subscribed_at=\(item.snippet?.publishedAt ?? "")"
            let artwork: String? = item.snippet?.thumbnails?.url.map { "artwork=\($0)" }
            let topics: String? = channelTopics[channelID].map { "topics=" + $0.joined(separator: "|") }
            return record(
                dataType: "subscription",
                itemID: channelID,
                name: item.snippet?.title ?? "",
                creator: item.snippet?.title ?? "",
                detail: snippetPrefix(item.snippet?.description),
                // The channel's own avatar, which is what a subscription's
                // thumbnails are.
                extra: joined([subscribedAt, artwork, topics])
            )
        }

        // 2. Liked videos.
        let liked = try await fetchAllPages(
            token: token,
            path: "videos",
            query: ["part": "snippet,contentDetails,topicDetails", "myRating": "like", "maxResults": "50"]
        )
        records += liked.map { item in
            record(
                dataType: "liked_video",
                itemID: item.id ?? "",
                name: item.snippet?.title ?? "",
                creator: item.snippet?.channelTitle ?? "",
                detail: snippetPrefix(item.snippet?.description),
                // `artwork` here is the video's still, not the channel's avatar
                // — the only image this endpoint carries. It stands in for the
                // channel the way an album cover stands in for an artist.
                extra: joined([
                    "published_at=\(item.snippet?.publishedAt ?? "")",
                    item.snippet?.channelId.map { "channel_id=\($0)" },
                    item.snippet?.thumbnails?.url.map { "artwork=\($0)" },
                    item.snippet?.categoryId.map { "category_id=\($0)" },
                    item.contentDetails?.duration.map { "duration=\($0)" },
                    // Last path component of each Wikipedia URL — the topic
                    // itself rather than a link to it, which is what a keyword
                    // stage would want and is shorter to store.
                    item.topicDetails?.topicCategories.map {
                        "topics=" + $0.compactMap { URL(string: $0)?.lastPathComponent }.joined(separator: "|")
                    },
                    (item.snippet?.tags?.isEmpty == false)
                        ? "tags=" + (item.snippet?.tags ?? []).prefix(12).joined(separator: "|")
                        : nil
                ])
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

    /// YouTube's own topic categories for a set of channels, keyed by channel id.
    ///
    /// `channels.list` takes up to 50 ids per call and costs 1 unit each, so a
    /// 200-channel subscription list is 4 units on top of a ~185-unit distill.
    ///
    /// **Failure is silent on purpose, and this is the one place in this file
    /// where that is right.** A channel with no topics simply goes unlabelled;
    /// the alternative is failing a whole distillation over an enrichment. It
    /// answers an empty dictionary rather than throwing, and the caller treats
    /// a missing entry and an empty entry identically — both mean "YouTube did
    /// not say", which is a different thing from "we decided not to look".
    /// Nothing downstream guesses in either case.
    private func channelTopics(token: String, channelIDs: [String]) async -> [String: [String]] {
        var topics: [String: [String]] = [:]

        for batch in stride(from: 0, to: channelIDs.count, by: 50) {
            let ids = Array(channelIDs[batch..<min(batch + 50, channelIDs.count)])
            guard var components = URLComponents(string: "\(Self.baseURL)/channels") else { continue }
            components.queryItems = [
                URLQueryItem(name: "part", value: "topicDetails"),
                URLQueryItem(name: "id", value: ids.joined(separator: ",")),
                URLQueryItem(name: "maxResults", value: "50")
            ]
            guard let url = components.url else { continue }

            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let page = try? JSONDecoder().decode(Page.self, from: data)
            else { continue }

            for item in page.items {
                guard let id = item.id,
                      let categories = item.topicDetails?.topicCategories
                else { continue }
                // Wikipedia URLs in, the topic itself out — same shape the liked
                // videos already store, so one parser serves both.
                let names = categories.compactMap { URL(string: $0)?.lastPathComponent }
                if !names.isEmpty { topics[id] = names }
            }
        }
        return topics
    }

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

    /// `extra` pairs, skipping the ones the API didn't give us — an empty
    /// `artwork=` is worse than no key at all, since readers treat a present
    /// key as a value.
    private func joined(_ pairs: [String?]) -> String {
        pairs.compactMap { $0 }.joined(separator: ";")
    }

    private func snippetPrefix(_ text: String?) -> String {
        guard let text, !text.isEmpty else { return "" }
        return String(text.replacingOccurrences(of: "\n", with: " ").prefix(120))
    }
}
