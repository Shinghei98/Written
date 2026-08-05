import Foundation

/// The PostgREST plumbing — one URL builder, one authenticated request, one date
/// parser.
///
/// `DiscoveryService`, `SharedPostService`, `SyncService` and `RestoreService`
/// each hand-roll this, which was fine at two and is why the fifth and sixth
/// copies live here instead. Those four predate it and can migrate whenever one
/// of them is next touched; nothing about this changes their behaviour.
///
/// Stateless on purpose: a `struct` with a stored token would have to be rebuilt
/// every time one expired, and `SupabaseAuth.validAccessToken()` already refreshes
/// on demand.
enum PostgREST {

    enum Failure: LocalizedError {
        case notSignedIn
        /// The status, plus whatever PostgREST said about it. `42501` in the body
        /// is a row-level-security refusal, which is the one worth recognising:
        /// it means the request was well-formed and the policy said no.
        case server(status: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .notSignedIn:
                return "You're not signed in."
            case .server(let status, let message):
                return message.isEmpty ? "Request failed (\(status))." : message
            }
        }
    }

    /// `GET`, decoded as an array of rows.
    static func rows(
        _ path: String,
        query: [String: String]
    ) async throws -> [[String: Any]] {
        let data = try await send("GET", path: path, query: query, body: nil, prefer: nil)
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
    }

    /// `POST`. `prefer` carries the upsert and return-shape headers.
    @discardableResult
    static func insert(
        _ path: String,
        body: Any,
        prefer: String? = "return=minimal"
    ) async throws -> [[String: Any]] {
        let data = try await send("POST", path: path, query: [:], body: body, prefer: prefer)
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
    }

    /// `PATCH`, which is how a status is answered.
    @discardableResult
    static func update(
        _ path: String,
        query: [String: String],
        body: [String: Any],
        prefer: String? = "return=minimal"
    ) async throws -> [[String: Any]] {
        let data = try await send("PATCH", path: path, query: query, body: body, prefer: prefer)
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
    }

    /// `DELETE`, for the one row a caller owns and wants gone.
    ///
    /// Rare in this schema on purpose — "nothing in Postgres is ever deleted" is
    /// the standing rule — and the exceptions are the ones where keeping a row
    /// is the mistake: `remove_list` because a preference must be changeable,
    /// and `device_tokens` because a stale token sends somebody's notification
    /// to a phone they no longer hold.
    @discardableResult
    static func delete(
        _ path: String,
        query: [String: String],
        prefer: String? = "return=minimal"
    ) async throws -> [[String: Any]] {
        let data = try await send("DELETE", path: path, query: query, body: nil, prefer: prefer)
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
    }

    private static func send(
        _ method: String,
        path: String,
        query: [String: String],
        body: Any?,
        prefer: String?
    ) async throws -> Data {
        guard let token = await SupabaseAuth.shared.validAccessToken() else {
            throw Failure.notSignedIn
        }

        var components = URLComponents(
            url: AppConfig.supabaseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )
        if !query.isEmpty {
            components?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components?.url else {
            throw Failure.server(status: 0, message: "Bad URL for \(path).")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let prefer { request.setValue(prefer, forHTTPHeaderField: "Prefer") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = [payload?["message"], payload?["details"], payload?["code"]]
                .compactMap { $0 as? String }
                .joined(separator: " — ")
            throw Failure.server(status: status, message: message)
        }
        return data
    }

    // MARK: - Timestamps

    /// PostgREST writes `timestamptz` with microseconds, which the plain
    /// ISO-8601 formatter rejects outright — and *without* them when the value
    /// happens to land on a whole second, which the fractional formatter rejects
    /// just as flatly. Both, in that order, is the only thing that reads every
    /// row.
    static func date(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    /// The other direction, for a column being written.
    static func string(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
