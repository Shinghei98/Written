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
        components?.queryItems = [
            URLQueryItem(name: "select", value: "user_id,display_name,age,district,photo_seeds,interests"),
            URLQueryItem(name: "order", value: "updated_at.desc"),
        ]
        guard let url = components?.url else { return [] }

        var request = URLRequest(url: url)
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                lastError = "Discovery failed (\(status))."
                return []
            }
            let rows = (try JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
            lastError = nil
            return rows.compactMap(Self.person(from:))
        } catch {
            lastError = error.localizedDescription
            return []
        }
    }

    /// A row that cannot be read is dropped rather than half-built. A card with
    /// no name and no photos is worse than one fewer person in the feed.
    private static func person(from row: [String: Any]) -> Person? {
        guard let id = row["user_id"] as? String,
              let name = row["display_name"] as? String
        else { return nil }

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
            interests: interests
        )
    }
}
