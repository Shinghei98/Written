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
/// **Health takes the same path as every other source, and this paragraph said
/// the opposite for months while the code disagreed.** It claimed `push` refused
/// health outright; `localOnlySources` is empty and `push` does no such thing.
/// What was true was worse than the claim: `DistillViewModel.sync` never called
/// `push` for health at all, so `distilled_records` held **zero** rows with
/// `source='health'` for every account that had ever connected it, while
/// `source_connections` and `health_signals` both looked healthy. Nothing looked
/// wrong because the half that failed was the invisible half.
///
/// The one row-level exception is real and remains: `health/biological_sex` is
/// refused at the wire by `localOnlyTypes`, because it is a protected
/// characteristic, nothing downstream asks for it, and `public.users.sex`
/// already means the gender somebody *chose*. It is still kept locally and still
/// in the owner's own export.
actor SyncService {

    static let shared = SyncService()

    /// The reason the *last* call failed, for the callers that ask right after
    /// making one — `accepted(_:)` on the biographics path is the only one.
    ///
    /// **It is not a record of what went wrong on the record path, and reading
    /// it as one is a mistake.** Every function here writes this field, and the
    /// four the record path calls run back to back in one detached task: a
    /// failed `push` followed by a successful `pushBans` clears the very reason
    /// the distillation is missing. Whether it survived at all depended on
    /// whether that person happened to have struck anything off.
    ///
    /// Anything that needs to know why an upload failed takes the returned
    /// `String?` instead, which belongs to that call and cannot be overwritten
    /// by the next one. Same shape as `deleteSource`.
    private(set) var lastError: String?

    // MARK: - Records

    /// Sources whose raw rows never reach Postgres.
    ///
    /// **Empty, and kept.** `health` was the last entry: raw workouts and
    /// activity rows were withheld and only the derived figures travelled. That
    /// was decided on volume, and the volume was never there — the distiller
    /// aggregates before it makes a record, so a year of Health is about 400 to
    /// 700 rows. What it actually cost was an export with nothing in it.
    ///
    /// Spotify was the other entry until it was dropped as a source: its
    /// Developer Terms forbid storing Spotify Content in a third-party database,
    /// which made it the one source that could never be restored to a new
    /// device once the server became the source of truth. That is the shape of
    /// thing this list is for — a whole source that may not be stored — and it
    /// is worth keeping empty rather than deleting, because the next one will
    /// arrive the same way.
    private static let localOnlySources: Set<String> = []

    /// Individual rows that are read, kept and exported, but never uploaded.
    ///
    /// **`source/data_type`, because the unit of this decision is a row.**
    /// Withholding a whole source was too blunt once Health's workouts and
    /// activity became worth having: one row out of five had to stay behind and
    /// the other four had to travel.
    ///
    /// **`health/biological_sex`** is a protected characteristic. Nothing
    /// downstream asks for it, and `public.users.sex` already means the gender
    /// somebody *chose* — two fields accepting the same words is precisely how
    /// HealthKit came to overwrite a chosen gender, silently and repeatedly, and
    /// worst for the people it matters most to. It stays on the device, where
    /// the export can still show it to its owner.
    ///
    /// Omitting a row is safe rather than destructive: `append_source_records`
    /// appends and its trigger drops rows identical to the newest version, so a
    /// type that never arrives simply never exists server-side.
    /// **Internal, because withholding a row is only half of it.** The server is
    /// the source of truth and `apply(_:)` replaces the local cache with its
    /// copy, so a row that never uploads is a row that survives exactly until
    /// the next hydration — which is every launch. `DistillViewModel` reads this
    /// to carry them across. Refusing to send and refusing to forget are one
    /// decision and have to be made in one place.
    static let localOnlyTypes: Set<String> = ["health/biological_sex"]

    /// Whether this row is kept on the device and never uploaded.
    static func isLocalOnly(_ record: DistilledRecord) -> Bool {
        localOnlySources.contains(record.source)
            || localOnlyTypes.contains("\(record.source)/\(record.dataType)")
    }

    /// Returns nil when the rows landed, and why not when they didn't.
    ///
    /// **A refused row is not a failure**, so a push left with nothing to send
    /// answers nil: there is nothing to report about rows that were never meant
    /// to travel.
    @discardableResult
    func push(source: String, records: [DistilledRecord]) async -> String? {
        guard !Self.localOnlySources.contains(source) else { return nil }
        let sendable = records.filter {
            !Self.localOnlyTypes.contains("\($0.source)/\($0.dataType)")
        }
        // **An empty push is not the same as nothing to push**, and conflating
        // them would have been a quiet regression: `append_source_records`
        // upserts `source_connections` even from an empty array, which is how a
        // source that legitimately returned nothing still registers as
        // connected. Podcasts is the case that matters — zero is its normal
        // answer. So this returns early only when rows existed and every one was
        // withheld, never when the source simply had none.
        guard !(sendable.isEmpty && !records.isEmpty) else { return nil }
        let records = sendable
        // This used to be a bare `else { return }`, which is the whole of why a
        // lost distillation had nothing to say for itself: the one failure that
        // takes every row with it left no trace at all.
        guard let token = await SupabaseAuth.shared.validAccessToken() else {
            lastError = await SupabaseAuth.shared.lastTokenFailure?.message
                ?? "your session couldn't be refreshed."
            return lastError
        }

        let payload = records.map(Self.row(for:))
        do {
            _ = try await post(
                path: "rest/v1/rpc/append_source_records",
                token: token,
                body: ["p_source": source, "p_records": payload]
            )
            lastError = nil
            return nil
        } catch {
            lastError = error.localizedDescription
            return lastError
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
        treeSeed: UInt64? = nil,
        // The four `0034` added. They are columns rather than `user` records
        // for one reason: `loadProfile` has to read them back in the single
        // request that decides the launch route, and a record cannot answer
        // until `RestoreService.hydrate()` runs — which is after the route.
        hasExplored: Bool? = nil,
        interestedIn: [String]? = nil,
        flirtLevel: String? = nil,
        responseTime: String? = nil
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
        if let hasExplored { row["has_explored"] = hasExplored }
        if let interestedIn { row["interested_in"] = interestedIn }
        if let flirtLevel { row["flirt_level"] = flirtLevel }
        if let responseTime { row["response_time"] = responseTime }
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
    ///
    /// **`en_US_POSIX` as well as the calendar**, and both are load-bearing on a
    /// fixed format. The calendar stops a Buddhist or Persian device writing the
    /// wrong year; the locale stops one set to Arabic or Devanagari numerals
    /// writing digits Postgres will not parse. `SupabaseAuth.day` reads this
    /// column back and the two must agree.
    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
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
    @discardableResult
    func pushConnection(source: String, recordCount: Int) async -> String? {
        guard let token = await SupabaseAuth.shared.validAccessToken() else {
            lastError = await SupabaseAuth.shared.lastTokenFailure?.message
                ?? "your session couldn't be refreshed."
            return lastError
        }
        guard let userID = await SupabaseAuth.shared.userID else {
            lastError = "you're not signed in."
            return lastError
        }

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
            return nil
        } catch {
            lastError = error.localizedDescription
            return lastError
        }
    }

    // MARK: - Health, derived only

    @discardableResult
    func pushHealthSignals(
        chronotype: LifestyleHighlights.Chronotype?,
        sports: [LifestyleHighlights.Sport],
        hourlyActivity: [Double],
        averageDailySteps: Int?
    ) async -> String? {
        guard let token = await SupabaseAuth.shared.validAccessToken() else {
            lastError = await SupabaseAuth.shared.lastTokenFailure?.message
                ?? "your session couldn't be refreshed."
            return lastError
        }
        guard let userID = await SupabaseAuth.shared.userID else {
            lastError = "you're not signed in."
            return lastError
        }

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
            return nil
        } catch {
            lastError = error.localizedDescription
            return lastError
        }
    }


    // MARK: - Bans

    /// **An empty list is not a failure and must not clear `lastError`.** It is
    /// the ordinary case, and this runs immediately after `push` on the same
    /// task — treating "nothing to send" as a success is how a lost
    /// distillation's reason used to disappear for anyone with a ban.
    @discardableResult
    func pushBans(_ bans: BanList) async -> String? {
        guard !bans.isEmpty else { return nil }
        guard let token = await SupabaseAuth.shared.validAccessToken() else {
            lastError = await SupabaseAuth.shared.lastTokenFailure?.message
                ?? "your session couldn't be refreshed."
            return lastError
        }
        guard let userID = await SupabaseAuth.shared.userID else {
            lastError = "you're not signed in."
            return lastError
        }

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
            return nil
        } catch {
            lastError = error.localizedDescription
            return lastError
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

        // **`user` rows are kept, and the distinction is the whole point of the
        // control.** *Disconnect all* means every distillation — what the app
        // read out of other apps — and not the profile somebody typed into this
        // one. `IdentitySummary` builds age, gender, education, occupation, bio
        // and both communication bands from `source == "user"` records, so
        // deleting them signed a person out of their own answers: they came
        // back to a profile with no school and no occupation, having asked only
        // for their music and calendar to go.
        //
        // Health's `age` and `biological_sex` *are* distilled and do go, along
        // with the derived figures below; the entered values outrank them in
        // `IdentitySummary` anyway, so what a person typed still shows.
        for table in ["distilled_records", "source_connections"] {
            do {
                _ = try await delete(
                    table: table, filter: ("user_id", userID),
                    excluding: ("source", "user"), token: token
                )
            } catch {
                lastError = error.localizedDescription
                return lastError
            }
        }

        // Neither table has a `source` column, and both hold only derived
        // Health figures — the raw samples were never uploaded, so without
        // these a disconnected Health account keeps answering for the
        // chronotype and the sport levels.
        for table in ["health_signals", "health_sports"] {
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
        excluding: (column: String, value: String)? = nil,
        token: String
    ) async throws -> Data {
        var components = URLComponents(
            url: AppConfig.supabaseURL.appendingPathComponent("rest/v1/\(table)"),
            resolvingAgainstBaseURL: false
        )
        // **`URLComponents`, and both filters go through it.** The `?` in a
        // PostgREST query is not a path component: `appendingPathComponent`
        // escapes it and asks for a table with a question mark in its name,
        // which 404s. The unlucky version of that mistake is a DELETE that
        // reaches the table with no filter at all.
        components?.queryItems = [
            URLQueryItem(name: filter.column, value: "eq.\(filter.value)")
        ]
        if let excluding {
            components?.queryItems?.append(
                URLQueryItem(name: excluding.column, value: "neq.\(excluding.value)")
            )
        }
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
