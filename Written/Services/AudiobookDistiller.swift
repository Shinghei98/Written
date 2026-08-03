import Foundation
import MediaPlayer

/// Audiobooks, from the same media library as podcasts.
///
/// **A separate source rather than more rows on `apple_podcasts`**, because
/// audiobooks come from Apple Books and podcasts from Apple Podcasts. Filing one
/// under the other's name would be a lie in the one column the ontology stage
/// reads to know where a fact came from. What they share is the *permission* —
/// `MPMediaLibrary` is asked once, so connecting the second of the two costs a
/// tap and no dialog.
///
/// **Whether anything is ever in here is untested.** `MPMediaQuery.audiobooks()`
/// returned zero on the one device it has been run against, and that device had
/// no audiobooks — which proves nothing, exactly as the same zero proved nothing
/// for podcasts before a show was followed. The field set below is podcasts'
/// field set because `MPMediaItem` is one type; which of them Apple Books
/// actually fills in will be known the first time somebody with an audiobook
/// connects this.
struct AudiobookDistiller {

    private static let sharedStore = MPMediaLibrary.default()

    enum AudiobookError: LocalizedError {
        case denied

        var errorDescription: String? {
            switch self {
            case .denied:
                return "Written needs access to your media library to read audiobooks. You can turn it on in Settings › Written."
            }
        }
    }

    func distill() async throws -> [DistilledRecord] {
        let status = await withCheckedContinuation { (continuation: CheckedContinuation<MPMediaLibraryAuthorizationStatus, Never>) in
            MPMediaLibrary.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else { throw AudiobookError.denied }

        let now = Date()
        var records: [DistilledRecord] = []

        // Grouped by album, which for an audiobook is the book — a long book
        // arrives as many files and would otherwise read as many books.
        let query = MPMediaQuery.audiobooks()
        query.groupingType = .album

        for collection in (query.collections ?? []).prefix(AppConfig.maxAudiobooks) {
            guard let item = collection.representativeItem,
                  let title = item.albumTitle ?? item.title else { continue }

            var extra = ["parts=\(collection.count)"]
            // Summed across the parts, since one part's duration says nothing
            // about the length of the book.
            let total = collection.items.reduce(0) { $0 + $1.playbackDuration }
            if total > 0 { extra.append("duration_s=\(Int(total))") }
            // Furthest point reached in any part — the closest thing to "how far
            // through are they", and the same measure podcasts use. Empty is
            // left empty rather than defaulted to nothing-listened, which is a
            // different claim.
            let furthest = collection.items.map(\.bookmarkTime).max() ?? 0
            if furthest > 0 { extra.append("resume_s=\(Int(furthest))") }
            if let genre = item.genre, !genre.isEmpty { extra.append("genre=\(genre)") }
            extra.append("added=\(Self.day.string(from: item.dateAdded))")

            records.append(DistilledRecord(
                source: "apple_audiobooks",
                dataType: "audiobook",
                itemID: String(item.albumPersistentID),
                name: title,
                // The author, which MediaPlayer files under `artist` for an
                // audiobook exactly as it files the publisher there for a
                // podcast.
                creator: item.artist ?? item.albumArtist ?? "",
                detail: "",
                extra: extra.joined(separator: ";"),
                collectedAt: now
            ))
        }

        // Empty is returned rather than thrown, for the reason podcasts settled:
        // somebody with no audiobooks has not failed at anything, and this sits
        // beside sources that have already grown the branch.
        return records
    }

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
