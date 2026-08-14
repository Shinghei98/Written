import Foundation
import MusicKit

/// Distills the signals listed for Apple Music in written_api.xlsx:
/// library songs / albums / artists / music videos, user playlists and their
/// contents, recently added, recently played, heavy rotation, personalized
/// recommendations, and like/dislike ratings.
///
/// Friction profile: a single system permission dialog (no login — the
/// device's Apple Music account is used), then everything is fetched silently
/// through MusicKit, which manages the developer and user tokens itself.
struct AppleMusicDistiller {

    /// One endpoint that was asked and did not answer.
    ///
    /// **The point is that a failure and an empty library used to be the same
    /// value.** Every call here is best-effort — a library read that fails must
    /// not take recommendations down with it — and the way that was written,
    /// `(try? await task) ?? []`, threw the error away at the moment it
    /// happened. So a run that lost five of nine data types looked exactly like
    /// somebody who owns no music, and said so to nobody.
    struct Shortfall: Equatable, Sendable {
        /// The path, shortened to what a person would recognise.
        let endpoint: String
        /// Domain and code, in the shape `HealthKitDistiller.Trail` uses: enough
        /// to tell a timeout from a refusal on a card somebody photographs.
        let reason: String
        /// What was lost. More than one where a later pass depends on this call
        /// — the ratings pass works from the library song ids, and playlist
        /// items from the playlists, so those two failures cost two types each.
        let dataTypes: [String]
    }

    /// What a distillation produced, and what it could not.
    struct Report {
        let records: [DistilledRecord]
        let shortfalls: [Shortfall]

        var isPartial: Bool { !shortfalls.isEmpty }
        /// Every data type that went missing, for the card and the vault.
        var missingDataTypes: [String] { shortfalls.flatMap(\.dataTypes).sorted() }
    }

    /// Collects failures across the concurrent phase. A reference type because
    /// the awaits below write to it from several places; the same reason
    /// `HealthKitDistiller.Trail` is one.
    private final class Shortfalls: @unchecked Sendable {
        private let lock = NSLock()
        private var found: [Shortfall] = []

        func add(_ endpoint: String, _ error: Error, losing dataTypes: [String]) {
            let reason: String
            if let urlError = error as? URLError {
                reason = "URLError \(urlError.code.rawValue)"
            } else {
                let nsError = error as NSError
                reason = "\(nsError.domain) \(nsError.code)"
            }
            lock.lock(); defer { lock.unlock() }
            found.append(Shortfall(endpoint: endpoint, reason: reason, dataTypes: dataTypes))
        }

        var all: [Shortfall] {
            lock.lock(); defer { lock.unlock() }
            return found.sorted { $0.endpoint < $1.endpoint }
        }
    }

    enum MusicError: LocalizedError {
        case notAuthorized

        var errorDescription: String? {
            "Apple Music access was not granted. You can enable it in Settings → Written."
        }
    }

    private static let apiBase = "https://api.music.apple.com"

    func distill() async throws -> Report {
        let status = await MusicAuthorization.request()
        guard status == .authorized else { throw MusicError.notAuthorized }

        var records: [DistilledRecord] = []

        // Apple Music has far more endpoints than the other sources — nine here
        // against YouTube's four — and run one after another that difference is
        // the whole reason this connect felt so much slower. It was never that
        // the data is richer; it is that a sequential distill pays a round trip
        // per family and then a *second* one per playlist and per hundred songs.
        //
        // Phase one: everything that depends on nothing. `async let` starts all
        // nine immediately and the awaits below collect them.
        // **`include=catalog`, and it is one parameter on a request already being
        // made** — the same shape as YouTube's `part=topicDetails`, quota being
        // per call rather than per part.
        //
        // A `library-songs` resource states no ISRC; only its catalogue
        // counterpart does, reached through the `catalog` relationship. Measured
        // 2026-08-14: **0 of 3,102 Apple Music observations carry an ISRC** while
        // Spotify carries one on 1,910 of 2,080, so the one identifier the two
        // catalogues share was missing from exactly the source that needs it —
        // Apple's own. Without it an Apple-only library cannot be resolved
        // against a catalogue at all, and `sources.online_resolution_policy` is
        // `catalog_ids_only`: an id may be sent, a performer's name may not.
        async let songsTask = fetchAllPages(path: "/v1/me/library/songs?limit=100&include=catalog")
        async let albumsTask = fetchAllPages(path: "/v1/me/library/albums?limit=100")
        async let artistsTask = fetchAllPages(path: "/v1/me/library/artists?limit=100")
        async let videosTask = fetchAllPages(path: "/v1/me/library/music-videos?limit=100")
        async let playlistsTask = fetchAllPages(path: "/v1/me/library/playlists?limit=100")
        async let recentlyAddedTask = fetchAllPages(path: "/v1/me/library/recently-added?limit=25")
        async let recentlyPlayedTask = fetchAllPages(path: "/v1/me/recent/played/tracks?limit=30")
        async let heavyRotationTask = fetchAllPages(path: "/v1/me/history/heavy-rotation?limit=10")
        async let recommendationsTask = fetchAllPages(path: "/v1/me/recommendations?limit=30")

        // 1. Library songs (also the id list the ratings pass works from).
        //
        // **Best-effort, like the other eight.** These two were the only
        // required calls in the run, so a library read that failed took the
        // whole distillation with it — recommendations, heavy rotation,
        // recently played, all discarded because one endpoint said no.
        //
        // Which endpoints answer depends on state nobody here has measured:
        // authorised is not the same as subscribed, and subscribed is not the
        // same as having Sync Library switched on. A library read failing is
        // exactly the case where the remaining calls are worth keeping, so no
        // single endpoint gets to end the run. `MusicError.notAuthorized` above
        // is still fatal, because that one is a real refusal.
        // **Still best-effort, but the reason is kept now.** Nothing here can
        // end the run — that decision stands and the comment above says why —
        // and the difference is only that a failure is recorded instead of
        // being flattened into an empty list.
        let shortfalls = Shortfalls()

        var songs: [[String: Any]] = []
        do { songs = try await songsTask } catch {
            // Two types, because the ratings pass works from these ids.
            shortfalls.add("library/songs", error, losing: ["library_song", "rating"])
        }
        let librarySongIDs = songs.compactMap { $0["id"] as? String }
        records += songs.map { makeRecord(dataType: "library_song", resource: $0) }

        // 2–4. Library albums, artists, music videos.
        do { records += try await albumsTask.map { makeRecord(dataType: "library_album", resource: $0) } }
        catch { shortfalls.add("library/albums", error, losing: ["library_album"]) }
        do { records += try await artistsTask.map { makeRecord(dataType: "library_artist", resource: $0) } }
        catch { shortfalls.add("library/artists", error, losing: ["library_artist"]) }
        do { records += try await videosTask.map { makeRecord(dataType: "library_music_video", resource: $0) } }
        catch { shortfalls.add("library/music-videos", error, losing: ["library_music_video"]) }

        // 5. Playlists themselves; their tracks come in phase two.
        var playlists: [[String: Any]] = []
        do { playlists = try await playlistsTask } catch {
            // Two types again: the tracks are fetched from these playlists.
            shortfalls.add("library/playlists", error, losing: ["library_playlist", "playlist_item"])
        }
        records += playlists.map { makeRecord(dataType: "library_playlist", resource: $0) }

        // 6–8. Recently added (max 25 per page), recently played (max 30),
        // heavy rotation — the strongest current-taste signal.
        do { records += try await recentlyAddedTask.map { makeRecord(dataType: "recently_added", resource: $0) } }
        catch { shortfalls.add("library/recently-added", error, losing: ["recently_added"]) }
        do { records += try await recentlyPlayedTask.map { makeRecord(dataType: "recently_played", resource: $0) } }
        catch { shortfalls.add("recent/played", error, losing: ["recently_played"]) }
        do { records += try await heavyRotationTask.map { makeRecord(dataType: "heavy_rotation", resource: $0) } }
        catch { shortfalls.add("history/heavy-rotation", error, losing: ["heavy_rotation"]) }

        // 9. Personalized recommendations. No extra requests: the items are
        // already inside `relationships.contents` on what came back.
        var recommendations: [[String: Any]] = []
        do { recommendations = try await recommendationsTask } catch {
            shortfalls.add("recommendations", error, losing: ["recommendation"])
        }
        for recommendation in recommendations {
            let reason = attribute("title", of: recommendation)
            let contents = ((recommendation["relationships"] as? [String: Any])?["contents"] as? [String: Any])?["data"] as? [[String: Any]] ?? []
            records += contents.map {
                makeRecord(dataType: "recommendation", resource: $0, detailOverride: "shelf=\(reason)")
            }
        }

        // Phase two: the two passes that need phase one's answers first. Both
        // were loops of sequential round trips, and the ratings one grows with
        // the size of the library — the "per-item fetch that can't be capped"
        // CLAUDE.md warns about, in the one distiller nobody could test.
        async let playlistItems = playlistTracks(in: playlists)
        async let ratings = ratings(forSongIDs: librarySongIDs)
        records += await playlistItems
        records += await ratings

        records.append(await Self.subscriptionRecord())

        return Report(records: records, shortfalls: shortfalls.all)
    }

    /// Whether this person actually has an Apple Music subscription.
    ///
    /// **Because "logged in to Apple Music" is four different states** and the
    /// app has been reasoning about it without ever asking. Signed into an Apple
    /// Account, having authorised this app, holding a paid subscription, and
    /// having Sync Library switched on are separate facts, and they gate
    /// different endpoints: the library reads above, the service features
    /// (recommendations, heavy rotation, recently played) and everything the
    /// device library covers instead.
    ///
    /// One row makes the difference measurable across testers rather than
    /// argued about — and it is what says whether `MusicLibraryDistiller` is
    /// duplicating this source or covering for it, since both now write song
    /// rows and the library rows carry `local=`.
    ///
    /// A `user` record: no column, no migration, and the change-only trigger
    /// means a distillation that finds the same answer writes nothing.
    /// The three answers `MusicSubscription` can give, kept apart.
    ///
    /// `canPlayCatalogContent` is what "subscribed" means here — the closest
    /// available flag, and the one that matters, since the endpoints a
    /// subscription unlocks are catalog-backed. It reads true for the Voice
    /// plan and false during a lapsed renewal; both are recorded as what the
    /// flag said rather than second-guessed, so the edge cases stay traceable.
    enum Subscription: String {
        case subscribed
        case authorizedNoSubscription = "authorized_no_subscription"
        /// The query itself failed. **Not the same as "no"** — it also covers a
        /// region that cannot do Apple Music and a request that never left the
        /// device, so flattening it into either would invent an answer.
        case unknown
    }

    static func subscriptionState() async -> Subscription {
        guard let subscription = try? await MusicSubscription.current else { return .unknown }
        return subscription.canPlayCatalogContent ? .subscribed : .authorizedNoSubscription
    }

    private static func subscriptionRecord() async -> DistilledRecord {
        let state = await subscriptionState().rawValue

        return DistilledRecord(
            source: "user",
            dataType: "apple_music_subscription",
            itemID: "apple_music_subscription",
            name: state,
            creator: "",
            detail: "",
            extra: "measured=1",
            collectedAt: Date()
        )
    }

    /// A playlist reduced to what expanding it needs. A named type rather than
    /// a tuple because Swift no longer splats one into a closure's parameters.
    private struct PlaylistRef: Sendable {
        let id: String
        let name: String
    }

    /// The tracks inside each playlist, several at a time.
    private func playlistTracks(in playlists: [[String: Any]]) async -> [DistilledRecord] {
        let wanted = playlists.prefix(AppConfig.maxPlaylistsExpanded).compactMap { playlist -> PlaylistRef? in
            guard let id = playlist["id"] as? String else { return nil }
            return PlaylistRef(id: id, name: attribute("name", of: playlist))
        }

        return await inParallel(over: Array(wanted)) { playlist in
            // Best effort: an empty playlist returns 404, which must not sink
            // the whole distillation.
            guard let tracks = try? await fetchAllPages(
                // `include=catalog` for the same reason as the library songs
                // call: a playlist's tracks are `library-songs` and state no
                // ISRC of their own.
                path: "/v1/me/library/playlists/\(playlist.id)/tracks?limit=100&include=catalog"
            ) else { return [] }
            return tracks.map {
                makeRecord(dataType: "playlist_item", resource: $0, detailOverride: "playlist=\(playlist.name)")
            }
        }
    }

    /// Like/dislike ratings, in batches of a hundred ids.
    ///
    /// The endpoint answers only for songs the user actually rated, so most
    /// batches come back nearly empty — which is exactly why running them one
    /// after another was such poor value for the time it cost.
    private func ratings(forSongIDs ids: [String]) async -> [DistilledRecord] {
        let capped = Array(ids.prefix(AppConfig.maxSongsRated))
        return await inParallel(over: capped.chunked(into: 100)) { batch in
            guard let rated = try? await fetchAllPages(
                path: "/v1/me/ratings/library-songs?ids=\(batch.joined(separator: ","))"
            ) else { return [] }
            return rated.map { resource in
                let value = (resource["attributes"] as? [String: Any])?["value"] as? Int ?? 0
                return DistilledRecord(
                    source: "apple_music",
                    dataType: "rating",
                    itemID: resource["id"] as? String ?? "",
                    name: "",
                    creator: "",
                    detail: value > 0 ? "liked" : "disliked",
                    extra: "value=\(value)",
                    collectedAt: Date()
                )
            }
        }
    }

    /// Runs `work` over `items` with a few in flight at once.
    ///
    /// Bounded rather than all-at-once: a large library is dozens of rating
    /// batches, and firing them simultaneously trades a slow distill for a
    /// rate-limited one.
    private func inParallel<Item: Sendable>(
        over items: [Item],
        limit: Int = 5,
        _ work: @escaping @Sendable (Item) async -> [DistilledRecord]
    ) async -> [DistilledRecord] {
        guard !items.isEmpty else { return [] }

        return await withTaskGroup(of: [DistilledRecord].self) { group in
            var index = 0
            var collected: [DistilledRecord] = []

            while index < min(limit, items.count) {
                let item = items[index]
                group.addTask { await work(item) }
                index += 1
            }

            // One new task for each that finishes, so `limit` stay in flight.
            while let batch = await group.next() {
                collected += batch
                if index < items.count {
                    let item = items[index]
                    group.addTask { await work(item) }
                    index += 1
                }
            }
            return collected
        }
    }

    // MARK: - Fetching

    /// Fetches a paginated Apple Music API endpoint, following `next` links.
    /// Resources are returned as raw dictionaries because each endpoint mixes
    /// resource types (songs, albums, playlists, stations...).
    private func fetchAllPages(path: String) async throws -> [[String: Any]] {
        var resources: [[String: Any]] = []
        var nextPath: String? = path

        for _ in 0..<AppConfig.maxPagesPerEndpoint {
            guard let currentPath = nextPath,
                  let url = URL(string: Self.apiBase + currentPath)
            else { break }

            let request = MusicDataRequest(urlRequest: URLRequest(url: url))
            let response = try await request.response()

            guard let json = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else { break }
            resources += json["data"] as? [[String: Any]] ?? []
            nextPath = (json["next"] as? String).map { carrying(queryOf: path, onto: $0) }
            if nextPath == nil { break }
        }
        return resources
    }

    /// Apple's `next` states the offset and forgets everything else.
    ///
    /// **Measured 2026-08-14: `include=catalog` reached exactly 100 of 320
    /// library songs — one page.** The paging link comes back as
    /// `/v1/me/library/songs?offset=100` with no `include`, so every page after
    /// the first returned library resources with no catalogue relationship and
    /// therefore no ISRC. Nothing failed; the field was simply absent for 69% of
    /// the library, which reads exactly like Apple not having the data.
    ///
    /// Carried generically rather than by re-appending the one parameter,
    /// because the next `include` or `extend` added here would land the same way
    /// and the symptom is a quietly incomplete answer rather than an error.
    /// Anything the paging link states itself wins — the offset is its business.
    private func carrying(queryOf original: String, onto next: String) -> String {
        guard var components = URLComponents(string: next),
              let originalItems = URLComponents(string: original)?.queryItems
        else { return next }
        var items = components.queryItems ?? []
        let stated = Set(items.map(\.name))
        items += originalItems.filter { !stated.contains($0.name) }
        components.queryItems = items
        return components.string ?? next
    }

    // MARK: - Normalization

    private func makeRecord(
        dataType: String,
        resource: [String: Any],
        detailOverride: String? = nil
    ) -> DistilledRecord {
        let name = attribute("name", of: resource).isEmpty
            ? attribute("title", of: resource)
            : attribute("name", of: resource)
        let creator = [attribute("artistName", of: resource), attribute("curatorName", of: resource)]
            .first { !$0.isEmpty } ?? ""

        var extras: [String] = []
        extras.append("resource_type=\(resource["type"] as? String ?? "")")
        if let attributes = resource["attributes"] as? [String: Any] {
            if let genres = attributes["genreNames"] as? [String], !genres.isEmpty {
                extras.append("genres=\(genres.joined(separator: "|"))")
            }
            if let dateAdded = attributes["dateAdded"] as? String {
                extras.append("date_added=\(dateAdded)")
            }
            if let lastPlayed = attributes["lastPlayedDate"] as? String {
                extras.append("last_played=\(lastPlayed)")
            }
            if let playCount = attributes["playCount"] as? Int {
                extras.append("play_count=\(playCount)")
            }
            if let cover = artworkURL(in: attributes) {
                extras.append("artwork=\(cover)")
            }

            // **Everything else the response already carried.** These were
            // fetched on every request and discarded at this line; the ontology
            // stage cannot ask for what was never kept, and re-distilling
            // everybody later to recover a field is not a thing that can be
            // done quietly.
            //
            // `composerName` is the one named in the ontology blueprint —
            // classical listening is invisible without it, since the "artist"
            // of a Bach partita is whoever performed it.
            if let composer = attributes["composerName"] as? String, !composer.isEmpty {
                extras.append("composer=\(composer)")
            }
            if let album = attributes["albumName"] as? String, !album.isEmpty {
                extras.append("album=\(album)")
            }
            if let released = attributes["releaseDate"] as? String {
                extras.append("released=\(released)")
            }
            // Seconds, not milliseconds: nothing downstream needs that precision
            // and every other duration in this schema is in seconds.
            if let millis = attributes["durationInMillis"] as? Int {
                extras.append("duration_s=\(millis / 1000)")
            }
            if let track = attributes["trackNumber"] as? Int {
                extras.append("track=\(track)")
            }
            if let rating = attributes["contentRating"] as? String, !rating.isEmpty {
                extras.append("content_rating=\(rating)")
            }
            if let hasLyrics = attributes["hasLyrics"] as? Bool {
                extras.append("has_lyrics=\(hasLyrics ? 1 : 0)")
            }

            // **The two catalogue identifiers, taken from whichever place the
            // response put them.** `isrc` is the identifier Spotify also states,
            // so it is what joins the two libraries; `catalog_id` is Apple's own
            // and is what survives when a row has no ISRC. Both are read because
            // a library resource states neither directly — the first arrives on
            // the `catalog` relationship above, the second is on `playParams`,
            // which was already in every response and discarded at this line.
            //
            // Named `isrc` because `SpotifyDistiller` already writes that key and
            // `with_catalogue_genres` already reads it. A third spelling would be
            // the `keywords`/`tags` defect again: a field present in the record
            // and invisible to everything downstream.
            if let isrc = catalogAttribute("isrc", of: resource), !isrc.isEmpty {
                extras.append("isrc=\(isrc)")
            }
            if let catalogID = catalogIdentifier(of: resource), !catalogID.isEmpty {
                extras.append("catalog_id=\(catalogID)")
            }

            // **What this row is *about*, decided once, here.**
            //
            // For almost all music that is the performer. For classical it is
            // the composer, because Apple Music's artist for a Bach partita is
            // whoever played it — the reason `composerName` is kept two blocks
            // above.
            //
            // It is stamped rather than worked out downstream because there are
            // two downstreams and they must agree: `Ontology.subjects` writes
            // the three figures on a dynamic profile, and `seed_icebreaker`
            // picks the name in the opening sentence, one in Swift and one in
            // SQL. Implemented twice they drift, and the day they drift the
            // page says Bach while the thread says English Baroque Soloists
            // about the same listening. Both now read this field and fall back
            // to `creator`, so the rule exists once.
            //
            // Same shape as `cal_type` and `booked=1`: a derived flag stamped
            // by the distiller, and self-healing for the same reason — a
            // re-stamped row differs from its stored version, and
            // `append_source_records` treats a difference as a change, so one
            // re-distill re-labels a whole library.
            let subject = Ontology.musicSubject(
                genres: attributes["genreNames"] as? [String] ?? [],
                composer: attributes["composerName"] as? String,
                performer: creator
            )
            if !subject.isEmpty {
                extras.append("subject=\(subject)")
            }
        }

        return DistilledRecord(
            source: "apple_music",
            dataType: dataType,
            itemID: resource["id"] as? String ?? "",
            name: name,
            creator: creator,
            detail: detailOverride ?? attribute("albumName", of: resource),
            extra: extras.joined(separator: ";"),
            collectedAt: Date()
        )
    }

    /// Apple hands back a *template*, not a URL: `.../{w}x{h}bb.jpg`. Stored as
    /// it comes it would 404 — the size has to be filled in first. 300px covers
    /// the dashboard's largest tile without pulling artwork at poster size.
    private func artworkURL(in attributes: [String: Any]) -> String? {
        guard let template = (attributes["artwork"] as? [String: Any])?["url"] as? String,
              !template.isEmpty else { return nil }
        return template
            .replacingOccurrences(of: "{w}", with: "300")
            .replacingOccurrences(of: "{h}", with: "300")
    }

    private func attribute(_ key: String, of resource: [String: Any]) -> String {
        (resource["attributes"] as? [String: Any])?[key] as? String ?? ""
    }

    /// The catalogue resource behind a library row, when `include=catalog`
    /// brought one back.
    ///
    /// **Absent is a normal answer, not a failure.** A song a person added from
    /// a CD rip or a file has no catalogue counterpart at all, and the
    /// relationship is simply missing — which is why every caller here is
    /// optional and nothing is stamped when it is.
    private func catalogResource(of resource: [String: Any]) -> [String: Any]? {
        guard let relationships = resource["relationships"] as? [String: Any],
              let catalog = relationships["catalog"] as? [String: Any],
              let data = catalog["data"] as? [[String: Any]] else { return nil }
        return data.first
    }

    /// A catalogue field, from the resource itself or from the one behind it.
    ///
    /// **Half these endpoints already return catalogue resources.**
    /// `recently-added`, `recent/played/tracks`, `heavy-rotation` and
    /// `recommendations` answer with `songs`, not `library-songs`, so their
    /// catalogue attributes are on the row rather than behind a `catalog`
    /// relationship — reading only the relationship found nothing on 452 rows
    /// that were stating the answer outright.
    private func catalogAttribute(_ key: String, of resource: [String: Any]) -> String? {
        if let own = (resource["attributes"] as? [String: Any])?[key] as? String,
           !own.isEmpty {
            return own
        }
        guard let catalog = catalogResource(of: resource),
              let attributes = catalog["attributes"] as? [String: Any] else { return nil }
        return attributes[key] as? String
    }

    /// Whether a resource is itself a catalogue row rather than a library one.
    ///
    /// Library types are `library-songs`, `library-albums`, `library-playlists`;
    /// catalogue types carry the bare name. Testing the prefix rather than
    /// listing the types means a resource kind added later is read correctly by
    /// default instead of silently answering nothing.
    private func isCatalogResource(_ resource: [String: Any]) -> Bool {
        guard let type = resource["type"] as? String else { return false }
        return !type.hasPrefix("library-")
    }

    /// Apple's own id for the catalogue song a library row stands for.
    ///
    /// **Two places state it and the cheaper one is tried second.**
    /// `playParams.catalogId` rides on every response already and costs nothing,
    /// but it is absent for anything not catalogue-backed; the `catalog`
    /// relationship's `id` is authoritative and only present with
    /// `include=catalog`. Reading both means a row keeps an identifier whichever
    /// way the response is shaped, and a future call that drops the `include`
    /// degrades rather than going silent.
    private func catalogIdentifier(of resource: [String: Any]) -> String? {
        // A catalogue resource *is* the thing being identified; its own id is
        // the catalogue id, and there is no relationship to follow.
        if isCatalogResource(resource), let id = resource["id"] as? String, !id.isEmpty {
            return id
        }
        if let id = catalogResource(of: resource)?["id"] as? String, !id.isEmpty {
            return id
        }
        guard let attributes = resource["attributes"] as? [String: Any],
              let playParams = attributes["playParams"] as? [String: Any] else { return nil }
        return playParams["catalogId"] as? String
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
