import CryptoKit
import Foundation

/// Sends typed envelopes to the private ingestion endpoint.
///
/// **Phase 1 of the v0.3.1 integration, and it is inert until switched on.**
/// `AppConfig.semanticIngestionEnabled` is `false`, so `submit` returns having
/// done nothing. Phase 1 is *dual*-write: the legacy `SyncService` path is
/// untouched and remains the one the product depends on.
///
/// **Independent of that path in every direction, which is the safety
/// property.** Its own queue, its own errors, its own retry. Nothing here can
/// make a distillation fail, and nothing here reads `SyncService.lastError` or
/// writes to it. A shadow path that can break the live one is not a shadow.
///
/// The endpoint is `aws/ingestion` — API Gateway in front of a Lambda that
/// verifies the caller's Supabase access token against the published JWKS,
/// encrypts each payload under a data key only KMS can unwrap, and writes both
/// through `semantic_private.ingest_source_records_v031`.
actor SemanticIngestionService {

    static let shared = SemanticIngestionService()

    /// What the endpoint says it did — `0053`'s receipt, verbatim.
    ///
    /// `stored` and `duplicates` are the coverage comparison Phase 1 asks for:
    /// a run whose rows are all duplicates has changed nothing, and a run where
    /// `stored` does not match what the legacy path sent is the disagreement
    /// the shadow phase exists to find.
    struct Receipt: Decodable, Equatable, Sendable {
        let ingestionRunID: String
        let received: Int
        let stored: Int
        let duplicates: Int
        let keyRecorded: Bool

        private enum CodingKeys: String, CodingKey {
            case ingestionRunID = "ingestion_run_id"
            case received, stored, duplicates
            case keyRecorded = "key_recorded"
        }
    }

    /// What one flush did. Returned rather than stashed on the actor, because
    /// **a shared `lastError` is not a record of what failed** — whoever writes
    /// it last wins, and a later success erases an earlier failure. Same lesson
    /// `SyncService` records at the top of its own file.
    struct Summary: Equatable, Sendable {
        var batchesSent = 0
        var batchesKept = 0
        var batchesDropped = 0
        var received = 0
        var stored = 0
        var duplicates = 0
        /// The *first* failure, not the last: the one that started the trouble
        /// is the one worth reading.
        var firstFailure: String?

        var isEmpty: Bool { batchesSent == 0 && batchesKept == 0 && batchesDropped == 0 }
    }

    // MARK: - Building and queueing

    /// Stage a run's envelopes and try to send them.
    ///
    /// **Written to disk before anything is sent**, so a force-quit mid-upload
    /// leaves the work to retry rather than losing it — `PendingPhotoStore`'s
    /// lesson, which cost a queue that died with the app.
    @discardableResult
    func submit(
        _ envelopes: [SourceEnvelope],
        connector: SemanticSource,
        ingestionID: UUID
    ) async -> Summary {
        guard AppConfig.semanticIngestionEnabled, !envelopes.isEmpty else { return Summary() }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        // Batched to the endpoint's own ceiling. It refuses a larger batch
        // rather than truncating it, which is the right way round — a request
        // that silently dropped its tail would show up as missing rows with
        // nothing anywhere saying so.
        for (index, slice) in envelopes.chunked(into: AppConfig.semanticIngestionBatchSize).enumerated() {
            guard let body = encode(slice, connector: connector, ingestionID: ingestionID, using: encoder) else {
                continue
            }
            PendingEnvelopeStore.stage(body, ingestionID: ingestionID, sequence: index)
        }

        return await flush()
    }

    private func encode(
        _ envelopes: [SourceEnvelope],
        connector: SemanticSource,
        ingestionID: UUID,
        using encoder: JSONEncoder
    ) -> Data? {
        guard let records = try? encoder.encode(envelopes) else { return nil }
        // `ingestion_runs.input_hash` is `not null` and is meant to identify
        // what went in. A hash over the encoded records is exactly that, and it
        // is computed here rather than server-side so it describes what this
        // device believed it was sending.
        let inputHash = SHA256.hash(data: records)
            .map { String(format: "%02x", $0) }.joined()

        let payload = Batch(
            ingestionID: ingestionID.uuidString.lowercased(),
            connectorSourceCode: connector.rawValue,
            connectorVersion: Self.connectorVersion,
            inputHash: inputHash,
            records: envelopes
        )
        return try? encoder.encode(payload)
    }

    private struct Batch: Encodable {
        let ingestionID: String
        let connectorSourceCode: String
        let connectorVersion: String
        let inputHash: String
        let records: [SourceEnvelope]

        private enum CodingKeys: String, CodingKey {
            case ingestionID = "ingestion_id"
            case connectorSourceCode = "connector_source_code"
            case connectorVersion = "connector_version"
            case inputHash = "input_hash"
            case records
        }
    }

    /// The app build that produced the rows, which `ingestion_runs` records so a
    /// bad connector version can be found later without guessing at dates.
    private static let connectorVersion: String = {
        let bundle = Bundle.main
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "ios-\(short)+\(build)"
    }()

    // MARK: - Sending

    /// Send everything queued, oldest first.
    ///
    /// Safe to call at any time and safe to call twice: the endpoint is
    /// idempotent per record — `0053` collides on
    /// `(user_id, source_code, record_fingerprint)` — so a batch sent twice
    /// stores nothing the second time and says so in its receipt.
    @discardableResult
    func flush() async -> Summary {
        guard AppConfig.semanticIngestionEnabled else { return Summary() }

        var summary = Summary()
        let pending = PendingEnvelopeStore.load()
        guard !pending.isEmpty else { return summary }

        // **Not guarded on the stored token.** `accessToken` is a cache, and a
        // cold launch has none until `restoreSession()` has been round the
        // network — so somebody can be legitimately signed in with it empty.
        guard let token = await SupabaseAuth.shared.validAccessToken() else {
            summary.batchesKept = pending.count
            summary.firstFailure = await SupabaseAuth.shared.lastTokenFailure?.message
                ?? "not signed in"
            return summary
        }

        for batch in pending {
            switch await send(batch.body, token: token) {
            case .success(let receipt):
                PendingEnvelopeStore.clear(batch.id)
                summary.batchesSent += 1
                summary.received += receipt.received
                summary.stored += receipt.stored
                summary.duplicates += receipt.duplicates

            case .permanent(let reason):
                // **Dropped rather than retried, and the distinction is the
                // whole reason this queue drains.** A batch the endpoint will
                // never accept — a malformed envelope, an expired grant, a
                // source it does not know — fails identically on every launch,
                // so keeping it means uploading the same rejection forever and
                // a queue that grows without bound.
                PendingEnvelopeStore.clear(batch.id)
                summary.batchesDropped += 1
                if summary.firstFailure == nil { summary.firstFailure = reason }

            case .transient(let reason):
                // Offline, rate-limited, or the endpoint is having a bad day.
                // Kept, and the rest of the queue is left alone: sending them
                // now would spend the same failure several more times.
                summary.batchesKept = pending.count - summary.batchesSent - summary.batchesDropped
                if summary.firstFailure == nil { summary.firstFailure = reason }
                return summary
            }
        }
        return summary
    }

    private enum SendResult {
        case success(Receipt)
        /// No retry will help.
        case permanent(String)
        /// A retry might.
        case transient(String)
    }

    private func send(_ body: Data, token: String) async -> SendResult {
        guard let url = AppConfig.semanticIngestionURL else {
            return .permanent("no ingestion endpoint configured")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        request.timeoutInterval = 30

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .transient("no response")
            }
            switch http.statusCode {
            case 200:
                guard let receipt = try? JSONDecoder().decode(Receipt.self, from: data) else {
                    // The rows are stored — the endpoint answered 200 — so this
                    // batch must not be sent again on the strength of a receipt
                    // we could not read. Dropped, and the reason recorded.
                    return .permanent("stored, but the receipt could not be read")
                }
                return .success(receipt)

            // **401 is transient, and that is not the obvious reading.** The
            // token expired or had not been refreshed yet; the batch is fine
            // and the next flush will have a fresh one. Treating it as
            // permanent would throw away a distillation because somebody
            // reopened the app after an hour.
            case 401, 408, 429, 500...599:
                return .transient("ingestion endpoint returned \(http.statusCode)")

            default:
                return .permanent("ingestion endpoint refused the batch (\(http.statusCode))")
            }
        } catch {
            return .transient(error.localizedDescription)
        }
    }
}

#if DEBUG
extension SemanticIngestionService {

    /// `-probe-ingest` → send one envelope through the real endpoint and say
    /// what came back.
    ///
    /// **This settles the last premise in the chain rather than showing a
    /// screen**, which is why it is here and not in a test. Everything from the
    /// device to Postgres has been proven in pieces — the token verifier
    /// against generated ECDSA keys, the Postgres function against a real
    /// migration chain, the role by connecting — and the one link nobody can
    /// exercise without a signed-in device is the whole of it at once. In
    /// particular `SUPABASE_ISSUER` on the Lambda has never been checked
    /// against a token Supabase actually minted, and a wrong one refuses every
    /// request identically.
    ///
    /// ```
    /// xcrun simctl launch <device> com.written.datingapp -probe-ingest 1
    /// ```
    ///
    /// **It writes a real row** — encrypted, in the prober's own vault, filed
    /// under `user`/`probe`. That is the point: a probe that avoided writing
    /// would leave the write path exactly as unproven as before. Running it
    /// twice is the more interesting result: the second receipt should read
    /// `stored 0, duplicates 1`, which is the fingerprint idempotency working.
    ///
    /// Deliberately bypasses `AppConfig.semanticIngestionEnabled` — the flag
    /// exists to keep dual-write off, and this is the thing that has to happen
    /// before turning it on. It also bypasses the queue, so a failed probe
    /// leaves nothing behind to be retried later by something that was not
    /// asked to.
    func probe() async -> String {
        let ingestionID = UUID()
        let envelope = SourceEnvelope(
            ingestionID: ingestionID,
            connectorSource: .user,
            recordSource: .user,
            action: nil,
            unweightedAction: nil,
            providerItemID: "ingestion-probe",
            providerRevisionOrETag: nil,
            observedAt: Date(),
            sourceEventAt: nil,
            lifecycleState: .active,
            dataUsePurpose: .sourceDistillation,
            typedPayload: .profile(
                ProfilePayload(field: "probe", value: "ingestion probe", detail: nil)
            ),
            legacyCorrelationID: "user/probe/ingestion-probe"
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let body = encode([envelope], connector: .user, ingestionID: ingestionID, using: encoder) else {
            return "could not encode the envelope"
        }
        guard let token = await SupabaseAuth.shared.validAccessToken() else {
            return "no access token: "
                + (await SupabaseAuth.shared.lastTokenFailure?.message ?? "not signed in")
        }

        switch await send(body, token: token) {
        case .success(let receipt):
            return """
                run \(receipt.ingestionRunID)
                received \(receipt.received), stored \(receipt.stored), duplicates \(receipt.duplicates)
                key recorded: \(receipt.keyRecorded)
                """
        case .permanent(let reason):
            return "refused: \(reason)"
        case .transient(let reason):
            return "not now: \(reason)"
        }
    }
}
#endif

private extension Array {
    /// Fixed-size slices, last one short. Nothing in the standard library does
    /// this and three callers would each write it slightly differently.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
