import Foundation
import MediaPlayer

/// Apple Podcasts, through the media library.
///
/// **The second source not in `written_api.xlsx`**, after Apple Calendar. What
/// earns its place is that a podcast is a long-form commitment: a person gives
/// a show hours of attention over weeks, and choosing to keep an episode on the
/// device is a stronger statement than a follow costs. It sits on Media beside
/// YouTube because it is the same kind of claim about attention.
///
/// **That it works at all was nearly missed.** `MPMediaQuery.podcasts()` was
/// probed on a phone whose Podcasts app had never been opened, returned zero,
/// and was written off. Following one show and downloading one episode turned
/// that into two. See the note in CLAUDE.md — a zero is a finding only when
/// something ought to have been found.
///
/// Friction, in the terms of the prime constraint: one system dialog, the same
/// one Apple Music raises, and no login at all.
struct PodcastDistiller {

    /// One store for the app's lifetime, for the reason `HealthKitDistiller`
    /// gives: a short-lived library object is a documented way to get a
    /// completion handler that never fires.
    private static let library = MPMediaLibrary.default()

    enum PodcastError: LocalizedError {
        case denied
        /// Authorized, and nothing came back.
        ///
        /// Named for the symptom, but unlike HealthKit this one can say *why*
        /// with confidence: the media library holds **downloaded** episodes, so
        /// somebody who streams everything genuinely has none. That is the
        /// common case rather than an edge, which is why it is a failure with a
        /// sentence rather than a branch that silently grows on nothing.
        case noDownloads

        var errorDescription: String? {
            switch self {
            case .denied:
                return "Written needs access to your media library to read Apple Podcasts. You can turn it on in Settings › Written."
            case .noDownloads:
                return "No downloaded podcast episodes found. Apple only lets apps see episodes saved to your phone — download one in Podcasts and try again."
            }
        }
    }

    func distill() async throws -> [DistilledRecord] {
        let status = await withCheckedContinuation { (continuation: CheckedContinuation<MPMediaLibraryAuthorizationStatus, Never>) in
            MPMediaLibrary.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else { throw PodcastError.denied }

        let query = MPMediaQuery.podcasts()
        let collections = query.collections ?? []
        let now = Date()

        var records: [DistilledRecord] = []

        // A show, once, however many of its episodes are on the phone. The
        // collection is what `MPMediaQuery.podcasts()` groups by, so this is
        // free — and it is the row the ontology stage wants, since the show is
        // the taste and the episode is the instance.
        for collection in collections.prefix(AppConfig.maxPodcastShows) {
            guard let item = collection.representativeItem,
                  let show = item.podcastTitle ?? item.albumTitle else { continue }

            var extra = ["episodes_on_device=\(collection.count)"]
            if let genre = item.genre { extra.append("genre=\(genre)") }

            records.append(DistilledRecord(
                source: "apple_podcasts",
                dataType: "podcast_show",
                // `podcastPersistentID` rather than the title: two shows share a
                // name more often than you would think, and a rename would
                // otherwise read as a new subscription on the next distillation.
                itemID: String(item.podcastPersistentID),
                name: show,
                creator: item.artist ?? "",
                detail: "",
                extra: extra.joined(separator: ";"),
                collectedAt: now
            ))
        }

        // Then the episodes. Capped, because a heavy downloader can hold
        // hundreds and the ontology stage wants the shape of the taste rather
        // than a complete manifest — the same argument `maxSongsRated` makes.
        let episodes = collections.flatMap { $0.items }
        for item in episodes.prefix(AppConfig.maxPodcastEpisodes) {
            guard let title = item.title else { continue }

            // **Everything optional is skipped rather than defaulted.** A zero
            // play count and an unknown play count are different facts, and
            // writing `plays=0` for the second would hand the ontology stage a
            // confident lie. Which of these the media library actually fills in
            // varies, so the row carries what it has and says nothing about the
            // rest.
            var extra: [String] = []
            if item.playbackDuration > 0 { extra.append("duration_s=\(Int(item.playbackDuration))") }
            if item.playCount > 0 { extra.append("plays=\(item.playCount)") }
            if item.bookmarkTime > 0 { extra.append("resume_s=\(Int(item.bookmarkTime))") }
            if let played = item.lastPlayedDate { extra.append("last_played=\(Self.day.string(from: played))") }
            if let released = item.releaseDate { extra.append("released=\(Self.day.string(from: released))") }
            // The one derived figure worth keeping: a downloaded-but-unplayed
            // episode and one listened to the end are opposite signals, and the
            // ratio says which without the ontology stage having to divide.
            if item.playbackDuration > 0, item.bookmarkTime > 0 {
                let share = min(1, item.bookmarkTime / item.playbackDuration)
                extra.append("progress=\(String(format: "%.2f", share))")
            }

            records.append(DistilledRecord(
                source: "apple_podcasts",
                dataType: "podcast_episode",
                itemID: String(item.persistentID),
                name: title,
                creator: item.podcastTitle ?? item.albumTitle ?? "",
                detail: "",
                extra: extra.joined(separator: ";"),
                collectedAt: now
            ))
        }

        // Surfaced rather than silently growing an empty branch — the rule
        // HealthKit taught, and here the reason can actually be given.
        guard !records.isEmpty else { throw PodcastError.noDownloads }
        return records
    }

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
