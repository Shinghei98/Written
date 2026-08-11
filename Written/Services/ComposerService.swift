import Foundation
import MusicKit

/// The composer and genres for a recording, looked up by ISRC.
///
/// **Why this exists.** Spotify's track object carries no composer and no track
/// genre, so `Ontology.musicSubject` cannot fire its classical rule and a Bach
/// partita files under whoever performed it. Apple Music's catalog carries both
/// fields for the same recording, and an ISRC is the identifier the two
/// services share — Spotify puts one in `external_ids`, Apple's catalog filters
/// on it.
///
/// **Both fields or neither.** `musicSubject` needs a classical genre *and* a
/// composer; a composer alone changes nothing, and a genre alone changes
/// nothing. So this returns them together or returns nil.
///
/// **No new credential.** `MusicDataRequest` injects the developer and
/// music-user tokens itself — the same mechanism `AppleMusicDistiller` has used
/// all along, which is why there is no `Authorization` header anywhere in this
/// app. The catalog is simply a path it had never asked for.
///
/// **Unverified where it matters.** `filter[isrc]` is documented on Apple's
/// Songs resource and `composerName`/`genreNames` are attributes
/// `AppleMusicDistiller` already reads off library songs — but this exact query
/// has never been run against a real token, because doing so needs the app's
/// signing identity. `probe(isrc:)` exists to settle that in one call before
/// anything is built on top of it.
actor ComposerService {

    static let shared = ComposerService()

    /// What the catalog knows about a recording.
    struct Credits: Codable, Equatable {
        let composer: String
        let genres: [String]
    }

    /// A lookup is not worth making a distillation wait. On a slow network this
    /// gives up and the row keeps the performer it already had.
    private static let timeout: TimeInterval = 8

    /// **Batched, because the alternative is the shape CLAUDE.md warns about.**
    /// `filter[isrc]` takes comma-joined values, exactly as the ratings pass's
    /// `ids=` does, so a library costs a handful of requests rather than one per
    /// track. A per-item fetch against a rate-limited service is how Apple
    /// Music's ratings pass became "one round trip per hundred songs with no
    /// ceiling", which is the precedent this is written against.
    private static let isrcsPerRequest = 100

    /// Both the credits found and the recordings known to have none.
    ///
    /// **Negative caching earns its place more here than in `LyricsService`.**
    /// Most tracks have no composer and never will, so `nil` has to mean
    /// "asked, nothing there" rather than "not asked" — otherwise every
    /// distillation re-asks the catalog about the same pop library forever.
    private var cache: [String: Credits?]

    /// In `.cachesDirectory`: derived from a third party and re-fetchable, so it
    /// should be evictable and must not be backed up. Deliberately not anywhere
    /// `CSVExporter` can see — a cache is not a distilled record and has no
    /// business in somebody's export.
    private static let cacheURL: URL? = {
        try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("isrc-credits.json")
    }()

    /// The storefront the catalog is queried against.
    ///
    /// Fetched once and kept, because it cannot change inside a distillation and
    /// it is a request like any other. Apple localises genre names to the
    /// storefront, which is why `musicSubject` matches `contains("classical")`
    /// and does not take `Klassik` or 古典音樂 — a caveat this inherits rather
    /// than introduces.
    private var storefront: String?

    init() {
        cache = Self.loadCache()
    }

    // MARK: - Asking

    /// Credits for many recordings at once, keyed by ISRC.
    ///
    /// Never throws: every failure — offline, no subscription, a recording the
    /// catalog does not carry — is the same answer to the caller, which is
    /// "leave the row's performer alone".
    func credits(forISRCs isrcs: [String]) async -> [String: Credits] {
        let wanted = Set(isrcs.filter { !$0.isEmpty })
        guard !wanted.isEmpty else { return [:] }

        var found: [String: Credits] = [:]
        var toAsk: [String] = []
        for isrc in wanted {
            if let cached = cache[isrc] {
                if let cached { found[isrc] = cached }   // nil = asked, nothing there
            } else {
                toAsk.append(isrc)
            }
        }
        guard !toAsk.isEmpty else { return found }

        for batch in stride(from: 0, to: toAsk.count, by: Self.isrcsPerRequest).map({
            Array(toAsk[$0..<min($0 + Self.isrcsPerRequest, toAsk.count)])
        }) {
            let answered = await fetch(isrcs: batch)
            for isrc in batch {
                // **Recorded either way.** A miss is a fact about the recording,
                // not a failure to ask, and caching it is what stops a pop
                // library being re-queried on every distillation.
                cache[isrc] = answered[isrc]
                if let credits = answered[isrc] { found[isrc] = credits }
            }
        }
        saveCache()
        return found
    }

    /// One ISRC, for the probe and for callers with a single row.
    func credits(forISRC isrc: String) async -> Credits? {
        await credits(forISRCs: [isrc])[isrc]
    }

    // MARK: - Fetching

    private func fetch(isrcs: [String]) async -> [String: Credits?] {
        guard let storefront = await currentStorefront() else {
            // No storefront, no catalog path. Nothing is cached: this is a
            // failure to ask rather than an answer, and caching it would make a
            // temporary problem permanent.
            return [:]
        }

        let joined = isrcs.joined(separator: ",")
        guard let encoded = joined.addingPercentEncoding(
                withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string:
                "https://api.music.apple.com/v1/catalog/\(storefront)/songs?filter[isrc]=\(encoded)")
        else { return [:] }

        var request = URLRequest(url: url)
        request.timeoutInterval = Self.timeout

        do {
            let response = try await MusicDataRequest(urlRequest: request).response()
            guard let json = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
                  let data = json["data"] as? [[String: Any]]
            else { return [:] }

            var byISRC: [String: Credits?] = [:]
            for song in data {
                guard let attributes = song["attributes"] as? [String: Any] else { continue }
                // The response echoes the ISRC it matched, which is the only
                // way to put a row back against the id that asked for it — the
                // catalog returns songs in its own order and may return several
                // for one ISRC across storefront editions.
                guard let isrc = attributes["isrc"] as? String else { continue }
                let composer = (attributes["composerName"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let genres = attributes["genreNames"] as? [String] ?? []
                guard !composer.isEmpty else { continue }
                // First match wins: editions differ by territory and artwork,
                // not by who wrote the piece.
                if byISRC[isrc] == nil {
                    byISRC[isrc] = Credits(composer: composer, genres: genres)
                }
            }
            return byISRC
        } catch {
            return [:]
        }
    }

    private func currentStorefront() async -> String? {
        if let storefront { return storefront }
        guard let url = URL(string: "https://api.music.apple.com/v1/me/storefront") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.timeout
        guard let response = try? await MusicDataRequest(urlRequest: request).response(),
              let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let data = json["data"] as? [[String: Any]],
              let id = data.first?["id"] as? String
        else { return nil }
        storefront = id
        return id
    }

    // MARK: - The probe

    /// One request, printed, so the premise can be settled before anything is
    /// built on it.
    ///
    /// Called from `-probe isrc <ISRC>` in DEBUG. If this prints a composer, the
    /// design holds; if it 404s or omits `composerName`, the fallback is
    /// MusicBrainz — which was measured at one request per second against
    /// roughly a hundred per request here, and returns `composer` for classical
    /// but several `writer` credits for pop.
    func probe(isrc: String) async -> String {
        guard let storefront = await currentStorefront() else {
            return "probe: no storefront — MusicKit is not authorised, or there is no signed-in Apple Music account"
        }
        guard let credits = await credits(forISRC: isrc) else {
            return "probe: storefront \(storefront), ISRC \(isrc) — no composer returned"
        }
        return "probe: storefront \(storefront), ISRC \(isrc) -> "
            + "composer=\(credits.composer) genres=\(credits.genres.joined(separator: "|"))"
    }

    // MARK: - Persistence

    private static func loadCache() -> [String: Credits?] {
        guard let cacheURL, let data = try? Data(contentsOf: cacheURL),
              let stored = try? JSONDecoder().decode([String: Credits].self, from: data)
        else { return [:] }
        // An empty composer on disk is how "looked, found nothing" is stored,
        // the same trick `LyricsService` uses with an empty string — JSON holds
        // a plain dictionary far more simply than one of optionals.
        return stored.mapValues { $0.composer.isEmpty ? nil : $0 }
    }

    private func saveCache() {
        guard let url = Self.cacheURL else { return }
        let storable = cache.mapValues { $0 ?? Credits(composer: "", genres: []) }
        guard let data = try? JSONEncoder().encode(storable) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
