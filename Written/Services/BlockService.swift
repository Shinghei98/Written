import Foundation

/// Blocking, which is the one safety control the server enforces rather than
/// the app.
///
/// Shaped like `BookmarkService` — an actor, one `lastError`, `PostgREST` for
/// the transport — and, like it, deliberately small: `0123`'s three policies
/// cover every operation, and the interesting half of blocking is not here at
/// all.
///
/// **What this file cannot do is the point of `0123`.** Hiding a blocked person
/// is not a filter the client applies, because a filter the client applies is a
/// filter another client omits. `api.discover_profiles` calls
/// `private.is_blocked` server-side, triggers refuse a like and a message, and
/// `match_profile` returns nothing — none of which this actor is involved in.
/// What it does is create and remove the row those checks read.
///
/// **And it can only ever see your own blocks.** `0123`'s select policy is
/// `auth.uid() = blocker_id`, so `blockedIDs()` returns the people *you* have
/// blocked and can never reveal who has blocked you. That asymmetry is the
/// product decision — the blocked person is told nothing — made structural, so
/// no future screen can accidentally draw it.
///
/// **Blocking is not unmatching.** `DistillViewModel.banPerson` is the local
/// ban list: it hides somebody from Explore and from chats on *this device* and
/// marks their records removed. Blocking is mutual, server-side and permanent
/// until lifted. The callers do both, because somebody who blocks plainly wants
/// what unmatching gives them as well — but they are two mechanisms and only one
/// of them survives a reinstall.
actor BlockService {

    static let shared = BlockService()

    private(set) var lastError: String?

    /// Everyone this account has blocked.
    ///
    /// **Returns `nil` for *could not ask*, not `[]`** — the recurring lesson
    /// this codebase has now paid for eleven times. An empty set is a decision
    /// ("you have blocked nobody") and a dropped request must not be mistaken
    /// for one, which here would draw a settings page saying somebody had
    /// unblocked people they had not.
    func blockedIDs() async -> Set<String>? {
        guard let me = await SupabaseAuth.shared.currentUserID() else {
            lastError = "You're not signed in."
            return nil
        }
        do {
            let rows = try await PostgREST.rows("rest/v1/blocks", query: [
                "blocker_id": "eq.\(me)",
                "select": "blocked_id",
            ])
            lastError = nil
            return Set(rows.compactMap { $0["blocked_id"] as? String })
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Block whoever holds this number, if anybody does.
    ///
    /// **You never learn whether it matched, and that is the design.**
    /// `public.block_by_phone` (`0124`) returns void and behaves identically
    /// against a number with an account and one without — a distinguishable
    /// answer would make the block list an oracle for *"is this person on
    /// Written?"*, which is a question about somebody else's account. So this
    /// returns whether the *call* succeeded, never whether it found anyone.
    ///
    /// The number needs its country code. Both sides are compared as digits
    /// only, so punctuation and spacing do not matter — but a bare national
    /// number matches nobody, and does so silently, for the same reason.
    @discardableResult
    func block(phone: String) async -> Bool {
        do {
            _ = try await PostgREST.insert(
                "rest/v1/rpc/block_by_phone", body: ["p_phone": phone]
            )
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// The address book, in one call.
    ///
    /// **One statement rather than one per contact**, which is the argument
    /// `DistillViewModel.block(names:)` already makes for the local half: a
    /// phone book runs to hundreds of entries. And the same silence — how many
    /// of somebody's contacts hold accounts is a more interesting answer than
    /// whether one does, and equally nobody's business.
    @discardableResult
    func block(phones: [String]) async -> Bool {
        let numbers = phones
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !numbers.isEmpty else { return true }
        do {
            _ = try await PostgREST.insert(
                "rest/v1/rpc/block_by_phones", body: ["p_phones": numbers]
            )
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Lift a block on whoever holds this number. Silent in the same way.
    @discardableResult
    func unblock(phone: String) async -> Bool {
        do {
            _ = try await PostgREST.insert(
                "rest/v1/rpc/unblock_by_phone", body: ["p_phone": phone]
            )
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Block somebody. Idempotent: blocking twice is blocking once.
    ///
    /// **`ignore-duplicates`, not `merge-duplicates`.** `0123` gives `blocks` no
    /// update policy at all — a block has nothing to change and lifting one is a
    /// delete — and `merge-duplicates` compiles to `on conflict do update`,
    /// which Postgres refuses at *plan* time for want of the update privilege
    /// whether or not a conflict occurs. That is `0009`'s 42501 lesson, and
    /// `LikeService.like` shipped it once already.
    @discardableResult
    func block(_ personID: String) async -> Bool {
        guard let me = await SupabaseAuth.shared.currentUserID() else {
            lastError = "You're not signed in."
            return false
        }
        guard me != personID else {
            lastError = "You can't block yourself."
            return false
        }
        do {
            _ = try await PostgREST.insert(
                "rest/v1/blocks",
                body: [["blocker_id": me, "blocked_id": personID]],
                prefer: "resolution=ignore-duplicates"
            )
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Lift a block. A real delete, for the reason `0035` gives about bookmarks:
    /// "nothing in Postgres is ever deleted" describes the distillation record,
    /// not a list somebody curates.
    ///
    /// **It does not undo what blocking did.** A revoked invitation stays
    /// revoked and a frozen conversation thaws without its lost messages,
    /// because neither was deleted — `0123` moves a pending like to `revoked`
    /// rather than removing it. Unblocking restores reachability, not history.
    @discardableResult
    func unblock(_ personID: String) async -> Bool {
        guard let me = await SupabaseAuth.shared.currentUserID() else {
            lastError = "You're not signed in."
            return false
        }
        do {
            // `URLComponents`, never `appendingPathComponent` — that escapes the
            // `?` and turns a filtered delete into a request for a table of that
            // name. It 404s, which is the lucky failure; the unlucky one is a
            // DELETE with no filter at all.
            _ = try await PostgREST.delete("rest/v1/blocks", query: [
                "blocker_id": "eq.\(me)",
                "blocked_id": "eq.\(personID)",
            ])
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }
}
