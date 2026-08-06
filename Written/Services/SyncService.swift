import Foundation

/// Pushes a distillation to Postgres.
///
/// **The device replaces; the server appends.** `replaceRecords(from:with:)`
/// swaps a source's rows in memory so a re-distill doesn't duplicate what the
/// dashboard shows, but `append_source_records` keeps every run — nothing in
/// Postgres is ever deleted. The two are read back into agreement by the
/// `summary_*` views, which return the latest row per item across all runs.
///
/// They used to agree by both replacing, and the cost was drift: that someone's
/// top artists differed in March is a fact about them, and it could not be
/// recovered once the March rows were gone.
///
/// **Health is not synced through here, and cannot be.** `push(source:records:)`
/// refuses it outright. Raw workouts, activity days and hourly steps stay on the
/// device; only the derived chronotype and sport levels travel, through
/// `pushHealthSignals`. The refusal is in code as well as in the schema — there
/// is no table those rows could land in — because a guarantee worth making is
/// worth enforcing twice.
actor SyncService {

    static let shared = SyncService()

    /// Never blocks the UI and never surfaces an error into it. A distillation
    /// that reached the device has already done its job; a failed upload is
    /// something to retry, not something to interrupt the garden with.
    private(set) var lastError: String?

    // MARK: - Records

    /// Sources whose raw rows never reach Postgres.
    ///
    /// **health** — raw workouts and activity rows are the sensitive part, so
    /// only the figures derived from them travel, via `pushHealthSignals`. The
    /// device discards the raw rows once it has derived them, so this guard is
    /// the second of two defences rather than the only one.
    ///
    /// Spotify was the other entry until it was dropped as a source: its
    /// Developer Terms forbid storing Spotify Content in a third-party database,
    /// which made it the one source that could never be restored to a new
    /// device once the server became the source of truth.
    private static let localOnlySources: Set<String> = ["health"]

    func push(source: String, records: [DistilledRecord]) async {
        guard !Self.localOnlySources.contains(source) else { return }
        guard let token = await SupabaseAuth.shared.validAccessToken() else { return }

        let payload = records.map(Self.row(for:))
        do {
            _ = try await post(
                path: "rest/v1/rpc/append_source_records",
                token: token,
                body: ["p_source": source, "p_records": payload]
            )
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// One record as the RPC expects it.
    ///
    /// Two shape changes happen here. `extra` is `key=value;key=value` on the
    /// device and becomes a JSON object, so the ontology stage can query
    /// `extra->>'genres'` instead of doing string surgery in SQL. And the
    /// removal note — which `BanList.markedRemoved` hides *inside* that same
    /// string — is lifted out into real columns, where it can be filtered on.
    private static func row(for record: DistilledRecord) -> [String: Any] {
        var extra = parseExtra(record.extra)
        let removedAt = extra.removeValue(forKey: DistilledRecord.removalKey)
        let removedReason = extra.removeValue(forKey: "removed_reason")

        return [
            "data_type": record.dataType,
            "item_id": record.itemID,
            "name": record.name,
            "creator": record.creator,
            "detail": record.detail,
            "extra": extra,
            "collected_at": ISO8601DateFormatter().string(from: record.collectedAt),
            "removed_at": removedAt as Any,
            "removed_reason": removedReason as Any
        ]
    }

    /// The same grammar `DistilledRecord.extraValue` reads, parsed whole.
    ///
    /// Values are left as strings rather than guessed into numbers: `play_count`
    /// and `steps` are numeric, but `genres` is pipe-separated and `first_move`
    /// is a clock time, and a parser that sometimes returns a number is worse to
    /// query than one that never does.
    private static func parseExtra(_ extra: String) -> [String: String] {
        var parsed: [String: String] = [:]
        for pair in extra.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { continue }
            parsed[String(parts[0])] = String(parts[1])
        }
        return parsed
    }

    // MARK: - The user object

    /// The attributes that belong to the person rather than to an observation:
    /// age, sex, where they are, and the seed their plant is drawn from.
    ///
    /// These were `distilled_records` rows and are columns now. Two of them had
    /// nowhere else to go once raw HealthKit rows stopped being kept: age and
    /// sex come from Health, whose rows are never uploaded, so without this a
    /// restored account would have no idea how old anyone was.
    ///
    /// Every argument is optional and nil ones are omitted rather than sent as
    /// null — the caller usually knows one fact, not all four, and a full
    /// overwrite would erase the other three.
    /// Returns whether the row reached Postgres.
    ///
    /// It used to return nothing and swallow the error, which was fine while
    /// every caller was a background push. It is not fine for a field the user
    /// just typed: the server is the record, so the only way a local copy can
    /// avoid drifting from it is to know whether the write landed.
    @discardableResult
    func pushUserObject(
        birthDate: Date? = nil,
        birthYear: Int? = nil,
        sex: String? = nil,
        place: String? = nil,
        treeSeed: UInt64? = nil
    ) async -> Bool {
        // Both early returns record *why*, because `lastError` is now read and
        // shown. Returning false without setting it made a session that could
        // not be refreshed report itself as a network problem, which is the one
        // wrong answer here: it sends the user to look at their signal when the
        // fix is to sign in again.
        // The token first and `userID` second, never the other way round: on a
        // cold launch both are empty until `validAccessToken()` has been through
        // `restoreSession()`, and that call is what fills in the id. Reading the
        // id first reports "not signed in" for a session that is merely not yet
        // restored — the same mistake `upsertProfile` made for real.
        guard let token = await SupabaseAuth.shared.validAccessToken() else {
            // Whichever of the three it actually was — signed out, expired, or
            // unreachable. Guessing here is what made a network fault read as a
            // dead session.
            lastError = await SupabaseAuth.shared.lastTokenFailure?.message
                ?? "your session couldn't be refreshed."
            return false
        }
        guard let userID = await SupabaseAuth.shared.userID else {
            lastError = "you're not signed in."
            return false
        }

        var row: [String: Any] = ["id": userID]
        if let birthDate { row["birth_date"] = Self.day.string(from: birthDate) }
        if let birthYear { row["birth_year"] = birthYear }
        if let sex { row["sex"] = sex }
        if let place { row["place"] = place }
        if let treeSeed { row["tree_seed"] = Int64(bitPattern: treeSeed) }
        // Nothing but the id: no caller does this, but a stale `lastError` from
        // a previous push would be reported as this one's reason.
        guard row.count > 1 else {
            lastError = "there was nothing to save."
            return false
        }

        do {
            _ = try await post(
                path: "rest/v1/users",
                token: token,
                body: [row],
                prefer: "resolution=merge-duplicates,return=minimal"
            )
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// `birth_date` is a `date`, not a timestamp — an ISO-8601 datetime is
    /// rejected by the column.
    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    // MARK: - Connections

    /// Records that a source was connected, for sources whose records never go
    /// through `push`.
    ///
    /// `append_source_records` already upserts this row for every source it
    /// writes, so only Health needs it explicitly — and Health needs it most,
    /// because it is about to have no records at all. Without this its branch
    /// would read as never connected the moment its raw rows stop being kept.
    func pushConnection(source: String, recordCount: Int) async {
        guard let token = await SupabaseAuth.shared.validAccessToken(),
              let userID = await SupabaseAuth.shared.userID
        else { return }

        do {
            _ = try await post(
                path: "rest/v1/source_connections",
                token: token,
                body: [[
                    "user_id": userID,
                    "source": source,
                    "last_distilled_at": ISO8601DateFormatter().string(from: Date()),
                    "record_count": recordCount
                ]],
                prefer: "resolution=merge-duplicates,return=minimal"
            )
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Health, derived only

    func pushHealthSignals(
        chronotype: LifestyleHighlights.Chronotype?,
        sports: [LifestyleHighlights.Sport],
        hourlyActivity: [Double],
        averageDailySteps: Int?
    ) async {
        guard let token = await SupabaseAuth.shared.validAccessToken(),
              let userID = await SupabaseAuth.shared.userID
        else { return }

        var signals: [String: Any] = ["user_id": userID, "updated_at": ISO8601DateFormatter().string(from: Date())]
        if let chronotype {
            signals["chronotype_label"] = chronotype.label
            signals["median_wake_minutes"] = chronotype.medianWakeMinutes
            signals["spread_minutes"] = chronotype.spreadMinutes
            signals["days_observed"] = chronotype.days
        }
        if let averageDailySteps { signals["average_daily_steps"] = averageDailySteps }
        if !hourlyActivity.isEmpty { signals["hourly_activity"] = hourlyActivity }

        do {
            // A new row per run rather than an upsert over the last one.
            _ = try await post(
                path: "rest/v1/health_signals",
                token: token,
                body: [signals],
                prefer: "return=minimal"
            )

            // Appended, never replaced. An earlier version of this deleted the
            // user's sports before inserting, so a workout type they stopped
            // doing wouldn't linger — which also threw away every previous
            // reading. A sport that has dropped out of the 365-day window still
            // belongs to them; the `summary_health_sports` view keeps it, with
            // the last figures ever recorded for it.
            if !sports.isEmpty {
                _ = try await post(
                    path: "rest/v1/health_sports",
                    token: token,
                    body: sports.map {
                        ["user_id": userID, "sport": $0.name, "sessions": $0.sessions, "minutes": $0.minutes]
                    },
                    prefer: "return=minimal"
                )
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }


    // MARK: - Bans

    func pushBans(_ bans: BanList) async {
        guard let token = await SupabaseAuth.shared.validAccessToken(),
              let userID = await SupabaseAuth.shared.userID,
              !bans.isEmpty
        else { return }

        do {
            _ = try await post(
                path: "rest/v1/bans",
                token: token,
                body: bans.entries.map {
                    [
                        "user_id": userID,
                        "kind": $0.kind.rawValue,
                        "value": $0.key,
                        "banned_at": ISO8601DateFormatter().string(from: $0.bannedAt)
                    ]
                },
                prefer: "resolution=merge-duplicates,return=minimal"
            )
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Transport

    private enum SyncError: LocalizedError {
        case server(String)
        var errorDescription: String? { if case .server(let m) = self { return m } else { return nil } }
    }

    @discardableResult
    /// Erases one source's rows from the server, permanently.
    ///
    /// **The one place this schema deletes, and it is not a change of mind.**
    /// Everything else here appends: `append_source_records` stamps a run and
    /// keeps every earlier version, and a row the user struck off is *annotated*
    /// rather than removed, because the ontology stage needs "collected then
    /// struck off" to be a different fact from "never collected". That rule
    /// holds for every source and every reason but this one.
    ///
    /// The exception is not ours to decline. YouTube's Developer Policies give
    /// 7 calendar days to delete Authorized Data when a user revokes through the
    /// client (III.D.2.c.1) or asks for deletion (III.E.4.g). An annotation is
    /// not a deletion, and "we kept it, marked as removed" is the answer that
    /// fails an audit.
    ///
    /// No edge function: `0001`'s policies are `for all using (auth.uid() =
    /// user_id)`, which covers delete, so the session can only ever reach its
    /// own rows and the filter below is a convenience rather than the security.
    ///
    /// Returns nil on success, or why it failed — the caller has to know,
    /// because a deletion the user asked for and did not get is the one failure
    /// here that must not be silent. That is the tenth time this codebase has
    /// had to learn it.
    func deleteSource(_ source: String) async -> String? {
        guard let token = await SupabaseAuth.shared.validAccessToken() else {
            lastError = "Not signed in."
            return lastError
        }

        for table in ["distilled_records", "source_connections"] {
            do {
                _ = try await delete(table: table, source: source, token: token)
            } catch {
                lastError = error.localizedDescription
                return lastError
            }
        }
        lastError = nil
        return nil
    }

    /// **Built with `URLComponents`, not by appending a string.**
    /// `appendingPathComponent` escapes the `?`, so
    /// `distilled_records?source=eq.youtube` becomes a request for a table
    /// literally named that — PostgREST answers 404 and the filter never
    /// applies. Getting it wrong the other way would be worse: a DELETE that
    /// reached the table with no filter at all.
    /// Erases every distillation this account has, and the derived health
    /// figures with it.
    ///
    /// **Behind "Disconnect all", which is one action rather than five.**
    /// `deleteSource` handles one source at a time and is still what the
    /// per-source controls use; this is the whole lot, including sources that
    /// were connected on another device and are not in this one's
    /// `knownConnections`. Deleting only what the phone remembers would leave
    /// rows nobody could see and nobody could remove.
    ///
    /// `health_signals` and `health_sports` are included because they are the
    /// only thing Health leaves behind — the raw samples were never uploaded,
    /// so without these two a disconnected Health account would keep answering
    /// for the chronotype and the sport levels on the profile.
    ///
    /// Returns nil on success or the first failure's message. Reported rather
    /// than swallowed: somebody who asked for everything to go and got a
    /// partial result must not be told it worked.
    func deleteEverything() async -> String? {
        guard let token = await SupabaseAuth.shared.validAccessToken() else {
            lastError = "Not signed in."
            return lastError
        }
        // Read *after* the token: the refresh is what fills the id in on a cold
        // launch, and reading it first reports "not signed in" for a session
        // that is merely not restored yet.
        guard let userID = await SupabaseAuth.shared.userID else {
            lastError = "No account id."
            return lastError
        }

        for table in ["distilled_records", "source_connections",
                      "health_signals", "health_sports"] {
            do {
                _ = try await delete(table: table, filter: ("user_id", userID), token: token)
            } catch {
                lastError = error.localizedDescription
                return lastError
            }
        }
        lastError = nil
        return nil
    }

    private func delete(table: String, source: String, token: String) async throws -> Data {
        try await delete(table: table, filter: ("source", source), token: token)
    }

    private func delete(
        table: String,
        filter: (column: String, value: String),
        token: String
    ) async throws -> Data {
        var components = URLComponents(
            url: AppConfig.supabaseURL.appendingPathComponent("rest/v1/\(table)"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: filter.column, value: "eq.\(filter.value)")
        ]
        guard let url = components?.url else {
            throw SyncError.server("Could not form the delete request.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0?["message"] as? String }
            throw SyncError.server(detail ?? "Delete failed (\(status)).")
        }
        return data
    }

    private func post(
        path: String,
        token: String,
        body: Any,
        prefer: String? = nil
    ) async throws -> Data {
        var request = URLRequest(url: AppConfig.supabaseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let prefer { request.setValue(prefer, forHTTPHeaderField: "Prefer") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0?["message"] as? String }
            throw SyncError.server(detail ?? "Sync failed (\(status)).")
        }
        return data
    }
}
