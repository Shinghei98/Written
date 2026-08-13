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
            /// `playlistItems.contentDetails` — the video's own id and the date
            /// it was published, as against `snippet.publishedAt`, which is when
            /// it was *added to the playlist*. Two different facts that the
            /// snippet alone cannot tell apart.
            let videoId: String?
            let videoPublishedAt: String?
            /// `subscriptions.contentDetails`. `newItemCount` is what YouTube
            /// says is unwatched, which is the closest this API comes to saying
            /// whether a subscription is live or abandoned — and watch history
            /// is not reachable at all, so it is the only such signal here.
            let totalItemCount: Int?
            let newItemCount: Int?
        }
        /// Wikipedia and Freebase topic URLs — YouTube's own classification of
        /// what a video is *about*, which is a different and better question
        /// than what category it was filed under.
        struct TopicDetails: Decodable {
            let topicCategories: [String]?
        }
        /// **Statistics are the one class III.E.4 lets outlive thirty days**, so
        /// these are the only fields here that a sweep does not have to take —
        /// and until now none were kept for a *video*, only for a channel.
        struct Statistics: Decodable {
            let subscriberCount: String?
            let viewCount: String?
            let likeCount: String?
            let videoCount: String?
        }
        /// **Uploader-supplied channel keywords** — the same class as
        /// `snippet.tags`, which `0078` licensed by name as *reading a supplied
        /// label*. It reaches the half of the corpus tags cannot:
        /// `subscriptions.list` carries no `topicDetails`, so subscriptions
        /// arrive with far less than liked videos do.
        struct BrandingSettings: Decodable {
            struct Channel: Decodable {
                let keywords: String?
            }
            let channel: Channel?
        }
        let id: String?
        let snippet: Snippet?
        let contentDetails: ContentDetails?
        let topicDetails: TopicDetails?
        let statistics: Statistics?
        let brandingSettings: BrandingSettings?
    }

    // MARK: - Distillation

    func distill() async throws -> [DistilledRecord] {
        let token = try await oauth.validAccessToken()
        var records: [DistilledRecord] = []

        // 1. Subscriptions — the channels this user chose to follow.
        let subscriptions = try await fetchAllPages(
            token: token,
            path: "subscriptions",
            query: ["part": "snippet,contentDetails", "mine": "true", "maxResults": "50"]
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
        let channelFacts = await channelFacts(token: token, channelIDs: subscribedIDs)

        records += subscriptions.map { item in
            let channelID = item.snippet?.resourceId?.channelId ?? item.id ?? ""
            // Pulled out as locals rather than inlined into the array literal:
            // Swift's type checker times out on long heterogeneous lists of
            // optionals, and this one was already close to the edge.
            let subscribedAt = "subscribed_at=\(item.snippet?.publishedAt ?? "")"
            let artwork: String? = item.snippet?.thumbnails?.url.map { "artwork=\($0)" }
            let facts = channelFacts[channelID]
            let topics: String? = facts.map(\.topics).flatMap {
                $0.isEmpty ? nil : "topics=" + $0.joined(separator: "|")
            }
            // **Why a size is worth keeping at all.** It is what tells an
            // official artist channel from somebody's repost account without
            // deciding what *kind* of channel it is — which is `channel_role`,
            // is "the type of a channel" in III.E.4.h's own words, and is not
            // ours to compute. A published number compared against a threshold
            // is read; a label applied to a channel is inferred.
            let subscribers: String? = facts?.subscriberCount.map { "subscriber_count=\($0)" }
            // Pipe-joined to match `tags=` on liked videos, so one parser serves
            // both and the resolver's whole-tag rule reads the same shape from
            // either. Capped for the reason every list here is capped.
            let keywords: String? = facts.map(\.keywords).flatMap {
                $0.isEmpty ? nil : "keywords=" + $0.prefix(12).joined(separator: "|")
            }
            let items: String? = item.contentDetails?.totalItemCount.map { "total_items=\($0)" }
            let unwatched: String? = item.contentDetails?.newItemCount.map { "new_items=\($0)" }
            return record(
                dataType: "subscription",
                itemID: channelID,
                name: item.snippet?.title ?? "",
                creator: item.snippet?.title ?? "",
                detail: snippetPrefix(item.snippet?.description),
                // The channel's own avatar, which is what a subscription's
                // thumbnails are.
                // Annotated `[String?]` rather than inferred. The list gained a
                // fourth element and the note above is explicit that it was
                // already close to the type checker's limit; naming the element
                // type leaves it nothing to solve.
                extra: joined([subscribedAt, artwork, topics, subscribers,
                               keywords, items, unwatched] as [String?])
            )
        }

        // 2. Liked videos.
        let liked = try await fetchAllPages(
            token: token,
            path: "videos",
            query: ["part": "snippet,contentDetails,topicDetails,statistics",
                    "myRating": "like", "maxResults": "50"]
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
                    // **Statistics, so these outlive the thirty-day sweep** —
                    // III.E.4 permits storing statistics beyond 30 days where a
                    // title or a channel name must be refreshed or deleted. A
                    // liked video kept none until now, only channels did.
                    item.statistics?.viewCount.map { "view_count=\($0)" },
                    item.statistics?.likeCount.map { "like_count=\($0)" },
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
                query: ["part": "snippet,contentDetails",
                        "playlistId": playlistID, "maxResults": "50"]
            ) else { continue }

            records += items.map { item in
                record(
                    dataType: "playlist_item",
                    itemID: item.snippet?.resourceId?.videoId ?? item.id ?? "",
                    name: item.snippet?.title ?? "",
                    creator: item.snippet?.channelTitle ?? "",
                    detail: "playlist=\(playlistName)",
                    // **`added_at` and `published_at` are two different dates
                    // and the snippet only tells you the first.**
                    // `snippet.publishedAt` on a playlist item is when it was
                    // *added to the playlist*; the video's own publication date
                    // is in `contentDetails`, and without it a 2009 song added
                    // last week reads as a 2026 one — which is exactly what the
                    // decade and scene concepts are computed from.
                    extra: joined([
                        "added_at=\(item.snippet?.publishedAt ?? "")",
                        item.contentDetails?.videoId.map { "video_id=\($0)" },
                        item.contentDetails?.videoPublishedAt.map { "published_at=\($0)" }
                    ] as [String?])
                )
            }
        }

        return records
    }

    // MARK: - Helpers

    /// What one `channels.list` call answers about a channel.
    ///
    /// **Two facts from one request rather than two requests.** The call was
    /// already being made for `topicDetails`; `statistics` is another `part` on
    /// it, which costs no extra quota unit and is exactly the "extra `part=` on
    /// a request already being made" the extraction rule licenses by name.
    struct ChannelFacts {
        let topics: [String]
        /// **A statistic, and that word is load-bearing.** III.E.4 permits
        /// storing Analytics data, Reporting data and *statistics* beyond 30
        /// calendar days, where titles and channel names must be refreshed or
        /// deleted. A subscriber count is a statistic by that clause's own
        /// example, so unlike everything else this distiller keeps about a
        /// channel, it is not on the thirty-day clock.
        ///
        /// Kept as YouTube sends it — a string — because it arrives as one and
        /// because a count that overflows an `Int` on some future channel should
        /// fail at whoever parses it rather than here.
        let subscriberCount: String?
        /// **Uploader-supplied keywords, which is why they may be kept at all.**
        /// `0078` recorded the determination for `snippet.tags`: matching a whole
        /// tag against a controlled vocabulary is *reading a supplied label*, not
        /// inferring one. These are the same field one level up, and they reach
        /// the channels tags cannot — a subscription carries no video snippet.
        ///
        /// Already split; see `keywords(from:)` for why that is not `split(" ")`.
        let keywords: [String]
    }

    /// YouTube returns channel keywords as **one space-delimited string with
    /// quoted phrases** — `kpop "girl group" dance` is three keywords, not four.
    ///
    /// Splitting on whitespace would turn every multi-word keyword into
    /// fragments, and a fragment is exactly what `0078`'s guards exist to keep
    /// out: `creator:yg` matched in that measurement because two characters match
    /// noise in any corpus. Whole keywords in, or nothing.
    static func keywords(from raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        var out: [String] = []
        var current = ""
        var quoted = false
        for character in raw {
            switch character {
            case "\"":
                quoted.toggle()
            case " " where !quoted:
                if !current.isEmpty { out.append(current); current = "" }
            default:
                current.append(character)
            }
        }
        if !current.isEmpty { out.append(current) }
        // An unterminated quote leaves the tail in `current`, which is kept
        // rather than dropped: a malformed keyword string is the uploader's
        // doing and losing the last keyword silently is worse than keeping one
        // that reads oddly.
        return out
    }

    /// YouTube's own topics and subscriber count for a set of channels.
    ///
    /// `channels.list` takes up to 50 ids per call and costs 1 unit each, so a
    /// 200-channel subscription list is 4 units on top of a ~185-unit distill —
    /// and asking for `statistics` alongside `topicDetails` adds no unit at all,
    /// because quota is charged per call rather than per part.
    ///
    /// **Failure is silent on purpose, and this is the one place in this file
    /// where that is right.** A channel with no topics simply goes unlabelled;
    /// the alternative is failing a whole distillation over an enrichment. It
    /// answers an empty dictionary rather than throwing, and the caller treats
    /// a missing entry and an empty entry identically — both mean "YouTube did
    /// not say", which is a different thing from "we decided not to look".
    /// Nothing downstream guesses in either case.
    private func channelFacts(token: String, channelIDs: [String]) async -> [String: ChannelFacts] {
        var facts: [String: ChannelFacts] = [:]

        for batch in stride(from: 0, to: channelIDs.count, by: 50) {
            let ids = Array(channelIDs[batch..<min(batch + 50, channelIDs.count)])
            guard var components = URLComponents(string: "\(Self.baseURL)/channels") else { continue }
            components.queryItems = [
                URLQueryItem(name: "part", value: "topicDetails,statistics,brandingSettings"),
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
                guard let id = item.id else { continue }
                // Wikipedia URLs in, the topic itself out — same shape the liked
                // videos already store, so one parser serves both.
                let names = (item.topicDetails?.topicCategories ?? [])
                    .compactMap { URL(string: $0)?.lastPathComponent }
                let subscribers = item.statistics?.subscriberCount
                let words = Self.keywords(from: item.brandingSettings?.channel?.keywords)
                // **Recorded when either fact is present, not only when both
                // are.** The guard used to require `topicCategories` and skip
                // the channel otherwise; keeping that would have thrown away the
                // subscriber count for every untagged channel — which is 8 of
                // 146 on a real account, and precisely the channels a size
                // threshold exists to judge.
                guard !names.isEmpty || subscribers != nil || !words.isEmpty else { continue }
                facts[id] = ChannelFacts(
                    topics: names, subscriberCount: subscribers, keywords: words
                )
            }
        }
        return facts
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
