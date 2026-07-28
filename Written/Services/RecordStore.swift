import Foundation

/// A cache of the distillation, on disk.
///
/// **A cache, not the record.** Postgres is the source of truth; this exists so
/// the garden draws on the first frame instead of after a round trip, and so the
/// app works offline. Deleting it loses nothing — `RestoreService` fetches the
/// same rows back.
///
/// That is a reversal. It was the *only* copy for a while, which is why signing
/// out had to erase it, and why a reinstall or a new phone started empty while
/// every row sat safely in Postgres. The argument for keeping it local was that
/// Spotify and raw Health could never be restored from the server; Spotify has
/// since been dropped as a source, and Health now derives its signals on the
/// device and uploads those, so nothing is left that only this file could carry.
///
/// A connection is still a *snapshot* — nothing polls, nothing listens, and each
/// row is a point-in-time reading stamped with `collectedAt`. "Connected" means
/// *has been connected*, and `source_connections` on the server is what makes
/// that durable now.
///
/// Scoped by account and cleared on sign-out, so nothing is retained afterwards.
enum RecordStore {

    /// Application Support, not Caches. This is the user's own distillation, and
    /// the system may evict a cache whenever it likes.
    ///
    /// One file per account. A single shared file meant signing out had to
    /// delete it, because otherwise the next person to sign in on this phone
    /// opened someone else's distillation.
    private static var fileURL: URL? {
        guard let directory = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else { return nil }
        return directory.appendingPathComponent("written-distillation-\(AccountScope.current).json")
    }

    /// The pre-account file, adopted once so nobody loses the snapshot they
    /// already had on this device when the stores became per-account.
    private static var legacyFileURL: URL? {
        guard let directory = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else { return nil }
        return directory.appendingPathComponent("written-distillation.json")
    }

    static func load() -> [DistilledRecord] {
        guard let fileURL else { return [] }

        if let data = try? Data(contentsOf: fileURL),
           let records = try? JSONDecoder().decode([DistilledRecord].self, from: data) {
            return records
        }

        // Nothing for this account yet. The unscoped file, if it is still there,
        // belongs to whoever was signed in when it was written — which on a
        // device that has only ever had one account is this person.
        guard let legacyFileURL, let data = try? Data(contentsOf: legacyFileURL),
              let records = try? JSONDecoder().decode([DistilledRecord].self, from: data)
        else { return [] }
        try? FileManager.default.moveItem(at: legacyFileURL, to: fileURL)
        return records
    }

    /// Fire-and-forget, off the main actor.
    ///
    /// A couple of megabytes of JSON has no business holding up the moment a
    /// distillation finishes — the plant should grow as the records land, not
    /// after they are written.
    static func save(_ records: [DistilledRecord]) {
        Task.detached(priority: .utility) {
            guard let fileURL, let data = try? JSONEncoder().encode(records) else { return }
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// For deleting an account — *not* for signing out.
    ///
    /// Signing out leaves this alone deliberately: a connection is a snapshot
    /// that was taken, and that stays true while nobody is signed in. The file
    /// is scoped to the account, so nothing else can reach it in the meantime.
    static func clear() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}
