import Foundation

/// Photo edits that have been made and not yet accepted by the server.
///
/// **The queue was memory-only, so it died with the app.** A photograph added
/// while offline stayed in the grid looking saved, the retry only fired if the
/// user happened to leave the tab again in the same launch, and a force-quit
/// took it with nothing left to try from. That is the one failure this whole
/// path exists to avoid: the device showing something the server never got.
///
/// Shaped like `RecordStore` — Application Support rather than Caches, because
/// the system may evict a cache whenever it likes and this is unsent work, and
/// one directory per account through `AccountScope`, because a queue flushed
/// into the wrong account would upload somebody else's face.
///
/// **The intent is in the file name, not in a manifest.** `3.jpg` is a pending
/// upload for slot 3; `3.removed` is a pending removal. A manifest beside the
/// files is a second thing that can disagree with them — a crash between writing
/// the two leaves a queue that names a file that isn't there, or a file nothing
/// will ever send. A directory listing cannot disagree with itself.
enum PendingPhotoStore {

    enum Entry {
        case upload(Data)
        case remove
    }

    private static let uploadExtension = "jpg"
    private static let removalExtension = "removed"

    private static var directory: URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else { return nil }
        let directory = support.appendingPathComponent(
            "written-pending-photos-\(AccountScope.current)"
        )
        // Created on demand rather than at launch: most sessions never stage
        // anything, and an empty directory per account is litter.
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
        }
        return directory
    }

    private static func file(_ position: Int, _ ext: String) -> URL? {
        directory?.appendingPathComponent("\(position).\(ext)")
    }

    /// Records one slot's intent. `nil` data means the photograph was removed.
    ///
    /// The opposite intent for the same slot is deleted first, so a slot can
    /// never be both — picking a photograph and then removing it must leave one
    /// instruction, not two contradictory ones.
    static func stage(_ data: Data?, at position: Int) {
        guard let upload = file(position, uploadExtension),
              let removal = file(position, removalExtension) else { return }

        if let data {
            try? FileManager.default.removeItem(at: removal)
            try? data.write(to: upload, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: upload)
            try? Data().write(to: removal, options: .atomic)
        }
    }

    /// Everything still owed to the server, by slot.
    static func load() -> [Int: Entry] {
        guard let directory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return [:] }

        var entries: [Int: Entry] = [:]
        for name in names {
            let url = directory.appendingPathComponent(name)
            guard let position = Int(url.deletingPathExtension().lastPathComponent),
                  (0..<6).contains(position)
            else { continue }

            switch url.pathExtension {
            case removalExtension:
                entries[position] = .remove
            case uploadExtension:
                // A file that cannot be read is dropped rather than queued
                // forever — it would fail every flush and report the same
                // refusal at every departure.
                guard let data = try? Data(contentsOf: url), !data.isEmpty else {
                    try? FileManager.default.removeItem(at: url)
                    continue
                }
                entries[position] = .upload(data)
            default:
                continue
            }
        }
        return entries
    }

    /// One slot, once the server has it.
    static func clear(position: Int) {
        if let upload = file(position, uploadExtension) {
            try? FileManager.default.removeItem(at: upload)
        }
        if let removal = file(position, removalExtension) {
            try? FileManager.default.removeItem(at: removal)
        }
    }

    /// **Wired into `DistillViewModel.signOutLocalState`.**
    ///
    /// Unsent work is not a cache, so keeping it would be defensible — but
    /// signing out leaves nothing on this device, and of everything here a
    /// photograph is the last thing to make an exception for. What makes that
    /// acceptable is that sign-out flushes first, while the token is still good;
    /// this only discards what a failure left behind.
    static func clear() {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}
