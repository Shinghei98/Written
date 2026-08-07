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
        /// Somebody unmatched or reported, keyed by their user id.
        ///
        /// **The odd one out, and it earns its place here.** The other three
        /// strike content off your own distillation; this hides a person. What
        /// they share is everything that made adding it a single line: the list
        /// is cached locally so a block applies with no round trip, pushed by
        /// `SyncService.pushBans`, restored by `RestoreService`, and covered by
        /// an RLS policy that is already `auth.uid() = user_id`. `bans.kind` is
        /// plain text with no check constraint, so this needed no migration.
        ///
        /// Keyed by id rather than by name because two people share a name and
        /// neither should inherit the other's block.
        case person
        /// A podcast show. Keyed by both its name and its persistent id, as
        /// channels are — the show rows carry an id and older records may not.
        case show
        /// A calendar event, **keyed by its title rather than its id.**
        ///
        /// The id would be more precise and would be wrong. A ban exists to
        /// survive the next distillation, and a recurring appointment generates
        /// fresh occurrences with fresh ids — so an id ban would strike this
        /// week's therapy session and let next week's straight back in, which is
        /// the opposite of what somebody striking it off is asking for.
        ///
        /// The cost is that removing a generically titled event removes every
        /// event sharing that title. That is a fair reading of the request: if
        /// four things are called "Lunch", none of them says anything, and
        /// somebody who strikes one is unlikely to be defending the other three.
        case event
        /// A word that keeps an invitation from ever being shown.
        ///
        /// **The second kind that hides something rather than striking it off,
        /// after `person`** — and it earns the same place for the same reasons.
        /// It is account-scoped, cached so a filter applies with no round trip,
        /// pushed by `SyncService.pushBans`, restored by `RestoreService`, and
        /// covered by a `bans` policy that is already `auth.uid() = user_id`.
        /// `bans.kind` is plain text with no check constraint, so this needs no
        /// migration either.
        ///
        /// Stored lowercased and matched as a substring of the note a like
        /// carries. Substring rather than whole-word deliberately: somebody
        /// filtering a slur is not also going to think of its plurals, and the
        /// cost of over-matching here is one invitation nobody sees, which is
        /// the outcome they asked for.
        case word
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

    /// Whether an invitation's note trips the word filter.
    ///
    /// **Lives here rather than on the view model**, because the two things
    /// that need it cannot both reach one: the settings page edits the list
    /// through `DistillViewModel`, and `ChatModel` — which draws the admirers —
    /// owns no view model at all. `BanList` is account-scoped and static, so
    /// both sides read the same answer with no plumbing.
    ///
    /// Substring, and lowercased on both sides. Somebody filtering a word means
    /// the word, not one spelling of it, and over-matching costs an invitation
    /// nobody wanted to see — which is what they asked for.
    func filters(note: String?) -> Bool {
        guard let note, !note.isEmpty else { return false }
        let haystack = note.lowercased()
        return keys(.word).contains { haystack.contains($0) }
    }

    func contains(_ kind: Kind, _ key: String) -> Bool {
        let needle = key.lowercased()
        return entries.contains { $0.kind == kind && $0.key.lowercased() == needle }
    }

    /// Every key struck off under one kind, lowercased so callers can test
    /// membership as cheaply as `contains` does.
    func keys(_ kind: Kind) -> Set<String> {
        Set(entries.filter { $0.kind == kind }.map { $0.key.lowercased() })
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

    /// Whether this row is withheld — **by the user or by policy**, which the
    /// name no longer distinguishes.
    ///
    /// It meant only the editing pass until `SensitiveEvents` began marking
    /// medical and political calendar titles, which nobody struck off. The key
    /// stays `removed_by_user` because it is in the schema and rows already
    /// carry it; `removed_reason` is what tells the two apart, and the ontology
    /// stage should read that rather than assume a person decided.
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
