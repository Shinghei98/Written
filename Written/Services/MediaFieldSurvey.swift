#if DEBUG
import Foundation
import MediaPlayer

/// What does the media library *actually* hand over for podcasts?
///
/// **A throwaway, like `PodcastProbe` before it, and deleted once scope is
/// settled.** It exists because `PodcastDistiller` was written from recollection
/// about which fields Apple populates, and recollection has been wrong twice on
/// this question already — once claiming podcasts were unreachable at all.
///
/// **It writes a file rather than logging.** Every previous round trip on this
/// lost its answer to a console filter: the first probe logged a field dump per
/// item and those lines were never read before the probe was deleted. A file in
/// the app container can be pulled straight off a connected device:
///
///     xcrun devicectl device copy from --device <id> \
///         --domain-type appDataContainer --domain-identifier com.written.datingapp \
///         --source Documents/media-survey.json --destination ./media-survey.json
///
/// **Preconditions, stated because the last probe's absence of them cost a
/// wrong conclusion**: this is meaningful only on a device with at least one
/// *followed show* and at least one *downloaded episode*. Without both, an empty
/// field proves nothing about the framework — it may simply be that nothing
/// exists to report. The report repeats this in its own header.
enum MediaFieldSurvey {

    static func run() async -> String {
        let status = await withCheckedContinuation { (continuation: CheckedContinuation<MPMediaLibraryAuthorizationStatus, Never>) in
            MPMediaLibrary.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else { return "media library not authorized (\(status.rawValue))" }

        var report: [String: Any] = [
            "preconditions": "Only meaningful with a followed show AND a downloaded episode present. "
                + "An empty field otherwise says nothing about the framework.",
            "podcasts": survey(MPMediaQuery.podcasts(), label: "podcasts"),
            // Same library, same permission, already paid for. If it returns
            // anything it is a second source for free; if not, that is worth
            // knowing once rather than wondering later.
            "audiobooks": survey(MPMediaQuery.audiobooks(), label: "audiobooks")
        ]
        report["songsControl"] = MPMediaQuery.songs().items?.count ?? 0
        report["reachability"] = reachability()

        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
              let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return "could not serialise the survey" }

        let url = dir.appendingPathComponent("media-survey.json")
        do {
            try data.write(to: url)
            let podcasts = (report["podcasts"] as? [String: Any])?["itemCount"] as? Int ?? -1
            let books = (report["audiobooks"] as? [String: Any])?["itemCount"] as? Int ?? -1
            return "written: \(data.count) bytes — podcast items \(podcasts), audiobooks \(books)"
        } catch {
            return "write failed: \(error.localizedDescription)"
        }
    }

    /// **Is `MPMediaQuery.podcasts()` hiding anything?**
    ///
    /// That convenience query sets its own grouping and media-type predicate,
    /// and "only downloads come back" was concluded from *its* results — which
    /// says nothing about what the library holds. Followed-but-undownloaded
    /// episodes, or Apple Podcasts' "Saved" list, would be invisible to that
    /// query and still present underneath it.
    ///
    /// So this asks the same library four other ways and compares the counts. If
    /// every route agrees, the library genuinely holds only what is downloaded.
    /// If any route returns more, `.podcasts()` was the limit rather than the
    /// library, and saved episodes are reachable after all.
    private static func reachability() -> [String: Any] {
        var out: [String: Any] = [:]

        // 1. The whole library, unfiltered, broken down by media type. The
        //    honest baseline: anything the library knows about is in here.
        let everything = MPMediaQuery()
        let all = everything.items ?? []
        out["libraryTotal"] = all.count
        var byType: [String: Int] = [:]
        for item in all {
            byType[String(item.mediaType.rawValue), default: 0] += 1
        }
        out["libraryByMediaType"] = byType
        // `.podcast` is 4 in `MPMediaType`; named here so the JSON is readable
        // without the enum to hand.
        out["podcastTypedInWholeLibrary"] = all.filter { $0.mediaType.contains(.podcast) }.count
        out["cloudItemsInWholeLibrary"] = all.filter(\.isCloudItem).count

        // 2. A raw predicate on the media type, with no grouping — what
        //    `.podcasts()` does minus whatever else it does.
        let raw = MPMediaQuery()
        raw.addFilterPredicate(MPMediaPropertyPredicate(
            value: MPMediaType.podcast.rawValue,
            forProperty: MPMediaItemPropertyMediaType
        ))
        out["rawPredicateItems"] = raw.items?.count ?? 0

        // 3. The same, grouped by title rather than by show, in case the
        //    grouping is what collapses the result.
        let grouped = MPMediaQuery()
        grouped.addFilterPredicate(MPMediaPropertyPredicate(
            value: MPMediaType.podcast.rawValue,
            forProperty: MPMediaItemPropertyMediaType
        ))
        grouped.groupingType = .title
        out["groupedByTitleCollections"] = grouped.collections?.count ?? 0

        // 4. Playlists — does Apple Podcasts express "Saved", "Up Next" or a
        //    station as one? Cheap to ask and it has never been asked.
        let playlists = MPMediaQuery.playlists()
        out["playlistCount"] = playlists.collections?.count ?? 0
        out["playlistNames"] = (playlists.collections ?? []).prefix(30).compactMap {
            ($0 as? MPMediaPlaylist)?.name
        }

        return out
    }

    /// One query, described completely: a populated/empty tally per field, then
    /// the raw rows behind it.
    ///
    /// The tally is the point. A hundred item rows is a haystack, and the
    /// question — *which fields does Apple actually fill in* — is answered by
    /// counting, not by reading.
    private static func survey(_ query: MPMediaQuery, label: String) -> [String: Any] {
        let collections = query.collections ?? []
        let items = query.items ?? []

        var populated: [String: Int] = [:]
        func note(_ field: String, _ isSet: Bool) {
            populated[field, default: 0] += isSet ? 1 : 0
        }

        var rows: [[String: Any]] = []
        for item in items.prefix(40) {
            // Strings first. Empty-but-present is counted as empty, since a
            // field that is always "" is as useless to the ontology stage as one
            // that is nil, and the distinction would only flatter the tally.
            let strings: [String: String?] = [
                "title": item.title,
                "podcastTitle": item.podcastTitle,
                "albumTitle": item.albumTitle,
                "artist": item.artist,
                "albumArtist": item.albumArtist,
                "genre": item.genre,
                "composer": item.composer,
                "comments": item.comments
            ]
            var row: [String: Any] = [:]
            for (field, value) in strings {
                note(field, !(value ?? "").isEmpty)
                row[field] = value ?? NSNull()
            }

            // **`isCloudItem` is the field this survey exists for.** It says
            // whether the audio is on the device or merely listed from iCloud,
            // and therefore whether "reads episodes downloaded to this phone"
            // was true. `assetURL` is the second opinion: nil for anything the
            // app cannot actually read.
            let flags: [String: Bool] = [
                "isCloudItem": item.isCloudItem,
                "hasProtectedAsset": item.hasProtectedAsset,
                "isExplicitItem": item.isExplicitItem,
                "hasAssetURL": item.assetURL != nil,
                "hasArtwork": item.artwork != nil
            ]
            for (field, value) in flags {
                note(field, value)
                row[field] = value
            }

            let numbers: [String: Double] = [
                "playbackDuration": item.playbackDuration,
                "playCount": Double(item.playCount),
                "skipCount": Double(item.skipCount),
                "rating": Double(item.rating),
                "bookmarkTime": item.bookmarkTime,
                "albumTrackNumber": Double(item.albumTrackNumber)
            ]
            for (field, value) in numbers {
                note(field, value > 0)
                row[field] = value
            }

            let dates: [String: Date?] = [
                "releaseDate": item.releaseDate,
                "lastPlayedDate": item.lastPlayedDate,
                "dateAdded": item.dateAdded
            ]
            for (field, value) in dates {
                note(field, value != nil)
                row[field] = value.map(ISO8601DateFormatter().string(from:)) ?? NSNull()
            }

            row["mediaType"] = item.mediaType.rawValue
            row["persistentID"] = String(item.persistentID)
            row["podcastPersistentID"] = String(item.podcastPersistentID)
            rows.append(row)
        }

        return [
            "itemCount": items.count,
            "collectionCount": collections.count,
            "sampled": rows.count,
            // "of N sampled, how many had this set" — read this first.
            "populatedOfSampled": populated,
            "collections": collections.prefix(20).map { collection -> [String: Any] in
                [
                    "count": collection.count,
                    "representativeTitle": collection.representativeItem?.podcastTitle
                        ?? collection.representativeItem?.albumTitle ?? NSNull(),
                    "representativeArtist": collection.representativeItem?.artist ?? NSNull(),
                    "representativeGenre": collection.representativeItem?.genre ?? NSNull()
                ]
            },
            "items": rows
        ]
    }
}
#endif
