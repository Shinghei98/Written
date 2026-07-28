import Foundation

/// Things the user has struck off their profile.
///
/// Distillation is automatic, which means it will sometimes surface something
/// private (a channel they'd rather not advertise) or simply wrong (a song
/// played once by someone borrowing the phone). This is the editing pass: what
/// the machine collected is a draft, and the person it describes gets the last
/// word.
///
/// Bans outlive the records they hide. A re-distill fetches the same library
/// again, so without persistence every removal would quietly undo itself the
/// next time the user connected.
struct BanList: Codable, Equatable {

    enum Kind: String, Codable {
        case artist
        case channel
        /// A workout type — "Yoga", "Running". Health is the most personal of
        /// the three branches, so being able to strike one off matters most here.
        case sport
    }

    struct Entry: Codable, Hashable {
        let kind: Kind
        /// Matched case-insensitively against `creator` for artists and against
        /// the channel name or id for channels.
        let key: String
        let bannedAt: Date
    }

    private(set) var entries: [Entry] = []

    var isEmpty: Bool { entries.isEmpty }

    func contains(_ kind: Kind, _ key: String) -> Bool {
        let needle = key.lowercased()
        return entries.contains { $0.kind == kind && $0.key.lowercased() == needle }
    }

    mutating func add(_ kind: Kind, _ key: String) {
        guard !key.isEmpty, !contains(kind, key) else { return }
        entries.append(Entry(kind: kind, key: key, bannedAt: Date()))
    }

    mutating func remove(_ kind: Kind, _ key: String) {
        let needle = key.lowercased()
        entries.removeAll { $0.kind == kind && $0.key.lowercased() == needle }
    }

    // MARK: - Persistence

    /// Small enough for `UserDefaults`, and it has to survive relaunches even
    /// though the records themselves don't: the ban is the user's decision, not
    /// distilled data.
    /// Scoped to the account. It was one key per *device*, which is why signing
    /// out had to erase it — otherwise the next account inherited a stranger's
    /// rejections and never found out why an artist kept vanishing.
    private static var storageKey: String { AccountScope.key("written.banned.entries") }

    static func load() -> BanList {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let list = try? JSONDecoder().decode(BanList.self, from: data) else {
            return BanList()
        }
        return list
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    /// Forgets everything struck off. For deleting an account, not signing out —
    /// a rejection is the user's own decision and outlasts a session.
    static func clear() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}

extension DistilledRecord {
    /// Written into `extra` when the user removes something, so the removal
    /// travels with the data rather than living only in the app.
    ///
    /// The row is **kept, not deleted**: the ontology stage downstream needs to
    /// know that this was collected and then struck off, which is a different
    /// fact from never having been collected. Everything that ranks or counts
    /// skips these.
    static let removalKey = "removed_by_user"

    var isRemovedByUser: Bool { extraValue(Self.removalKey) != nil }

    /// A copy carrying the removal note. `extra` is `key=value;…`, so this is
    /// two more pairs on the end.
    func markedRemoved(reason: String, at date: Date = Date()) -> DistilledRecord {
        guard !isRemovedByUser else { return self }
        let stamp = ISO8601DateFormatter().string(from: date)
        let note = "\(Self.removalKey)=\(stamp);removed_reason=\(reason)"
        return DistilledRecord(
            source: source,
            dataType: dataType,
            itemID: itemID,
            name: name,
            creator: creator,
            detail: detail,
            extra: extra.isEmpty ? note : "\(extra);\(note)",
            collectedAt: collectedAt
        )
    }
}
