import Foundation

/// Reads the people a user can be shown.
///
/// The one query in this app that returns somebody else's data. It hits
/// `discovery_cards` and nothing else — see `0007_discovery.sql`, where that
/// table is deliberately not a view over `distilled_records`. Everything a card
/// prints is a column here; nothing here could rebuild a distillation.
///
/// The access token is still the user's own, so the read goes through row level
/// security exactly like `RestoreService` — what changed is the policy on one
/// table, not the way the app authenticates.
actor DiscoveryService {

    static let shared = DiscoveryService()

    /// One discoverable person, with everything the feed draws from.
    ///
    /// The *person*, not a profile. One of these produces many profiles — see
    /// `DiscoveryFeed` — which is why the photos and interests arrive as pools
    /// rather than as the two of each a card happens to show.
    struct Person: Identifiable, Equatable {
        let id: String
        let name: String
        let age: Int?
        let district: String?
        let photoSeeds: [Int]
        /// Object paths in `profile-photos`, in the order the person arranged
        /// them. Real photographs; `photoSeeds` is the synthetic accounts'
        /// generated stand-in and only one of the two is ever non-empty.
        let photoPaths: [String]
        let interests: [Interest]

        struct Interest: Equatable {
            let domain: Ontology.Domain
            let subject: String
        }
    }

    private(set) var lastError: String?

    func people() async -> [Person] {
        guard let token = await SupabaseAuth.shared.validAccessToken() else { return [] }

        var components = URLComponents(
            url: AppConfig.supabaseURL.appendingPathComponent("rest/v1/discovery_cards"),
            resolvingAgainstBaseURL: false
        )
        // Read after the token, never before: the refresh is what fills the id
        // in on a cold launch, and reading it first reports "not signed in" for
        // a session that is merely not restored yet.
        let me = await SupabaseAuth.shared.userID

        var query = [
            URLQueryItem(name: "select", value: Self.columns),
            URLQueryItem(name: "order", value: "updated_at.desc"),
        ]
        // **Everybody but you.** Nothing excluded the viewer, which cost
        // nothing while the only cards were the six synthetic ones — no real
        // account had a card to be shown its own. `DiscoveryCardService` now
        // publishes one for every user, so without this the first thing a person
        // would meet in Explore is themselves.
        //
        // Filtered in the query so the viewer's own card never crosses the wire.
        if let me {
            query.append(URLQueryItem(name: "user_id", value: "neq.\(me)"))
        }
        components?.queryItems = query
        guard let url = components?.url else { return [] }

        // **And again on the result, because the query filter is conditional.**
        // If the id were unavailable the `neq` above is simply not added, and
        // the request comes back with the viewer's own card in it — a guard that
        // silently does nothing is the shape of most of the bugs in this
        // project. `fetch` drops a row whose id matches whatever happened
        // upstream, and if the id is unknown then no card can match it and
        // nothing is lost.
        return await fetch(url, token: token, excluding: me) ?? []
    }

    /// The cards for a named set of people, for the bookmarks page.
    ///
    /// **Returns `nil` for *could not ask*, unlike `people()` above**, whose
    /// `[]`-on-failure the feed disambiguates through `lastError`. A new caller
    /// should not have to know that, and an empty bookmarks page and an
    /// unreachable server are two different screens.
    ///
    /// The viewer is not excluded here and does not need to be: `0035` forbids
    /// bookmarking yourself, so an id in that set is never your own.
    func people(ids: Set<String>) async -> [Person]? {
        guard !ids.isEmpty else { return [] }
        guard let token = await SupabaseAuth.shared.validAccessToken() else {
            lastError = "You're not signed in."
            return nil
        }

        var components = URLComponents(
            url: AppConfig.supabaseURL.appendingPathComponent("rest/v1/discovery_cards"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "select", value: Self.columns),
            // PostgREST's `in` list. Ids are uuids from our own table rather
            // than anything a user typed, so there is nothing here to quote.
            URLQueryItem(name: "user_id", value: "in.(\(ids.joined(separator: ",")))"),
            URLQueryItem(name: "order", value: "updated_at.desc"),
        ]
        guard let url = components?.url else { return nil }
        return await fetch(url, token: token, excluding: nil)
    }

    private static let columns =
        "user_id,display_name,age,district,photo_seeds,photo_paths,interests"

    /// One request, one parse, one place that decides what a failure looks like.
    private func fetch(_ url: URL, token: String, excluding me: String?) async -> [Person]? {
        var request = URLRequest(url: url)
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                lastError = "Discovery failed (\(status))."
                return nil
            }
            let rows = (try JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
            lastError = nil
            return rows
                .compactMap(Self.person(from:))
                .filter { $0.id != me }
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// A row that cannot be read is dropped rather than half-built. A card with
    /// no name and no photos is worse than one fewer person in the feed.
    private static func person(from row: [String: Any]) -> Person? {
        guard let id = row["user_id"] as? String,
              let name = row["display_name"] as? String
        else { return nil }

        // **Nobody without a face.** A card is only published once somebody has
        // photographs, so an empty pair here is a row from before that rule or a
        // person who removed theirs — either way there is nothing to draw, and a
        // profile that is a name over blank space is worse than one fewer
        // person in the feed.
        let paths = row["photo_paths"] as? [String] ?? []
        let seeds = row["photo_seeds"] as? [Int] ?? []
        guard !paths.isEmpty || !seeds.isEmpty else { return nil }

        let interests = (row["interests"] as? [[String: Any]] ?? []).compactMap {
            entry -> Person.Interest? in
            guard let raw = entry["domain"] as? String,
                  let domain = Ontology.Domain(rawValue: raw),
                  let subject = entry["subject"] as? String
            else { return nil }
            return Person.Interest(domain: domain, subject: subject)
        }

        return Person(
            id: id,
            name: name,
            age: row["age"] as? Int,
            district: row["district"] as? String,
            photoSeeds: row["photo_seeds"] as? [Int] ?? [],
            photoPaths: row["photo_paths"] as? [String] ?? [],
            interests: interests
        )
    }
}
