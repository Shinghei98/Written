import Foundation
import MediaPlayer

/// The songs actually on the device, as opposed to the Apple Music account.
///
/// **This exists because `AppleMusicDistiller` needs a subscription.** MusicKit
/// reads the Apple Music *service*: without an account it mints no developer
/// token and returns nothing, so somebody who has never subscribed currently
/// distils no music whatsoever — the largest single hole in this app's coverage,
/// and invisible from a developer's phone which is always signed in.
///
/// `MPMediaQuery.songs()` reads the *device library*, which needs no
/// subscription and holds what MusicKit never surfaces: purchased tracks, ripped
/// CDs, files synced from a computer. Measured on a real device during the
/// podcast survey — 320 songs, of which 304 were cloud items and the rest local
/// only.
///
/// **It costs no new permission and no new picker row.** MusicKit's
/// `MusicAuthorization` and `MPMediaLibrary.requestAuthorization` are the same
/// grant behind `NSAppleMusicUsageDescription`, so connecting Apple Music
/// already covers this, and it is run as part of that connect rather than
/// offered as a separate source. One tap, two record sources.
///
/// The overlap with `apple_music` is deliberate and not deduplicated here: they
/// are different observations — one says what the account holds, the other what
/// the phone holds — and collapsing them is the ontology stage's decision to
/// make with both in front of it.
struct MusicLibraryDistiller {

    func distill() async throws -> [DistilledRecord] {
        let status = await withCheckedContinuation { (continuation: CheckedContinuation<MPMediaLibraryAuthorizationStatus, Never>) in
            MPMediaLibrary.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else { return [] }

        let now = Date()
        let query = MPMediaQuery.songs()

        return (query.items ?? []).prefix(AppConfig.maxLibrarySongs).compactMap { item in
            guard let title = item.title else { return nil }

            var extra: [String] = []
            if let album = item.albumTitle, !album.isEmpty { extra.append("album=\(album)") }
            if let genre = item.genre, !genre.isEmpty { extra.append("genre=\(genre)") }
            // Named in the ontology blueprint, and MediaPlayer fills it in where
            // the file carries it — which for classical is most of the meaning.
            if let composer = item.composer, !composer.isEmpty { extra.append("composer=\(composer)") }
            // **Unlike podcasts, these are real.** The same fields measured empty
            // on every podcast episode are populated for music, which is why the
            // podcast records carry no play count and these do.
            if item.playCount > 0 { extra.append("plays=\(item.playCount)") }
            if item.skipCount > 0 { extra.append("skips=\(item.skipCount)") }
            if item.rating > 0 { extra.append("rating=\(item.rating)") }
            if let played = item.lastPlayedDate { extra.append("last_played=\(Self.day.string(from: played))") }
            if let released = item.releaseDate { extra.append("released=\(Self.day.string(from: released))") }
            if item.playbackDuration > 0 { extra.append("duration_s=\(Int(item.playbackDuration))") }
            extra.append("added=\(Self.day.string(from: item.dateAdded))")
            // Whether the audio is on the phone or only in iCloud. Kept because
            // it separates "in their library" from "downloaded to carry around",
            // which are different strengths of the same claim.
            extra.append("local=\(item.isCloudItem ? 0 : 1)")

            return DistilledRecord(
                source: "music_library",
                dataType: "library_song",
                itemID: String(item.persistentID),
                name: title,
                creator: item.artist ?? item.albumArtist ?? "",
                detail: "",
                extra: extra.joined(separator: ";"),
                collectedAt: now
            )
        }
    }

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
