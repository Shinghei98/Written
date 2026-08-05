import Foundation

/// Likes, and the admirers they make.
///
/// Shaped like `DiscoveryService`: an actor, one `lastError`, and rows dropped
/// rather than half-built. See `0009_likes_and_chat.sql` for the policies — the
/// short version is that a like is visible to exactly two people, only the
/// recipient may answer it, and nothing is ever deleted.
actor LikeService {

    static let shared = LikeService()

    /// Somebody who has liked you and is still waiting for an answer.
    struct Admirer: Identifiable, Equatable {
        /// Their user id, which is also what identifies the like: the primary key
        /// is `(liker_id, liked_id)` and the second half is always you.
        let id: String
        /// **Not `let`**: the stored `liker_name` is a snapshot from the moment
        /// the like was sent, and `admirers()` overwrites it with whatever the
        /// person's card says they are called now.
        var name: String
        let photoSeed: Int
        /// Their own photograph, where they have one. Same reasoning as
        /// `ChatService.Conversation.partnerPhotoPath`: a seed is the synthetic
        /// accounts' stand-in, so drawing one for everybody left real people
        /// looking like placeholders.
        var photoPath: String?

        /// What they wrote with the invitation, if they wrote anything.
        ///
        /// Absent for a plain heart, which is most of them. See `0018` — the
        /// column refuses an empty string, so this is never a note that says
        /// nothing.
        var message: String?

        /// What to draw. Their face if there is one, the generated portrait if
        /// not — the same `PhotoRef` the feed and chat use.
        var photoRef: DiscoveryFeed.PhotoRef {
            if let photoPath { return .stored(photoPath) }
            return .generated(photoSeed)
        }
        let likedAt: Date
    }

    private(set) var lastError: String?

    // MARK: - Liking

    /// Everyone this account has already liked, whatever came of it.
    ///
    /// Read back rather than remembered locally, and that is the point: the feed
    /// draws a filled heart from this, so a relaunch or a second device has to be
    /// able to arrive at the same answer.
    func likedPersonIDs() async -> Set<String> {
        await invitations().liked
    }

    /// Everyone this account has invited, and which of them got a note.
    ///
    /// **Two sets from one request.** The card draws a filled *heart* for a
    /// plain like and a filled *envelope* for one carried with a note, so it has
    /// to know which happened — and asking twice for the same rows to answer
    /// two halves of one question would be a second round trip on the screen
    /// that already waits longest.
    ///
    /// Read from the server on load rather than kept only in memory: a relaunch
    /// that forgot would draw every invitation as untouched.
    func invitations() async -> (liked: Set<String>, withNote: Set<String>) {
        guard let me = await SupabaseAuth.shared.currentUserID() else { return ([], []) }
        do {
            let rows = try await PostgREST.rows("rest/v1/likes", query: [
                "liker_id": "eq.\(me)",
                "select": "liked_id,message",
            ])
            lastError = nil
            var liked: Set<String> = []
            var withNote: Set<String> = []
            for row in rows {
                guard let id = row["liked_id"] as? String else { continue }
                liked.insert(id)
                // `0018` refuses an empty string at the column, so anything
                // non-null here is a note somebody wrote.
                if row["message"] is String { withNote.insert(id) }
            }
            return (liked, withNote)
        } catch {
            lastError = error.localizedDescription
            return ([], [])
        }
    }

    private func row(me: String, personID: String, myName: String, note: String?) -> [String: Any] {
        var row: [String: Any] = [
            "liker_id": me,
            "liked_id": personID,
            "liker_name": myName,
            "liker_photo_seed": PortraitSeed.stable(for: me),
        ]
        // Omitted rather than sent as null: `ignore-duplicates` means this row
        // may be discarded wholesale anyway, and a column absent from the body
        // is one fewer thing for the insert to be refused over.
        if let note { row["message"] = note }
        return row
    }

    /// Attaches a note to a like that already exists.
    ///
    /// **The one path `0018`'s grant was widened for.** `like` uses
    /// `ignore-duplicates`, so hearting somebody and *then* writing to them
    /// would otherwise be swallowed in silence — the second insert conflicts,
    /// does nothing, and reports success. This is the update that the column
    /// grant and the `pending` policy exist to allow, and nothing else on this
    /// table may be updated by the person who wrote it.
    ///
    /// A refusal here is `42501` and means the policy is wrong, not the caller.
    @discardableResult
    func attachMessage(_ message: String, to personID: String) async -> Bool {
        guard let me = await SupabaseAuth.shared.currentUserID() else {
            lastError = "You're not signed in."
            return false
        }
        let note = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { return true }

        do {
            try await PostgREST.update(
                "rest/v1/likes",
                query: ["liker_id": "eq.\(me)", "liked_id": "eq.\(personID)"],
                body: ["message": note]
            )
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Likes a person, with an optional note. Idempotent — `(liker_id,
    /// liked_id)` is the primary key, so a second tap upserts the row it already
    /// wrote rather than failing on it.
    ///
    /// The name and seed travel with the row because the recipient cannot look
    /// them up: `public.users` is closed and a real account has no
    /// `discovery_cards` row to read. See the migration's header.
    /// True when the last failure was a person who no longer exists.
    ///
    /// Read by `DiscoveryModel.like`, which takes them off the screen instead of
    /// reporting it. Reset on every attempt, so it can only ever describe the
    /// most recent one.
    private(set) var lastFailureWasMissingPerson = false

    func like(personID: String, message: String? = nil) async -> Bool {
        lastFailureWasMissingPerson = false
        guard let me = await SupabaseAuth.shared.currentUserID() else { return false }
        let myName = await SupabaseAuth.shared.firstName ?? "Someone"
        // Trimmed here rather than at the sheet, so every route in gets the same
        // answer about what counts as a note. `0018` refuses an empty string at
        // the column, and this is what keeps that check from ever being the
        // thing that reports the problem.
        let note = message?.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            try await PostgREST.insert(
                "rest/v1/likes",
                body: [row(
                    me: me, personID: personID, myName: myName,
                    note: (note?.isEmpty == false) ? note : nil
                )],
                // Merge rather than fail: tapping a heart twice is a person being
                // unsure, not an error to show them.
                // **`ignore-duplicates`, never `merge-duplicates`.** Both read as
                // "upsert", and only one of them can work here.
                //
                // `merge-duplicates` compiles to `on conflict do update`, and
                // Postgres checks privileges when it plans the statement rather
                // than when a conflict happens — so it needs `update` on every
                // column being inserted, whether or not the row already exists.
                // `0009` revokes update on this table and grants back only
                // `(status, responded_at)`, precisely so a recipient cannot
                // rewrite `liker_id` and forge a like. The two are in direct
                // conflict, and the privilege wins: **every like was refused with
                // 42501**, silently, because the heart fills optimistically and
                // the error is recorded and never shown.
                //
                // `ignore-duplicates` compiles to `on conflict do nothing`, which
                // needs no update privilege and gives the same idempotence — a
                // second tap is a no-op rather than a rewrite of a row whose
                // contents cannot have changed anyway.
                //
                // `ChatService.open` documents this same trap for
                // `conversations`. It is the second time this schema's column
                // grants have caught an upsert.
                prefer: "resolution=ignore-duplicates,return=minimal"
            )
            lastError = nil
            return true
        } catch {
            // **A deleted account, not a failure worth showing.** Every foreign
            // key in this schema leads back to `public.users`, and deleting an
            // account cascades from `auth.users` through it — so `23503` here
            // means the person on the card is gone. Their card can still be in
            // somebody's feed for as long as that feed has been open, because
            // `DiscoveryFeed` is built once and scrolled, not re-fetched.
            //
            // Reported as `violates foreign key constraint
            // "likes_liked_id_fkey"` on screen, which is true, useless, and
            // frightening.
            lastFailureWasMissingPerson = PostgREST.isMissingPerson(error)
            lastError = error.localizedDescription
            return false
        }
    }

    // MARK: - Being liked

    /// The people waiting for an answer, newest first — or **nil for "could not
    /// ask"**.
    ///
    /// Same reasoning as `ChatService.conversations()`: an empty list is a fact
    /// about an account and must never stand in for a request that did not
    /// happen. Here it emptied the admirers banner offline; there it wiped the
    /// cached chat list.
    func admirers() async -> [Admirer]? {
        guard let me = await SupabaseAuth.shared.currentUserID() else {
            lastError = "You're not signed in."
            return nil
        }
        do {
            let rows = try await PostgREST.rows("rest/v1/likes", query: [
                "liked_id": "eq.\(me)",
                "status": "eq.pending",
                "select": "liker_id,liker_name,liker_photo_seed,message,created_at",
                // **The order the compose sheet promises.** Its subtitle says a
                // message "puts you on top of the stack", and copy that promises
                // placement over code that ignores it is a lie the app tells
                // every time somebody pays attention to it. `message.desc` sorts
                // non-null before null in Postgres' default `nulls last`, so
                // written invitations come first and recency decides within each
                // group.
                "order": "message.desc.nullslast,created_at.desc",
            ])
            lastError = nil
            var list = rows.compactMap { row -> Admirer? in
                guard let id = row["liker_id"] as? String,
                      let name = row["liker_name"] as? String,
                      let created = row["created_at"] as? String,
                      let likedAt = PostgREST.date(created)
                else { return nil }
                return Admirer(
                    id: id,
                    name: name,
                    photoSeed: row["liker_photo_seed"] as? Int ?? PortraitSeed.stable(for: id),
                    message: row["message"] as? String,
                    likedAt: likedAt
                )
            }
            // Their faces **and their current names**, in one request rather
            // than one per admirer. `liker_name` is denormalised onto the row
            // when the like is sent and never corrected, so somebody who set or
            // changed their name afterwards is listed as whoever they used to
            // be — and that stale name is then copied onto the conversation the
            // moment the like is accepted, where it stays. The card is the live
            // answer; the stored column is the fallback for anybody who has
            // never synced one.
            let cards = await ChatService.cards(for: list.map(\.id))
            for index in list.indices {
                guard let card = cards[list[index].id] else { continue }
                if let name = card.displayName { list[index].name = name }
                list[index].photoPath = card.photoPath
            }
            return list
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Answers a like. Accepting is what authorises the conversation — the
    /// insert policy on `conversations` looks for exactly this row.
    ///
    /// Declining marks the row and leaves their card in the feed, which is the
    /// decision recorded in the plan: a decline removes them from the list
    /// without hiding them, and they are never told.
    func respond(to likerID: String, accept: Bool) async -> Bool {
        guard let me = await SupabaseAuth.shared.currentUserID() else { return false }
        do {
            try await PostgREST.update(
                "rest/v1/likes",
                query: [
                    "liker_id": "eq.\(likerID)",
                    "liked_id": "eq.\(me)",
                ],
                body: [
                    "status": accept ? "accepted" : "declined",
                    "responded_at": PostgREST.string(Date()),
                ]
            )
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }
}
