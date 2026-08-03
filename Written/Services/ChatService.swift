import Foundation

/// Conversations and the messages in them.
///
/// A conversation exists only where an accepted like does — enforced by the
/// insert policy in `0009_likes_and_chat.sql`, not merely by this file. Nothing
/// here can open a thread with somebody who has not agreed to one.
actor ChatService {

    static let shared = ChatService()

    /// One thread, from the point of view of whoever is reading the list.
    ///
    /// The row stores `user_a`/`user_b`; a list wants "the other person", so the
    /// mapping happens on the way out and no view has to work out which of the
    /// two columns it is.
    struct Conversation: Identifiable, Equatable, Codable {
        let id: String
        let partnerID: String
        let partnerName: String
        let partnerPhotoSeed: Int
        let lastMessage: String?
        let lastMessageAt: Date?
        /// `photo` | `video` | `audio`, or `nil` when the last message was text.
        ///
        /// Kept on the summary rather than worked out from `lastMessage`. The
        /// chat list used to read an empty body as "a photo with no caption",
        /// which a voice memo breaks: its body is a duration, so it is not
        /// empty, and `\d\d:\d\d` is also how somebody writes half past
        /// twelve. See `0013`.
        var lastMessageKind: String?
    }

    struct Message: Identifiable, Equatable, Codable {
        let id: String
        let senderID: String
        let body: String
        let sentAt: Date

        /// On its way out, and not yet acknowledged.
        ///
        /// **Never persisted.** `ChatStore` only ever writes messages the server
        /// has confirmed, so an app killed mid-send comes back without a ghost
        /// that may or may not have landed — the next fetch settles it, and the
        /// server is the source of truth either way.
        var isPending = false
        /// Where the photo or video lives in the `chat-media` bucket, and which
        /// it is. Both or neither — `0010` has a constraint saying so, because a
        /// path with no kind is a file the client cannot decide how to draw.
        var attachmentPath: String?
        var attachmentKind: String?

        var isVideo: Bool { attachmentKind == "video" }
        /// A voice memo. Drawn as a player rather than as a thumbnail, so it has
        /// to be asked about before the attachment is treated as a picture.
        var isVoice: Bool { attachmentKind == "audio" }
    }

    /// The newest messages a thread loads. Capped for the reason every fetch in
    /// this project is capped — an uncapped one is a request that gets slower for
    /// the people who use the app most.
    static let messagePageSize = 200

    private(set) var lastError: String?

    // MARK: - The list

    func conversations() async -> [Conversation] {
        guard let me = await SupabaseAuth.shared.userID else { return [] }
        do {
            let rows = try await PostgREST.rows("rest/v1/conversations", query: [
                "or": "(user_a.eq.\(me),user_b.eq.\(me))",
                "select": "id,user_a,user_b,user_a_name,user_b_name,"
                    + "user_a_photo_seed,user_b_photo_seed,last_message,last_message_at,last_message_kind",
                // Newest conversation first, and a thread nobody has written in
                // yet sits at the top rather than falling off the end — it is the
                // one waiting for a first line.
                "order": "last_message_at.desc.nullsfirst",
            ])
            lastError = nil
            return rows.compactMap { Self.conversation(from: $0, me: me) }
        } catch {
            lastError = error.localizedDescription
            return []
        }
    }

    private static func conversation(from row: [String: Any], me: String) -> Conversation? {
        guard let id = row["id"] as? String,
              let userA = row["user_a"] as? String,
              let userB = row["user_b"] as? String
        else { return nil }

        let iAmA = userA == me
        let partnerID = iAmA ? userB : userA
        let partnerName = (iAmA ? row["user_b_name"] : row["user_a_name"]) as? String

        return Conversation(
            id: id,
            partnerID: partnerID,
            partnerName: partnerName ?? "Someone",
            partnerPhotoSeed: (iAmA ? row["user_b_photo_seed"] : row["user_a_photo_seed"]) as? Int
                ?? PortraitSeed.stable(for: partnerID),
            lastMessage: row["last_message"] as? String,
            lastMessageAt: (row["last_message_at"] as? String).flatMap(PostgREST.date),
            lastMessageKind: row["last_message_kind"] as? String
        )
    }

    // MARK: - Reporting

    /// Files a report about somebody. See `0014_reports.sql`.
    ///
    /// Separate from the block, and both happen: `BanList` is what makes them
    /// disappear, this is what tells us why. A block that quietly also filed a
    /// report would be reporting people who only wanted to unmatch.
    func report(_ personID: String, named name: String, body: String) async -> Bool {
        guard let me = await SupabaseAuth.shared.userID else {
            lastError = "You're not signed in."
            return false
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        do {
            try await PostgREST.insert("rest/v1/reports", body: [[
                "reporter_id": me,
                "reported_id": personID,
                "reported_name": name,
                "body": trimmed,
            ]], prefer: "return=minimal")
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    // MARK: - Opening one

    /// Opens the thread with an admirer whose like has just been accepted, or
    /// returns the one that already exists.
    ///
    /// **Read first, then insert.** The obvious shape is an upsert on the
    /// `(user_a, user_b)` unique constraint, and it cannot work here: `authenticated`
    /// has no `update` privilege on `conversations` at all — deliberately, see the
    /// migration — and `resolution=merge-duplicates` compiles to `on conflict do
    /// update`, which needs one. Two people accepting at the same instant still
    /// race past the read, so a failed insert re-reads once rather than surfacing
    /// a constraint violation to somebody who simply tapped Chat.
    func open(with partnerID: String, partnerName: String, partnerPhotoSeed: Int) async -> Conversation? {
        guard let me = await SupabaseAuth.shared.userID else { return nil }
        let myName = await SupabaseAuth.shared.firstName ?? "Someone"

        if let existing = await conversation(with: partnerID) { return existing }

        // `user_a < user_b`, which is what makes one thread per pair fall out of a
        // unique constraint rather than needing either side to check first.
        //
        // Compared as lowercase strings, and that is exact rather than
        // approximate: Postgres orders `uuid` by its bytes, and canonical hex
        // digits sort in the same order as the values they stand for, with the
        // hyphens at matching positions. Uppercase would break it, hence the
        // lowercasing.
        let mine = me.lowercased()
        let theirs = partnerID.lowercased()
        let meFirst = mine < theirs

        let row: [String: Any] = [
            "user_a": meFirst ? me : partnerID,
            "user_b": meFirst ? partnerID : me,
            "user_a_name": meFirst ? myName : partnerName,
            "user_b_name": meFirst ? partnerName : myName,
            "user_a_photo_seed": meFirst ? PortraitSeed.stable(for: me) : partnerPhotoSeed,
            "user_b_photo_seed": meFirst ? partnerPhotoSeed : PortraitSeed.stable(for: me),
        ]

        do {
            let inserted = try await PostgREST.insert(
                "rest/v1/conversations",
                body: [row],
                prefer: "return=representation"
            )
            lastError = nil
            if let first = inserted.first, let made = Self.conversation(from: first, me: me) {
                return made
            }
            return await conversation(with: partnerID)
        } catch {
            // Lost the race, most likely. If a re-read finds it, nothing went
            // wrong from the user's point of view.
            if let existing = await conversation(with: partnerID) {
                lastError = nil
                return existing
            }
            lastError = error.localizedDescription
            return nil
        }
    }

    private func conversation(with partnerID: String) async -> Conversation? {
        guard let me = await SupabaseAuth.shared.userID else { return nil }
        let pair = [me, partnerID].map { $0.lowercased() }.sorted()
        do {
            let rows = try await PostgREST.rows("rest/v1/conversations", query: [
                "user_a": "eq.\(pair[0])",
                "user_b": "eq.\(pair[1])",
                "select": "id,user_a,user_b,user_a_name,user_b_name,"
                    + "user_a_photo_seed,user_b_photo_seed,last_message,last_message_at,last_message_kind",
            ])
            return rows.first.flatMap { Self.conversation(from: $0, me: me) }
        } catch {
            return nil
        }
    }

    // MARK: - Messages

    /// The thread, oldest first — which is the order it is read in, not the order
    /// it is fetched in. The query takes the *newest* page and reverses it, so a
    /// long conversation loads its end rather than its beginning.
    /// - Parameter before: fetch the page *older* than this moment, for reading
    ///   back through a thread. Nil means the newest page.
    ///
    /// History is kept on the device forever, so without a cursor "forever"
    /// would only ever mean "the most recent `messagePageSize`" — a promise the
    /// store could not keep.
    func messages(in conversationID: String, before: Date? = nil) async -> [Message] {
        do {
            var query: [String: String] = [
                "conversation_id": "eq.\(conversationID)",
                "select": "id,sender_id,body,created_at,attachment_path,attachment_kind",
                "order": "created_at.desc",
                "limit": String(Self.messagePageSize),
            ]
            if let before {
                query["created_at"] = "lt.\(PostgREST.string(before))"
            }
            let rows = try await PostgREST.rows("rest/v1/messages", query: query)
            lastError = nil
            return rows.compactMap { row -> Message? in
                guard let id = row["id"] as? String,
                      let senderID = row["sender_id"] as? String,
                      let body = row["body"] as? String,
                      let created = row["created_at"] as? String,
                      let sentAt = PostgREST.date(created)
                else { return nil }
                return Message(
                    id: id,
                    senderID: senderID,
                    body: body,
                    sentAt: sentAt,
                    attachmentPath: row["attachment_path"] as? String,
                    attachmentKind: row["attachment_kind"] as? String
                )
            }.reversed()
        } catch {
            lastError = error.localizedDescription
            return []
        }
    }

    func send(
        _ body: String,
        in conversationID: String,
        attachment: MediaService.Upload? = nil
    ) async -> Bool {
        guard let me = await SupabaseAuth.shared.userID else { return false }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        // Either half will do, which is exactly what `messages_have_content`
        // says: `0009` required text, and a photo sent without a caption is the
        // ordinary case the moment attachments exist. Refusing an empty *and*
        // attachment-less send here means it is a no-op rather than a round trip
        // that comes back 400.
        guard !trimmed.isEmpty || attachment != nil else { return false }

        do {
            var row: [String: Any] = [
                "conversation_id": conversationID,
                "sender_id": me,
                "body": trimmed,
            ]
            if let attachment {
                row["attachment_path"] = attachment.path
                row["attachment_kind"] = attachment.kind
            }
            try await PostgREST.insert("rest/v1/messages", body: [row])
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }
}
