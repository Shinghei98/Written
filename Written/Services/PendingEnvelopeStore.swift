import Foundation

/// Batches of `SourceEnvelope` that have been built and not yet accepted by the
/// ingestion endpoint.
///
/// **Phase 1 asks for retry and idempotency "independent" of the legacy path**,
/// and independence is the point rather than a detail: the new path is on
/// shadow, so it must not be able to break the old one. Nothing here touches
/// `RecordStore`, `SyncService` or their errors, and a batch stuck in this queue
/// forever costs a distillation nothing.
///
/// Shaped like `PendingPhotoStore`, and for its reason — that queue was
/// memory-only, so a photograph added offline stayed in the grid looking saved
/// and a force-quit took it with nothing left to try from. Application Support
/// rather than Caches, because the system may evict a cache whenever it likes
/// and this is unsent work; one directory per account through `AccountScope`,
/// because a queue flushed into the wrong account uploads somebody else's
/// library.
///
/// **The file name is the whole manifest.** `<ingestion id>-<n>.json` is batch
/// *n* of that run. A separate index beside the files is a second thing that can
/// disagree with them, and a crash between the two writes leaves a queue naming
/// a file that is not there. A directory listing cannot disagree with itself.
enum PendingEnvelopeStore {

    /// One batch, exactly as it will be posted.
    ///
    /// Encoded at *staging* rather than at send, so a retry after a crash sends
    /// the same bytes — the same rule `PhotoService` follows, and for the same
    /// reason: re-deriving on the way out means the thing retried is not the
    /// thing that failed.
    struct Batch: Identifiable {
        let id: String
        let body: Data
    }

    private static var directory: URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else { return nil }
        let directory = support.appendingPathComponent(
            "written-pending-envelopes-\(AccountScope.current)"
        )
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
        }
        return directory
    }

    /// Writes one batch and answers whether it is safe to send.
    ///
    /// **`false` means do not send it**, because a batch that could not be
    /// written is one a crash would lose silently — and the whole purpose of
    /// this queue is that the device never believes it sent something the
    /// server never got.
    @discardableResult
    static func stage(_ body: Data, ingestionID: UUID, sequence: Int) -> Bool {
        guard let directory else { return false }
        let url = directory.appendingPathComponent(
            "\(ingestionID.uuidString.lowercased())-\(sequence).json"
        )
        do {
            try body.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Everything still owed to the endpoint, oldest run first.
    ///
    /// Sorted by name, which sorts by run and then by sequence within it —
    /// so a run's batches go in the order they were built. That matters only
    /// for legibility in the logs, since the endpoint is idempotent per record
    /// and does not care, but an out-of-order queue is a thing somebody would
    /// eventually try to explain.
    static func load() -> [Batch] {
        guard let directory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return [] }

        return names.sorted().compactMap { name in
            guard name.hasSuffix(".json") else { return nil }
            let url = directory.appendingPathComponent(name)
            // A batch that cannot be read is dropped rather than queued
            // forever: it would fail every flush and report the same refusal on
            // every launch, which is `PendingPhotoStore`'s lesson exactly.
            guard let body = try? Data(contentsOf: url), !body.isEmpty else {
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            return Batch(id: name, body: body)
        }
    }

    /// One batch, once the endpoint has it — or once it has refused it in a way
    /// no retry can fix.
    static func clear(_ id: String) {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(id))
    }

    /// How much is waiting, without reading any of it.
    static var pendingCount: Int {
        guard let directory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return 0 }
        return names.filter { $0.hasSuffix(".json") }.count
    }

    /// **Wired into `DistillViewModel.signOutLocalState`**, alongside every
    /// other per-account store.
    ///
    /// Unsent work, so keeping it would be defensible — but signing out leaves
    /// nothing on this device, and a batch of somebody's calendar titles is the
    /// last thing to make an exception for.
    static func clear() {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}
