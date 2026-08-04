import Foundation
import MediaPlayer

/// The songs actually on the device, as opposed to the Apple Music account.
///
/// `MPMediaQuery.songs()` reads the *device library* rather than the Apple Music
/// service, so it surfaces what MusicKit does not: purchased tracks, ripped CDs,
/// files synced from a computer.
///
/// **It was added as cover for people without an Apple Music subscription, and
/// that justification is weaker than it was written.** The claim was that
/// somebody with hundreds of songs on their phone gets a music branch whether or
/// not they pay Apple monthly. The survey it cited says otherwise:
///
///     libraryTotal              322
///     music media type          320
///     cloudItemsInWholeLibrary  304
///
/// **304 of the 320 are cloud items** — present because Sync Library is on,
/// which is a subscription feature. Take the subscription away and those rows
/// most likely go with it, leaving the 16 that are genuinely local. So this
/// reads without a subscription as a matter of *API*, and may well return
/// nothing as a matter of *data*, for anybody who has only ever streamed.
///
/// The number that undercut the claim was in the same JSON as the number that
/// seemed to support it. Settle it by turning Sync Library off and re-running
/// `MediaFieldSurvey` — until then this is unproven either way.
///
/// It still earns its place: local files are real records that MusicKit does not
/// return, and the extraction rule is to take what is reachable. What it is not
/// is a guarantee that an unsubscribed person has a music branch.
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
