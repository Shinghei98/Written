import Foundation
import MediaPlayer

/// The songs actually on the device, as opposed to the Apple Music account.
///
/// `MPMediaQuery.songs()` reads the *device library* rather than the Apple Music
/// service, so it surfaces what MusicKit does not: purchased tracks, ripped CDs,
/// files synced from a computer.
///
/// **It was added as cover for people without an Apple Music subscription, and
/// measurement refuted that.** Same device, Sync Library on and then off:
///
///     songsControl          320  ->  0
///     libraryTotal          322  ->  2
///     cloudItemsInLibrary   304  ->  0
///     podcast items           2  ->  2      <- the control
///
/// **Zero songs.** Not the sixteen non-cloud rows that were predicted to survive
/// — all of them. Even those were Apple Music tracks downloaded for offline
/// play, which read as non-cloud and still depend on the subscription. Podcasts
/// held at 2 throughout, which is what proves the library was still readable and
/// authorised: `songs: 0` is an absence, not a refusal.
///
/// So for anybody whose music *is* Apple Music — the common case — this returns
/// nothing at all without Sync Library, and the branch it was supposed to
/// rescue stays empty.
///
/// **Sync Library off is not identical to unsubscribed**, and the difference is
/// the whole of this source's remaining value. Someone with iTunes Store
/// purchases or a collection synced from a computer keeps those rows in either
/// state; the test device simply has none. So this reads what a person *owns*
/// rather than what they stream, which is a real if uncommon population —
/// collectors, older libraries, anyone who bought music before streaming.
///
/// It stays, because the extraction rule is to take what is reachable and this
/// costs no permission, no picker row and no round trip. What it is not, and was
/// wrongly documented as being, is a guarantee that an unsubscribed person has a
/// music branch. **They do not.**
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
            // The same stamp `AppleMusicDistiller` writes, through the same
            // rule: composer for classical, performer otherwise. Nothing reads
            // these rows yet — `Ontology.subjects` counts `apple_music` only,
            // and the icebreaker splits `genres` where this writes `genre` —
            // but labelling at the point of collection is the whole reason the
            // rule moved here, and a row that arrives unlabelled would need a
            // re-distill to fix rather than a query.
            let subject = Ontology.musicSubject(
                genres: item.genre.map { [$0] } ?? [],
                composer: item.composer,
                performer: item.artist ?? ""
            )
            if !subject.isEmpty { extra.append("subject=\(subject)") }
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
