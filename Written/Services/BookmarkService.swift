import Foundation

/// Saved profiles, private to the person who saved them.
///
/// Shaped like `LikeService` — an actor, one `lastError`, `PostgREST` for the
/// transport — and deliberately much smaller, because a bookmark has no second
/// party. Nobody is notified, nobody answers, and `0035`'s single policy covers
/// all four operations. See that migration's header for why it is a real delete
/// rather than an annotation.
actor BookmarkService {

    static let shared = BookmarkService()

    private(set) var lastError: String?

    /// True when the last failure was a person who no longer exists.
    ///
    /// Same contract as `LikeService.lastFailureWasMissingPerson`: `23503` on
    /// insert means they deleted their account between the feed being built and
    /// the tap, and the caller takes them off the screen rather than reporting a
    /// foreign-key violation to somebody who just tapped a bookmark.
    private(set) var lastFailureWasMissingPerson = false

    /// Every person this account has bookmarked.
    ///
    /// **Returns `nil` for *could not ask*, not `[]`.** An empty set is a
    /// decision — draw an empty bookmarks page, draw every icon unfilled — and a
    /// dropped request must not be mistaken for one. That distinction is the
    /// ninth-instance lesson from `ChatService.conversations()`, which wrote its
    /// empty answer back over the cache; here it would silently un-fill every
    /// bookmark on the feed.
    func bookmarkedIDs() async -> Set<String>? {
        guard let me = await SupabaseAuth.shared.currentUserID() else {
            lastError = "You're not signed in."
            return nil
        }
        do {
            let rows = try await PostgREST.rows("rest/v1/bookmarks", query: [
                "user_id": "eq.\(me)",
                "select": "bookmarked_id",
            ])
            lastError = nil
            return Set(rows.compactMap { $0["bookmarked_id"] as? String })
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// The bookmarked people, newest first, as the cards the feed already draws.
    ///
    /// **Two requests rather than a join**, because there is no join to make:
    /// `bookmarks` is keyed to `public.users`, which is closed, and everything
    /// drawable about another person lives in `discovery_cards` — the one table
    /// a signed-in user may read about somebody else. So this asks which ids,
    /// then asks `DiscoveryService` for those cards.
    ///
    /// **A bookmarked person with no card is dropped, and that is correct.** A
    /// card is withdrawn when somebody pauses their account or takes down their
    /// last photograph, and drawing a saved copy after that would be showing a
    /// profile its owner has withdrawn.
    func bookmarked() async -> [DiscoveryService.Person]? {
        guard let ids = await bookmarkedIDs() else { return nil }
        guard !ids.isEmpty else { return [] }

        let people = await DiscoveryService.shared.people(ids: ids)
        guard let people else {
            lastError = await DiscoveryService.shared.lastError
            return nil
        }
        return people
    }

    /// Adds a bookmark. Idempotent — `(user_id, bookmarked_id)` is the primary
    /// key, so a second tap conflicts and does nothing.
    ///
    /// **`ignore-duplicates`, never `merge-duplicates`.** The latter compiles to
    /// `on conflict do update`, which Postgres plans as needing `update` on every
    /// column inserted; there is nothing here worth updating, and the habit is
    /// what shipped a silently-refused like once already.
    @discardableResult
    func add(_ personID: String) async -> Bool {
        lastFailureWasMissingPerson = false
        guard let me = await SupabaseAuth.shared.currentUserID() else {
            lastError = "You're not signed in."
            return false
        }
        do {
            try await PostgREST.insert(
                "rest/v1/bookmarks",
                body: [["user_id": me, "bookmarked_id": personID]],
                prefer: "resolution=ignore-duplicates,return=minimal"
            )
            lastError = nil
            return true
        } catch {
            lastFailureWasMissingPerson = PostgREST.isMissingPerson(error)
            lastError = error.localizedDescription
            return false
        }
    }

    /// Removes one. A real delete — see `0035`.
    ///
    /// Filtered through `PostgREST.delete`, which builds its query with
    /// `URLComponents`. Worth knowing why that matters: appending
    /// `bookmarks?user_id=eq.…` as a path component escapes the `?` and asks for
    /// a table of that name, and the unlucky version of that mistake is a DELETE
    /// arriving with no filter at all.
    @discardableResult
    func remove(_ personID: String) async -> Bool {
        guard let me = await SupabaseAuth.shared.currentUserID() else {
            lastError = "You're not signed in."
            return false
        }
        do {
            try await PostgREST.delete("rest/v1/bookmarks", query: [
                "user_id": "eq.\(me)",
                "bookmarked_id": "eq.\(personID)",
            ])
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }
}
