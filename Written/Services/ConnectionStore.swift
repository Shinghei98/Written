import Foundation

/// Which sources this account has ever connected, on disk.
///
/// **A connection is not the same fact as a row, and inferring one from the
/// other is what this exists to stop.** Every other part of the garden is
/// derived from `RecordStore` — connect Apple Music, get four hundred rows, and
/// the branch draws itself. That works right up until a source legitimately
/// returns nothing: a YouTube account with no likes and no subscriptions, a
/// Podcasts library with nothing downloaded, an Apple Music account with no
/// subscription and no local library. Those distillations *succeed*, and with
/// no rows behind them the modality read as never connected — so the plant did
/// not grow, the prompt went on asking for the same branch, and the person was
/// stuck with no error to explain it. That is exactly how it was reported.
///
/// `source_connections` on the server has always recorded this correctly —
/// `append_source_records` upserts the row even from an empty array — but the
/// server is a round trip away and offline is not a state the garden may break
/// in. This is the local half of the same fact.
///
/// Only source names. No counts, no timestamps, nothing about *what* was read —
/// those live in `RecordStore` where they can be struck off. Scoped by account
/// and cleared on sign-out, like every store beside it.
enum ConnectionStore {

    /// Application Support beside the distillation, one file per account.
    ///
    /// One shared file would mean signing out had to delete it, because
    /// otherwise the next person to sign in on this phone inherits a garden
    /// grown from somebody else's connections.
    private static var fileURL: URL? {
        guard let directory = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else { return nil }
        return directory.appendingPathComponent("written-connections-\(AccountScope.current).json")
    }

    static func load() -> Set<String> {
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let sources = try? JSONDecoder().decode(Set<String>.self, from: data)
        else { return [] }
        return sources
    }

    /// Fire-and-forget, off the main actor — the branch should grow as the
    /// distillation lands, not after a file is written.
    ///
    /// **An empty set is a delete rather than a write**, matching
    /// `LifestyleStore`: caching "this account has connected nothing" would turn
    /// a momentary state into a fact the next launch trusts over the server.
    static func save(_ sources: Set<String>) {
        guard !sources.isEmpty else { return clear() }
        Task.detached(priority: .utility) {
            guard let fileURL, let data = try? JSONEncoder().encode(sources) else { return }
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    static func clear() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}
