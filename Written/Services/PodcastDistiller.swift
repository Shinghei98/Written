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

    /// **Only a refusal is an error here.** There is deliberately no case for an
    /// empty library — see the note above `distill`'s return.
    enum PodcastError: LocalizedError {
        case denied

        var errorDescription: String? {
            switch self {
            case .denied:
                return "Written needs access to your media library to read Apple Podcasts. You can turn it on in Settings › Written."
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
        // **Every episode, not the capped shows.** `maxPodcastShows` is a
        // guardrail on how long a distillation takes; the archive is the answer
        // the library gave, and a show trimmed here is one nobody can recover
        // without asking somebody to open the app.
        if let payload = RawArchiveSerialiser.envelope(
            source: "apple_podcasts", kind: "episode",
            objects: collections.flatMap { $0.items }.map(RawArchiveSerialiser.mediaItem)
        ) {
            await RawArchive.shared.captureEncoded(
                source: "apple_podcasts", endpoint: "episode", payload: payload
            )
        }
        let now = Date()

        var records: [DistilledRecord] = []

        // A show, once, however many of its episodes are on the phone. The
        // collection is what `MPMediaQuery.podcasts()` groups by, so this is
        // free — and it is the row the ontology stage wants, since the show is
        // the taste and the episode is the instance.
        for collection in collections.prefix(AppConfig.maxPodcastShows) {
            guard let item = collection.representativeItem,
                  let show = item.podcastTitle ?? item.albumTitle else { continue }

            // No `genre`: measured nil on every episode of both shows. Apple
            // does not write a podcast category into the media library at all,
            // so a category would have to come from the iTunes Search API by
            // show name — a network call and a name match, and not obviously
            // worth either.
            let extra = ["episodes_on_device=\(collection.count)"]

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

            // **Only the fields the library was measured to fill in.**
            // `playCount`, `lastPlayedDate` and `genre` were nil or zero on
            // every sampled episode — including ones demonstrably played — so
            // Apple keeps no play history here whatever. They were written
            // conditionally at first, which is harmless but dishonest about what
            // this source can offer; the survey settled it and they are gone.
            //
            // Everything remaining is still skipped when absent rather than
            // defaulted. A zero and an unknown are different facts, and writing
            // one for the other hands the ontology stage a confident lie.
            var extra: [String] = []
            if item.playbackDuration > 0 { extra.append("duration_s=\(Int(item.playbackDuration))") }
            if item.bookmarkTime > 0 { extra.append("resume_s=\(Int(item.bookmarkTime))") }
            if let released = item.releaseDate { extra.append("released=\(Self.day.string(from: released))") }
            // **When it arrived on the phone, which under auto-download is a
            // fact about the show rather than the episode.** Apple keeps the
            // recent episodes of followed shows without being asked, so a fresh
            // `added` date means the show is still publishing and still
            // followed — where `released` only says when the world got it.
            // Non-optional, unlike everything else here — the library always
            // knows when it took something in.
            extra.append("added=\(Self.day.string(from: item.dateAdded))")
            // **The only behavioural fact this source has.** With no play count
            // and no last-played, the resume position is all that separates an
            // episode delivered automatically from one somebody actually
            // started. Measured real: 50.8s of 4191.8s, 48.9s of 2381s.
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

        // **Empty is returned, not thrown, and that is deliberate — the Health
        // rule does not carry over.**
        //
        // Health surfaces an empty distill as a failure because it is the only
        // source on its branch: connect it, get nothing, and the plant refuses
        // to move with no explanation. Podcasts sits beside YouTube on Media, so
        // an empty result leaves nobody staring at a branch that would not grow.
        //
        // And the only sentence there is to say — "download an episode and try
        // again" — asks somebody to change how they listen in order to feed our
        // database. Someone who streams everything has not failed at anything.
        // The picker row says what this reads *before* it is tapped, which is
        // where an expectation belongs; complaining afterwards would be nagging.
        return records
    }

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
