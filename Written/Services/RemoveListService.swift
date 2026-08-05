import Foundation

/// People taken out of one person's discovery stack, without an accusation.
///
/// **The quieter of the two ways to never see somebody again.** Reporting goes
/// through `ChatService.report` and `BanList.Kind.person`, which is the same act
/// as unmatching and is stored with it. This is the other one: no complaint, no
/// words, just "not this person" — and it is kept in its own table so the two
/// statements never have to be told apart by a `kind` column that a future query
/// forgets to filter on. See `0017_remove_list.sql` for that trade in full.
///
/// The cost of separateness is paid here: this is the service, the restore leg
/// and the place in the feed's hiding set that `bans` would have provided free.
actor RemoveListService {

    static let shared = RemoveListService()

    private(set) var lastError: String?

    /// Everybody this account has removed.
    ///
    /// Read at launch for the feed's exclusion set. A failure returns nothing
    /// rather than throwing, and that direction is deliberate: an empty answer
    /// shows somebody a person they had removed, which is a bad minute; the
    /// alternative — treating a failed read as "remove everybody" — is an empty
    /// Explore with no explanation.
    func removed() async -> Set<String> {
        guard await SupabaseAuth.shared.userID != nil else { return [] }
        do {
            let rows = try await PostgREST.rows("rest/v1/remove_list", query: [
                "select": "removed_id",
            ])
            lastError = nil
            return Set(rows.compactMap { $0["removed_id"] as? String })
        } catch {
            lastError = error.localizedDescription
            return []
        }
    }

    /// Takes somebody out of the stack for good.
    ///
    /// `ignore-duplicates`, not `merge-duplicates`: the row carries nothing worth
    /// updating, and a second removal of the same person is the same removal.
    /// This is also the form that needs no `update` privilege — the trap `0009`
    /// documents for `likes`, where a merge compiles to `on conflict do update`
    /// and is refused at plan time whether or not a conflict happens.
    @discardableResult
    func remove(_ personID: String) async -> Bool {
        guard let me = await SupabaseAuth.shared.userID else {
            lastError = "You're not signed in."
            return false
        }
        do {
            try await PostgREST.insert(
                "rest/v1/remove_list",
                body: [["remover_id": me, "removed_id": personID]],
                prefer: "resolution=ignore-duplicates,return=minimal"
            )
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }
}
