import Foundation

/// Videos people have shared into the feed.
///
/// Reads and writes `shared_posts` — see `0008_shared_posts.sql`, where that
/// table is the second and last thing one user may read about another. The
/// access token is the user's own, so this goes through row level security
/// exactly like `DiscoveryService`; what changed is the policy on one table,
/// not how the app authenticates.
actor SharedPostService {

    static let shared = SharedPostService()

    /// Where a shared video came from.
    ///
    /// An enum and a URL builder rather than a branch scattered through the
    /// feed, so Instagram is one case and one line when a Meta token exists.
    /// Its official `instagram_oembed` needs `oembed_read` behind App Review,
    /// and that token is a real secret — unlike the OAuth client IDs in
    /// `AppConfig`, it cannot ship in the binary and will need an edge function
    /// to proxy.
    enum Provider: String {
        case youtube

        /// The page to load in the web view.
        ///
        /// `playsinline` keeps it in the card on iPhone, where a tapped video
        /// otherwise takes over the whole screen; `rel=0` stops the end screen
        /// offering someone else's videos, which in a feed reads as the app
        /// handing the reader off.
        func embed(_ videoID: String) -> URL? {
            switch self {
            case .youtube:
                return URL(string: "https://www.youtube-nocookie.com/embed/\(videoID)?playsinline=1&rel=0")
            }
        }
    }

    struct Post: Identifiable, Equatable {
        let id: String
        let sharerName: String
        let provider: Provider
        let videoID: String
        let message: String?
        let createdAt: Date
    }

    enum ShareError: LocalizedError {
        case unsupported
        case notSignedIn
        case server(String)

        var errorDescription: String? {
            switch self {
            case .unsupported:
                return "That doesn't look like a YouTube link. Paste the link to a video, a Short, or a youtu.be address."
            case .notSignedIn:
                return "You need to be signed in to share."
            case .server(let detail):
                return detail
            }
        }
    }

    private(set) var lastError: String?

    // MARK: - Reading

    func posts(limit: Int = 40) async -> [Post] {
        guard let token = await SupabaseAuth.shared.validAccessToken() else { return [] }

        var components = URLComponents(
            url: AppConfig.supabaseURL.appendingPathComponent("rest/v1/shared_posts"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "select", value: "id,sharer_name,provider,video_id,message,created_at"),
            URLQueryItem(name: "order", value: "created_at.desc"),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        guard let url = components?.url else { return [] }

        var request = URLRequest(url: url)
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0) else {
                lastError = "Couldn't load shared videos."
                return []
            }
            let rows = (try JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
            lastError = nil
            return rows.compactMap(Self.post(from:))
        } catch {
            lastError = error.localizedDescription
            return []
        }
    }

    // MARK: - Writing

    /// Shares a link, or says why it can't.
    ///
    /// Throws rather than returning nil so the sheet can tell "that isn't a
    /// video" from "that didn't reach the server" — they need different words
    /// and only one of them is worth retrying.
    @discardableResult
    func share(link: String, message: String?) async throws -> Post {
        guard let parsed = Self.parse(link) else { throw ShareError.unsupported }
        guard let token = await SupabaseAuth.shared.validAccessToken(),
              let userID = await SupabaseAuth.shared.userID
        else { throw ShareError.notSignedIn }

        let name = await SupabaseAuth.shared.firstName ?? "Someone"
        let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines)

        var request = URLRequest(
            url: AppConfig.supabaseURL.appendingPathComponent("rest/v1/shared_posts")
        )
        request.httpMethod = "POST"
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("return=representation", forHTTPHeaderField: "Prefer")

        var row: [String: Any] = [
            "sharer_id": userID,
            "sharer_name": name,
            "provider": parsed.provider.rawValue,
            "video_id": parsed.videoID,
        ]
        if let trimmed, !trimmed.isEmpty { row["message"] = trimmed }
        request.httpBody = try JSONSerialization.data(withJSONObject: [row])

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0?["message"] as? String }
            throw ShareError.server(detail ?? "Couldn't share that (\(status)).")
        }

        let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
        guard let post = rows.first.flatMap(Self.post(from:)) else {
            throw ShareError.server("Shared, but the post came back unreadable.")
        }
        return post
    }

    // MARK: - Links

    /// Pulls the video id out of whatever form the link takes.
    ///
    /// A watch link, a `youtu.be` link, a Short and an embed URL are four ways
    /// of writing one video, and storing what was typed would make them four
    /// different posts. The id is the identity; the URL is how someone happened
    /// to arrive at it.
    ///
    /// Returns nil rather than guessing. A link that yields no id has to be
    /// refused at the sheet, because a row stored without one is a card that
    /// can never render and nothing downstream would notice.
    static func parse(_ link: String) -> (provider: Provider, videoID: String)? {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host?.lowercased() else { return nil }

        let path = url.pathComponents.filter { $0 != "/" }

        // youtu.be/<id>
        if host.hasSuffix("youtu.be") {
            return path.first.flatMap { id in valid(id).map { (.youtube, $0) } }
        }

        guard host.hasSuffix("youtube.com") || host.hasSuffix("youtube-nocookie.com") else {
            return nil
        }

        // /watch?v=<id>
        if path.first == "watch",
           let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "v" })?.value,
           let id = valid(v) {
            return (.youtube, id)
        }

        // /shorts/<id>, /embed/<id>, /live/<id> — the id is always the segment
        // after the kind, so they are one case rather than three.
        if let kind = path.first, ["shorts", "embed", "live", "v"].contains(kind),
           path.count > 1, let id = valid(path[1]) {
            return (.youtube, id)
        }

        return nil
    }

    /// YouTube ids are 11 characters of an unpadded base64url alphabet. Checked
    /// because the path segment after `/shorts/` is otherwise whatever the URL
    /// happened to contain — including a trailing slug or a query fragment that
    /// would be stored as an id and render as nothing.
    private static func valid(_ candidate: String) -> String? {
        let id = candidate.prefix(while: { $0 != "?" && $0 != "&" })
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        guard id.count == 11, id.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return String(id)
    }

    private static func post(from row: [String: Any]) -> Post? {
        guard let id = row["id"] as? String,
              let name = row["sharer_name"] as? String,
              let rawProvider = row["provider"] as? String,
              let provider = Provider(rawValue: rawProvider),
              let videoID = row["video_id"] as? String
        else { return nil }

        return Post(
            id: id,
            sharerName: name,
            provider: provider,
            videoID: videoID,
            message: row["message"] as? String,
            createdAt: (row["created_at"] as? String).flatMap(Self.date(from:)) ?? Date()
        )
    }

    /// Postgres returns fractional seconds, which plain `ISO8601DateFormatter`
    /// rejects — the same trap `RestoreService` documents.
    private static func date(from text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
