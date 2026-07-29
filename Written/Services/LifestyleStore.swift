import Foundation

/// A cache of the four figures the lifestyle card and branch are made of.
///
/// Apple Health is the one source that cannot be cached the way every other one
/// is. `RecordStore` holds each source's rows, so music, media and calendar are
/// connected on the first frame after a relaunch — but Health's rows are derived
/// and *discarded* rather than stored, which is deliberate and stays that way.
/// With nothing on disk, the branch could only come back from the server, so
/// Apple Health alone read as disconnected on every launch until a round trip
/// finished, and not at all offline.
///
/// So: the derived figures, and only those. A chronotype, an hourly profile, a
/// step average and a list of sports — the same four values already uploaded to
/// `health_signals`, which is strictly less than the raw workouts and samples
/// this app refuses to write down. No workout, no sample, no timestamp.
///
/// Scoped by account and cleared with the rest on sign-out, exactly like
/// `RecordStore`.
enum LifestyleStore {

    /// Everything `DistillViewModel` cannot recompute once the rows are gone.
    ///
    /// Written and read as a set, mirroring `RestoreService.Snapshot.Lifestyle`:
    /// half of these is not a state the card has a sensible rendering for.
    struct Cached: Codable {
        var chronotype: LifestyleHighlights.Chronotype?
        var hourlyActivity: [Double]
        var sports: [LifestyleHighlights.Sport]
        var averageDailySteps: Int?

        var isEmpty: Bool {
            chronotype == nil && hourlyActivity.isEmpty
                && sports.isEmpty && averageDailySteps == nil
        }
    }

    /// Application Support beside the distillation, one file per account.
    private static var fileURL: URL? {
        guard let directory = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else { return nil }
        return directory.appendingPathComponent("written-lifestyle-\(AccountScope.current).json")
    }

    static func load() -> Cached? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let cached = try? JSONDecoder().decode(Cached.self, from: data)
        else { return nil }
        return cached
    }

    /// Fire-and-forget, off the main actor — the plant should grow as the
    /// figures land, not after they are written.
    ///
    /// An empty set is a delete rather than a write. Saving it would turn "this
    /// account has no Health data" into a cached fact that outlives the reason,
    /// and the next launch would trust it over the server.
    static func save(_ cached: Cached) {
        guard !cached.isEmpty else { return clear() }
        Task.detached(priority: .utility) {
            guard let fileURL, let data = try? JSONEncoder().encode(cached) else { return }
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    static func clear() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}
