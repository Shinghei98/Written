import Foundation
import Compression

/// A copy of what each source actually said, before Written made anything of it.
///
/// **The response used to be parsed and dropped.** Every distiller turned an
/// API body into `[DistilledRecord]` — eight columns and a `key=value;key=value`
/// string — and nothing kept the body. `raw_source_records` reads as though it
/// did, and does not: it holds a `SourcePayload` derived *from* the normalised
/// row, one lossy step further on. `SourcePayload+Legacy.swift` names the loss
/// in its own words — `extra` cannot represent a value containing `;` or `=`,
/// "so a track called *Symphony No. 5; II* lost its tail long before this file
/// saw it. Nothing here can recover that."
///
/// This is the standing rule made real: **a change that needs data re-projected
/// is our problem to solve server-side**, and four changes in two days were paid
/// for by asking somebody to open the app. An archive is what makes the next one
/// a query instead of a favour.
///
/// **Two kinds of capture, named differently on purpose.** Five sources speak
/// HTTP and have a body to keep verbatim — YouTube, Google Calendar, Outlook,
/// Spotify and Apple Music through `MusicDataRequest`. The other five are device
/// frameworks with no body at all: `EKEventStore`, `HKHealthStore`, `MPMediaQuery`
/// and `CLLocationManager` return object graphs. Calling a property dump a "raw
/// response" would be the same misnomer this file exists to correct, so
/// ``captureResponse(source:endpoint:request:data:)`` keeps bytes and
/// ``captureObjects(source:kind:objects:)`` keeps a complete serialisation.
///
/// **Explicit at each call site, never an interceptor.** A `URLProtocol` would
/// also catch Supabase, Discovery and the lyrics providers, none of which may be
/// archived. Explicit is also what makes the author of the next source decide
/// rather than inherit.
///
/// Shaped like `PendingPhotoStore`: Application Support rather than Caches
/// because the system may evict a cache whenever it likes and this is unsent
/// work, and one directory per account through `AccountScope`, because a queue
/// flushed into the wrong account uploads somebody else's life.
actor RawArchive {

    static let shared = RawArchive()

    /// The private bucket, alongside `profile-photos` and `chat-media`.
    ///
    /// **Not the vault, and the reason is availability rather than preference.**
    /// `raw_source_records.raw_blob_ref` was designed for exactly this and has
    /// never had a writer — but it is reached through the AWS ingestion Lambda,
    /// which is lapsed. Nothing here writes that column, so when the vault route
    /// returns the two cannot disagree about where a body lives.
    private static let bucket = "raw-source-archives"

    /// Why a capture was refused, kept so a silent archive can be told from an
    /// empty one. **An absent archive and a refused one are different facts**,
    /// and this project has paid for confusing them more than once.
    private(set) var refusals: [String: Int] = [:]

    private init() {}

    // MARK: - Where it lands

    private static var directory: URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else { return nil }
        let directory = support.appendingPathComponent(
            "written-raw-archive-\(AccountScope.current)"
        )
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
        }
        return directory
    }

    /// The file name carries everything needed to replay it, and no manifest
    /// sits beside it — same argument as `PendingPhotoStore`'s `3.jpg` /
    /// `3.removed`: **a directory listing cannot disagree with itself**, and a
    /// crash between writing a file and writing its manifest entry leaves a
    /// queue naming something that is not there.
    ///
    /// `<source>__<endpoint>__<epoch-millis>.json.gz`, with the endpoint
    /// flattened so a path separator in a URL cannot create a directory.
    private static func name(source: String, endpoint: String, at when: Date) -> String {
        let stamp = Int(when.timeIntervalSince1970 * 1000)
        let flat = endpoint
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "__", with: "-")
            .prefix(80)
        return "\(source)__\(flat)__\(stamp).json.gz"
    }

    // MARK: - Capture

    /// One HTTP response, exactly as it arrived.
    ///
    /// **Never throws and never fails a distillation.** An archive is worth less
    /// than the reading it is an archive of; a write error is counted in
    /// ``refusals`` and swallowed, on the same reasoning that makes
    /// `CALENDAR_CLASSIFIER_ARN` unset a deliberate off switch rather than an
    /// error.
    ///
    /// The request's URL is kept because a body is uninterpretable without the
    /// question that produced it — which `part=` was asked for, which `$select`,
    /// which page token. Headers are not kept: they carry the bearer token.
    func captureResponse(
        source: String,
        endpoint: String,
        request: URLRequest,
        data: Data
    ) async {
        guard AppConfig.rawArchiveEnabled else { return }
        let envelope: [String: Any] = [
            "schema": "written-raw-capture-v1",
            "kind": "http_response",
            "source": source,
            "endpoint": endpoint,
            // The query is the question; without it a page of fifty videos does
            // not say which fifty were asked for.
            "url": request.url?.absoluteString ?? endpoint,
            "method": request.httpMethod ?? "GET",
            "captured_at": ISO8601DateFormatter().string(from: Date()),
            "body_utf8": String(data: data, encoding: .utf8) ?? "",
            "body_bytes": data.count
        ]
        guard JSONSerialization.isValidJSONObject(envelope),
              let json = try? JSONSerialization.data(
                withJSONObject: envelope, options: [.sortedKeys]
              ) else {
            count("not_encodable:\(source)")
            return
        }
        await write(json, source: source, endpoint: endpoint)
    }

    /// One framework query, serialised whole.
    ///
    /// `objects` is what the caller read off the framework — every property it
    /// exposes, not the subset the distiller uses. That difference is the entire
    /// point: a field no distiller reads today is precisely the field a
    /// re-projection will want, and it is the one thing this archive can keep
    /// that `DistilledRecord` cannot.
    ///
    /// **The local-only refusals are applied before serialising, not after.**
    /// `health/biological_sex` never leaves the device — a protected
    /// characteristic, with `public.users.sex` already meaning the gender
    /// somebody *chose*. An archive that captured it and filtered on upload
    /// would put it in a file on disk that the Settings export then ships.
    /// **Takes bytes, not a dictionary, and that is a concurrency requirement
    /// rather than a style.** `[String: Any]` is not `Sendable`, so handing one
    /// across an actor boundary is a data race the compiler is right to refuse.
    /// `RawArchiveSerialiser.envelope` builds and encodes on the caller's side —
    /// which is also where the framework objects already live and where they
    /// must not escape to.
    func captureEncoded(source: String, endpoint: String, payload: Data) async {
        guard AppConfig.rawArchiveEnabled else { return }
        await write(payload, source: source, endpoint: endpoint)
    }

    // MARK: - Writing

    private func write(_ json: Data, source: String, endpoint: String) async {
        guard let directory = Self.directory else {
            count("no_directory")
            return
        }
        guard let squeezed = Self.gzip(json) else {
            count("not_compressible:\(source)")
            return
        }
        // **Refuse past the ceiling; never delete to make room.** Choosing
        // which of somebody's data to drop is not a decision a size limit
        // should be making, and a silently-pruned archive is worse than one
        // that stopped and said so.
        if stagedBytes() + squeezed.count > AppConfig.rawArchiveMaxBytes {
            count("over_ceiling:\(source)")
            return
        }
        let url = directory.appendingPathComponent(
            Self.name(source: source, endpoint: endpoint, at: Date())
        )
        do {
            try squeezed.write(to: url, options: .atomic)
        } catch {
            count("write_failed:\(source)")
        }
    }

    private func count(_ reason: String) {
        refusals[reason, default: 0] += 1
    }

    /// zlib through `Compression`, because a raw JSON archive is mostly repeated
    /// keys and compresses by roughly an order of magnitude. Returns nil rather
    /// than the original bytes on failure: an uncompressed file with a `.gz`
    /// name is worse than no file, since whatever reads the directory later will
    /// trust the extension.
    private static func gzip(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = max(data.count, 64)
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress
            else { return 0 }
            return data.withUnsafeBytes { source -> Int in
                guard let sourceBase = source.bindMemory(to: UInt8.self).baseAddress
                else { return 0 }
                return compression_encode_buffer(
                    destinationBase, capacity, sourceBase, data.count, nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else { return nil }
        return output.prefix(written)
    }

    // MARK: - Reading, for the export and the upload queue

    /// Every archived file for this account, newest last.
    func staged() -> [URL] {
        guard let directory = Self.directory,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
              ) else { return [] }
        return entries.filter { $0.pathExtension == "gz" }.sorted {
            $0.lastPathComponent < $1.lastPathComponent
        }
    }

    /// What the archive currently occupies, in bytes.
    ///
    /// **Reported rather than assumed.** An archive nobody sized is one that
    /// surprises somebody at five hundred users.
    func stagedBytes() -> Int {
        staged().reduce(0) { total, url in
            total + ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0)
        }
    }

    // MARK: - Sending

    /// Upload everything staged, and delete each file only once it landed.
    ///
    /// **Delete-after-success, never before**, which is the property that makes
    /// the queue survive a bad connection: a file removed on a hopeful upload
    /// is a piece of somebody's data that no longer exists anywhere. Same shape
    /// as `PendingPhotoStore` — the disk is the queue and the queue outlives
    /// the app.
    ///
    /// Returns how many objects landed and how many were left for next time.
    @discardableResult
    func flush() async -> (sent: Int, remaining: Int) {
        let staged = staged()
        guard !staged.isEmpty else { return (0, 0) }
        guard let token = await SupabaseAuth.shared.validAccessToken(),
              let userID = await SupabaseAuth.shared.userID else {
            // **Not signed in is not a failure to record against the data.**
            // The files stay; the next launch tries again.
            count("not_signed_in")
            return (0, staged.count)
        }

        var sent = 0
        for file in staged {
            guard let bytes = try? Data(contentsOf: file) else {
                count("unreadable_staged_file")
                continue
            }
            // `<user_id>/<file>` — the owner first, because the storage
            // policies read `storage.foldername(name)[1]` and compare it to
            // `auth.uid()`. Built as a string rather than with
            // `appendingPathComponent`, which percent-encodes the separator so
            // a two-segment key arrives as one flat name and `foldername`
            // finds no owner. The same trap is documented in `PhotoService.put`
            // and `MediaService.put`.
            let path = "\(userID)/\(file.lastPathComponent)"
            guard let url = URL(
                string: "\(AppConfig.supabaseURL.absoluteString)/storage/v1/object/\(Self.bucket)/\(path)"
            ) else {
                count("bad_upload_url")
                continue
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/gzip", forHTTPHeaderField: "Content-Type")
            // The name carries a millisecond stamp, so a re-upload of the same
            // capture is the same object rather than a duplicate.
            request.setValue("true", forHTTPHeaderField: "x-upsert")
            request.httpBody = bytes

            guard let (_, response) = try? await URLSession.shared.data(for: request),
                  (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0)
            else {
                count("upload_refused")
                continue
            }
            try? FileManager.default.removeItem(at: file)
            sent += 1
        }
        return (sent, staged.count - sent)
    }

    /// Erase this account's archive. Called by *Disconnect all*, by account
    /// deletion, and by sign-out — **a deletion control names every place or it
    /// is not finished**, and this is a third place beside `public` and the
    /// vault.
    func forget() {
        for url in staged() { try? FileManager.default.removeItem(at: url) }
        refusals = [:]
    }
}
