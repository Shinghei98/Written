import Foundation

/// Reads an account's state back out of Postgres.
///
/// The missing half of `SyncService`. Sync has pushed since the backend landed
/// and nothing has ever pulled, which made the server a backup nobody restored
/// from: every row safe in Postgres, and a reinstall or a new phone starting at
/// bare soil regardless.
///
/// Everything here is a plain `GET` under row-level security — the access token
/// is the user's own, so `auth.uid()` decides what comes back and there is no
/// user id in any query. `RecordStore` is now a cache in front of this rather
/// than the record itself.
actor RestoreService {

    static let shared = RestoreService()

    /// Everything one account has on the server.
    struct Snapshot {
        var records: [DistilledRecord] = []
        var connectedSources: Set<String> = []
        var bans = BanList()
        var lifestyle: Lifestyle?
        var identity = IdentitySummary()
        var treeSeed: UInt64?
        var lastCollectedAt: Date?
    }

    /// The derived health figures, which are all that ever leaves the device.
    ///
    /// Kept as one value rather than four loose optionals because they are
    /// written and read as a set: a restore that produced sports without a
    /// chronotype would be a half-applied answer, and the lifestyle card would
    /// have no way to tell that from "no data".
    struct Lifestyle {
        var chronotype: LifestyleHighlights.Chronotype?
        var sports: [LifestyleHighlights.Sport] = []
        var hourlyActivity: [Double] = []
        var averageDailySteps: Int?
    }

    private(set) var lastError: String?

    func hydrate() async -> Snapshot? {
        guard let token = await SupabaseAuth.shared.validAccessToken() else { return nil }

        var snapshot = Snapshot()
        do {
            snapshot.records = try await allRecords(token: token)
            snapshot.lastCollectedAt = snapshot.records.map(\.collectedAt).max()
            try await loadProfile(into: &snapshot, token: token)
            try await loadConnections(into: &snapshot, token: token)
            try await loadLifestyle(into: &snapshot, token: token)
            try await loadBans(into: &snapshot, token: token)
            lastError = nil
            return snapshot
        } catch {
            // A failed restore leaves the cache in place rather than blanking the
            // garden — offline is not the same as "this account has nothing".
            lastError = error.localizedDescription
            return nil
        }
    }

    // MARK: - Records

    /// Every distilled row, in pages, summarised across every run.
    ///
    /// Reads the `summary_distilled_records` view rather than the table. The
    /// table is append-only — one set of rows per distillation, kept forever —
    /// and the view reduces that to the latest row per item, which is the
    /// combined picture the dashboard wants. Reading the table directly would
    /// return every run at once and count everything as many times as it has
    /// been distilled.
    ///
    /// **PostgREST answers at most `maxRowsPerRequest` rows and says nothing
    /// about it.** No error, no flag — a `200 OK` carrying the first thousand of
    /// however many there are. The summary passed a thousand some time ago, so
    /// an unranged read would restore a healthy-looking fraction of a library
    /// and quietly get every artist count wrong. `Range` is what asks for the
    /// rest — and it matters more over time, not less, since the summary only
    /// grows as new items appear across runs.
    private func allRecords(token: String) async throws -> [DistilledRecord] {
        var all: [DistilledRecord] = []
        var offset = 0

        while true {
            let page = try await get(
                path: "rest/v1/summary_distilled_records",
                token: token,
                query: [
                    URLQueryItem(
                        name: "select",
                        value: "source,data_type,item_id,name,creator,detail,extra,collected_at,removed_at,removed_reason"
                    ),
                    URLQueryItem(name: "order", value: "source.asc,data_type.asc,item_id.asc")
                ],
                range: offset..<(offset + Self.maxRowsPerRequest)
            )

            all += page.compactMap(Self.record(from:))
            // A short page is the last page. Asking again would cost a round trip
            // to be told the same thing.
            if page.count < Self.maxRowsPerRequest { break }
            offset += Self.maxRowsPerRequest

            // A runaway guard, not a limit anyone should hit: 50 pages is
            // 50,000 rows, an order of magnitude past the largest real library.
            if offset >= Self.maxRowsPerRequest * 50 { break }
        }
        return all
    }

    /// PostgREST's default ceiling. Matching it exactly means a full page is an
    /// unambiguous "there may be more".
    private static let maxRowsPerRequest = 1_000

    /// One row back into the shape the app works in.
    ///
    /// Reverses both changes `SyncService.row(for:)` makes on the way out:
    /// `extra` is a JSON object on the server and `key=value;…` here, and the
    /// removal note lives in real columns there but inside `extra` here, where
    /// `isRemovedByUser` looks for it.
    private static func record(from row: [String: Any]) -> DistilledRecord? {
        guard let source = row["source"] as? String,
              let dataType = row["data_type"] as? String,
              let itemID = row["item_id"] as? String,
              let collected = (row["collected_at"] as? String).flatMap(parseDate)
        else { return nil }

        var pairs: [String] = []
        if let extra = row["extra"] as? [String: Any] {
            // Sorted so a record round-trips to the same string every time;
            // dictionary order is not stable and `extra` is compared as text.
            for key in extra.keys.sorted() {
                let value = String(describing: extra[key] ?? "")
                guard !value.isEmpty else { continue }
                pairs.append("\(key)=\(value)")
            }
        }
        if let removedAt = row["removed_at"] as? String {
            pairs.append("\(DistilledRecord.removalKey)=\(removedAt)")
            if let reason = row["removed_reason"] as? String {
                pairs.append("removed_reason=\(reason)")
            }
        }

        return DistilledRecord(
            source: source,
            dataType: dataType,
            itemID: itemID,
            name: row["name"] as? String ?? "",
            creator: row["creator"] as? String ?? "",
            detail: row["detail"] as? String ?? "",
            extra: pairs.joined(separator: ";"),
            collectedAt: collected
        )
    }

    // MARK: - The user object

    private func loadProfile(into snapshot: inout Snapshot, token: String) async throws {
        let rows = try await get(
            path: "rest/v1/users",
            token: token,
            query: [URLQueryItem(name: "select", value: "birth_date,birth_year,sex,place,tree_seed")]
        )
        guard let row = rows.first else { return }

        // Age is derived, never stored — a number written down on a birthday is
        // wrong the next one. See migration 0003.
        //
        // Two precisions, and the exact one wins. `birth_date` is only set when
        // the user typed a full birthday; `birth_year` is what HealthKit gives,
        // which deliberately keeps the year alone. Reading only the date — as
        // this did at first — left every Health-derived account with no age at
        // all, because that column is null for all of them.
        if let birth = (row["birth_date"] as? String).flatMap(Self.parseDay) {
            snapshot.identity.age = Calendar.current
                .dateComponents([.year], from: birth, to: Date()).year
        } else if let year = (row["birth_year"] as? NSNumber)?.intValue {
            // Accurate to within a year, which is the best this column can do:
            // without a month and day there is no telling whether the birthday
            // has passed.
            let thisYear = Calendar.current.component(.year, from: Date())
            let age = thisYear - year
            if (0...130).contains(age) { snapshot.identity.age = age }
        }
        snapshot.identity.sex = row["sex"] as? String
        snapshot.identity.place = row["place"] as? String
        if let seed = row["tree_seed"] as? NSNumber {
            snapshot.treeSeed = seed.uint64Value
        }
    }

    private func loadConnections(into snapshot: inout Snapshot, token: String) async throws {
        let rows = try await get(
            path: "rest/v1/source_connections",
            token: token,
            query: [URLQueryItem(name: "select", value: "source,last_distilled_at")]
        )
        snapshot.connectedSources = Set(rows.compactMap { $0["source"] as? String })
    }

    // MARK: - Health, derived only

    private func loadLifestyle(into snapshot: inout Snapshot, token: String) async throws {
        let signalRows = try await get(
            path: "rest/v1/summary_health_signals",
            token: token,
            query: [URLQueryItem(
                name: "select",
                value: "chronotype_label,median_wake_minutes,spread_minutes,days_observed,average_daily_steps,hourly_activity"
            )]
        )
        let sportRows = try await get(
            path: "rest/v1/summary_health_sports",
            token: token,
            query: [
                URLQueryItem(name: "select", value: "sport,sessions,minutes"),
                URLQueryItem(name: "order", value: "minutes.desc")
            ]
        )

        // No row at all means Health was never connected on this account, which
        // is different from connected-and-empty; leave `lifestyle` nil so the
        // card draws nothing rather than drawing zeroes.
        guard let signals = signalRows.first else { return }

        var lifestyle = Lifestyle()
        if let label = signals["chronotype_label"] as? String,
           let median = signals["median_wake_minutes"] as? Int {
            lifestyle.chronotype = LifestyleHighlights.Chronotype(
                medianWakeMinutes: median,
                spreadMinutes: signals["spread_minutes"] as? Int ?? 0,
                label: label,
                days: signals["days_observed"] as? Int ?? 0
            )
        }
        lifestyle.averageDailySteps = signals["average_daily_steps"] as? Int
        lifestyle.hourlyActivity = (signals["hourly_activity"] as? [Any])?
            .compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
        lifestyle.sports = sportRows.compactMap { row in
            guard let name = row["sport"] as? String else { return nil }
            return LifestyleHighlights.Sport(
                name: name,
                sessions: row["sessions"] as? Int ?? 0,
                minutes: row["minutes"] as? Int ?? 0
            )
        }
        snapshot.lifestyle = lifestyle
    }

    // MARK: - Bans

    private func loadBans(into snapshot: inout Snapshot, token: String) async throws {
        let rows = try await get(
            path: "rest/v1/bans",
            token: token,
            query: [URLQueryItem(name: "select", value: "kind,value,banned_at")]
        )

        var bans = BanList()
        for row in rows {
            guard let rawKind = row["kind"] as? String,
                  let kind = BanList.Kind(rawValue: rawKind),
                  let value = row["value"] as? String
            else { continue }
            bans.add(kind, value)
        }
        snapshot.bans = bans
    }

    // MARK: - Transport

    private enum RestoreError: LocalizedError {
        case server(String)
        var errorDescription: String? { if case .server(let m) = self { return m } else { return nil } }
    }

    private func get(
        path: String,
        token: String,
        query: [URLQueryItem],
        range: Range<Int>? = nil
    ) async throws -> [[String: Any]] {
        var components = URLComponents(
            url: AppConfig.supabaseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = query
        guard let url = components?.url else { throw RestoreError.server("Bad restore URL.") }

        var request = URLRequest(url: url)
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let range {
            request.setValue("\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // 206 Partial Content is the expected answer to a ranged request.
        guard (200..<300).contains(status) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0?["message"] as? String }
            throw RestoreError.server(detail ?? "Restore failed (\(status)).")
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
    }

    /// Postgres timestamps come back as `2026-07-28T14:30:04.368075+00:00`, with
    /// fractional seconds that the plain ISO-8601 formatter rejects outright.
    private static func parseDate(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    /// A `date` column is `2001-04-17` — no time, so the timestamp parsers above
    /// return nil for it.
    private static func parseDay(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text)
    }
}
