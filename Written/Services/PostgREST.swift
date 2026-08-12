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
        /// The status, PostgREST's own error code, and whatever it said about
        /// it. **The code is carried separately rather than only folded into
        /// the message**, because two of them mean something a caller can act
        /// on: `42501` is a row-level-security refusal — the request was
        /// well-formed and the policy said no — and `23503` is a foreign key
        /// with nothing behind it, which in this schema means the person you
        /// are writing about has deleted their account.
        case server(status: Int, code: String?, message: String)

        var errorDescription: String? {
            switch self {
            case .notSignedIn:
                return "You're not signed in."
            case .server(_, _, let message) where !message.isEmpty:
                return message
            case .server(let status, _, _):
                return "Request failed (\(status))."
            }
        }
    }

    /// Whether this failure was a foreign key pointing at a row that is gone.
    ///
    /// **In this schema that means one thing: the person has deleted their
    /// account.** Every foreign key here leads back to `public.users`, and
    /// deleting an account cascades from `auth.users` through it — so `23503`
    /// is not a bug to report but a fact to act on, and the caller's job is to
    /// take that person off the screen rather than to show somebody
    /// `violates foreign key constraint "likes_liked_id_fkey"`.
    static func isMissingPerson(_ error: Error) -> Bool {
        guard case Failure.server(_, let code, _)? = error as? Failure else { return false }
        return code == "23503"
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

    /// A function call in the `api` schema.
    ///
    /// **The schema header is the whole of why this is separate from `insert`.**
    /// PostgREST resolves an unqualified `rpc/name` against its *exposed*
    /// schemas, and with more than one exposed it uses the first unless a
    /// request says otherwise. Sending `Content-Profile: api` names the schema
    /// per request, so `public` stays the default for every other call in the
    /// app and nothing else has to change.
    ///
    /// **`api` must also be in the project's exposed schemas**, which is a
    /// dashboard setting and not something a migration can do. Without it every
    /// call here answers `PGRST202` — *"Searched for the function
    /// public.list_assertions… no matches were found in the schema cache"* —
    /// which names `public` and reads as a missing function rather than as an
    /// unexposed schema. Measured before any of this was written, precisely so
    /// it would not be diagnosed from inside the app.
    static func callFunction(
        _ name: String,
        arguments: [String: Any] = [:]
    ) async throws -> [[String: Any]] {
        let data = try await send(
            "POST", path: "rest/v1/rpc/\(name)", query: [:],
            body: arguments, prefer: nil, schema: "api"
        )
        // A set-returning function answers an array; a scalar one answers a
        // bare value. Both are wrapped so a caller reads one shape.
        //
        // **`.allowFragments`, and without it the scalar case silently returned
        // nothing.** A function returning `uuid` answers `"a1b2-…"` — a
        // top-level JSON string, which `JSONSerialization` refuses by default as
        // not being an object or an array. So `record_assertion_exposure`
        // parsed to nil, the exposure id was never read, and every confirm and
        // suppress that depended on it failed with no error worth reporting:
        // the request had succeeded and only the reading of it had not.
        if let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
            return rows
        }
        if let scalar = try? JSONSerialization.jsonObject(
            with: data, options: [.allowFragments]
        ) {
            return [["value": scalar]]
        }
        return []
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
        prefer: String?,
        schema: String? = nil
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
            throw Failure.server(status: 0, code: nil, message: "Bad URL for \(path).")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let prefer { request.setValue(prefer, forHTTPHeaderField: "Prefer") }
        // Both headers, because PostgREST reads `Accept-Profile` for reads and
        // `Content-Profile` for writes — and an RPC is a POST that reads.
        // Setting only one sends half the calls to `public`, where none of
        // these functions exists.
        if let schema {
            request.setValue(schema, forHTTPHeaderField: "Content-Profile")
            request.setValue(schema, forHTTPHeaderField: "Accept-Profile")
        }
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
            throw Failure.server(
                status: status,
                code: payload?["code"] as? String,
                message: message
            )
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
