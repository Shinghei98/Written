import Foundation

/// Turns distilled media records into the channels the dashboard's media card
/// shows. Pure and stateless, like `MusicHighlights` and `TreeMetrics`.
enum MediaHighlights {

    struct Channel: Identifiable, Hashable {
        /// The platform's channel id where we have one; older records that
        /// predate `channel_id=` fall back to the name.
        var id: String { channelID.isEmpty ? name.lowercased() : channelID }
        let channelID: String
        let name: String
        /// Videos of theirs the user liked.
        let likes: Int
        let subscribed: Bool
        let artworkURL: URL?
        let score: Double
    }

    // MARK: - The ranking, which is a draft

    /// **Draft weights — the thing to argue about.**
    ///
    /// Likes are the measure and subscribing is the thumb on the scale, so a
    /// subscription multiplies rather than replaces: a channel the user liked 66
    /// videos from should not sit below one they subscribed to and never liked.
    /// Measured against the real export, 1.5 reorders the middle of the list
    /// without unseating the top — see the card and say whether that is the
    /// balance you want.
    static let subscribedMultiplier = 1.5

    /// What a subscription is worth on its own, so a channel with no likes still
    /// places above nothing. Deliberately about "one like": subscribing is a
    /// weaker signal than liking, not a stronger one.
    static let subscribedBase = 1.0

    /// **Recency, as a continuous decay rather than buckets.**
    ///
    /// Every like and every subscription is worth `0.5 ^ (age / halfLife)` of a
    /// fresh one — smooth, never negative, and with no cliff on a birthday.
    ///
    /// Two half-lives because the two acts differ in kind: a like is a reaction
    /// and ages quickly; a subscription is a standing arrangement, and one made
    /// in 2023 still says something now. Measured against the real export, likes
    /// run 2020–2026 with the mass in 2025–26, subscriptions 2014–2026 with the
    /// mass in 2023–24.
    static let likeHalfLifeDays = 548.0      // 18 months
    static let subscribedHalfLifeDays = 1095.0 // 3 years

    /// Age in days → its weight. Undated records weigh a full 1: we can't
    /// penalise what we can't date, and guessing old would bury them.
    static func recency(ageDays: Double?, halfLife: Double) -> Double {
        guard let ageDays, ageDays > 0 else { return 1 }
        return pow(0.5, ageDays / halfLife)
    }

    /// `weightedLikes` is the sum of each like's own recency weight, not a count
    /// — so ten likes on 2021 videos are worth less than three on this year's.
    static func score(weightedLikes: Double, subscribed: Bool, subscriptionRecency: Double) -> Double {
        weightedLikes * (subscribed ? subscribedMultiplier : 1)
            + (subscribed ? subscribedBase * subscriptionRecency : 0)
    }

    // MARK: - Ranking

    /// One video the user liked, with enough on it to say what it was about.
    struct LikedVideo: Hashable {
        let title: String
        let channel: String
        let artworkURL: URL?
        /// The description prefix the distiller kept. Thin, but it is often the
        /// only place a video says what it is when the title is a joke.
        let detail: String
    }

    /// Liked videos in the order YouTube returned them, newest like first.
    ///
    /// No ranking of our own, because there is nothing to rank on: likes carry
    /// no date (see the note in `topChannels`), so the API's own ordering —
    /// most recently liked — is strictly better information than anything we
    /// could compute from `published_at`.
    ///
    /// Returns a list rather than one video because the caller may have to walk
    /// past the first: see `Ontology`, where a second music item is no use next
    /// to a line that is already about music.
    static func topLikedVideos(in records: [DistilledRecord], limit: Int = 8) -> [LikedVideo] {
        var videos: [LikedVideo] = []
        var seen: Set<String> = []

        for record in media(in: records) where record.dataType == "liked_video" {
            let title = record.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, seen.insert(record.itemID.isEmpty ? title : record.itemID).inserted else { continue }

            videos.append(
                LikedVideo(
                    title: title,
                    channel: record.creator.trimmingCharacters(in: .whitespacesAndNewlines),
                    artworkURL: artworkURL(of: record),
                    detail: record.detail
                )
            )
            if videos.count == limit { break }
        }
        return videos
    }

    /// Every channel the user subscribes to, by name.
    ///
    /// Kept separate from `topChannels`, which ranks and truncates: the question
    /// here is not who they watch most but *what kinds of thing* they follow at
    /// all, so the whole list matters and a top six would throw away exactly the
    /// long tail that distinguishes one person's interests from another's.
    static func subscribedChannels(in records: [DistilledRecord]) -> [String] {
        media(in: records)
            .filter { $0.dataType == "subscription" }
            .map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Channels the user subscribes to and channels whose videos they liked,
    /// merged and ranked. Ties break on name so the order is stable.
    ///
    /// `now` is injectable so the decay can be checked against a fixed date
    /// rather than drifting with the clock.
    static func topChannels(in records: [DistilledRecord], limit: Int = 6, now: Date = Date()) -> [Channel] {
        var tallies: [String: Tally] = [:]
        /// Lets a liked video with no `channel_id` still find its subscription.
        var keyByName: [String: String] = [:]

        // Subscriptions first, so they own the key their likes will join on.
        for record in media(in: records) where record.dataType == "subscription" {
            let name = record.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let key = record.itemID.isEmpty ? name.lowercased() : record.itemID

            var tally = tallies[key] ?? Tally(name: name, channelID: record.itemID)
            tally.subscribed = true
            tally.name = name
            tally.subscriptionRecency = recency(
                ageDays: ageInDays(record.extraValue("subscribed_at"), from: now),
                halfLife: subscribedHalfLifeDays
            )
            // The channel's avatar beats a video still, so it wins even if a
            // liked video got here first.
            tally.artwork = artworkURL(of: record) ?? tally.artwork
            tallies[key] = tally
            keyByName[name.lowercased()] = key
        }

        for record in media(in: records) where record.dataType == "liked_video" {
            let name = record.creator.trimmingCharacters(in: .whitespacesAndNewlines)
            let channelID = record.extraValue("channel_id") ?? ""
            guard !name.isEmpty || !channelID.isEmpty else { continue }

            let key: String
            if !channelID.isEmpty {
                key = channelID
            } else {
                // Pre-`channel_id` records: the title is all we have.
                key = keyByName[name.lowercased()] ?? name.lowercased()
            }

            var tally = tallies[key] ?? Tally(name: name, channelID: channelID)
            tally.likes += 1
            // `liked_at` is what this wants and the API does not provide it —
            // no endpoint reports when a video was liked, and the liked-videos
            // playlist has been closed to third parties for years. `published_at`
            // stands in: it dates the *video*, which is a proxy for the like and
            // not the like itself. The key is read first so that if a source
            // ever does carry a real like date, the maths needs no change.
            let dated = record.extraValue("liked_at") ?? record.extraValue("published_at")
            tally.weightedLikes += recency(
                ageDays: ageInDays(dated, from: now),
                halfLife: likeHalfLifeDays
            )
            if tally.name.isEmpty { tally.name = name }
            if tally.artwork == nil { tally.artwork = artworkURL(of: record) }
            tallies[key] = tally
            if !name.isEmpty { keyByName[name.lowercased()] = key }
        }

        var ranked = tallies.values.map { tally in
            Channel(
                channelID: tally.channelID,
                name: tally.name,
                likes: tally.likes,
                subscribed: tally.subscribed,
                artworkURL: tally.artwork,
                score: score(
                    weightedLikes: tally.weightedLikes,
                    subscribed: tally.subscribed,
                    subscriptionRecency: tally.subscriptionRecency
                )
            )
        }
        ranked.sort { left, right in
            left.score == right.score ? left.name < right.name : left.score > right.score
        }
        return Array(ranked.prefix(limit))
    }

    // MARK: - Reading the records

    private struct Tally {
        var name: String
        var channelID: String
        /// The plain count, for display. The score uses `weightedLikes`.
        var likes = 0
        var weightedLikes = 0.0
        var subscribed = false
        var subscriptionRecency = 1.0
        var artwork: URL?
    }

    /// Days between an ISO 8601 timestamp and `now`, or `nil` if it can't be read.
    ///
    /// Both shapes appear in the data — `2025-12-12T09:01:40Z` and
    /// `2024-04-06T06:49:46.909445Z` — and the fractional one has six digits,
    /// which `withFractionalSeconds` will not parse. Trimming to the second is
    /// simpler than a second formatter, and nothing here needs sub-second
    /// precision on a scale of months.
    private static func ageInDays(_ timestamp: String?, from now: Date) -> Double? {
        guard let timestamp, !timestamp.isEmpty else { return nil }
        let trimmed: String
        if let dot = timestamp.firstIndex(of: ".") {
            trimmed = String(timestamp[timestamp.startIndex..<dot]) + "Z"
        } else {
            trimmed = timestamp
        }
        guard let date = isoFormatter.date(from: trimmed) else { return nil }
        return now.timeIntervalSince(date) / 86_400
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func media(in records: [DistilledRecord]) -> [DistilledRecord] {
        // Rows the user struck off are kept in the data with a note saying so,
        // and skipped by everything that counts.
        records.filter { Modality.media.sources.contains($0.source) && !$0.isRemovedByUser }
    }

    private static func artworkURL(of record: DistilledRecord) -> URL? {
        record.extraValue("artwork").flatMap(URL.init(string:))
    }
}
