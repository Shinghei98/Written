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
        var partnerName: String
        let partnerPhotoSeed: Int
        /// The partner's own photograph, where they have one.
        ///
        /// **Chat drew generated portraits for everybody, including people with
        /// real faces uploaded.** `conversations` carries a `photo_seed` and
        /// nothing else, and a seed is the *synthetic* accounts' stand-in — so
        /// every real person appeared as an abstract placeholder, reported as
        /// the circular avatar being empty.
        ///
        /// Read from `discovery_cards` rather than denormalised onto the
        /// conversation row: that table is already the one place a signed-in
        /// user may read about another, it already holds the paths, and a copy
        /// here would be a second thing to keep in step every time somebody
        /// changes their photographs.
        var partnerPhotoPath: String?
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

        /// What to draw: their photograph if there is one, the generated
        /// portrait if not. The same `PhotoRef` the feed uses, so chat and
        /// Explore cannot disagree about somebody's face.
        var photoRef: DiscoveryFeed.PhotoRef {
            if let partnerPhotoPath { return .stored(partnerPhotoPath) }
            return .generated(partnerPhotoSeed)
        }
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
        /// When the recipient read it, if they have.
        ///
        /// **Carried so the thread can draw the unread divider**, and the
        /// ordering matters: opening a conversation marks everything read, so
        /// the boundary only exists in the *first* fetch. `ConversationView`
        /// takes its snapshot before `markRead` runs and holds it for the life
        /// of the page.
        var readAt: Date?

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

    /// Every thread this account is in, or **nil for "could not ask"**.
    ///
    /// **Never `[]` for a request that failed**, and that distinction is not
    /// stylistic here — it destroyed data. This used to answer `[]` both for
    /// somebody with no conversations and for a device with no reachable
    /// session, and `ChatModel.load` reads an empty answer as authoritative:
    /// it assigned it *and wrote it to `ChatStore`*. So going offline emptied
    /// the chat list and then overwrote the cache that would have filled it,
    /// leaving the threads gone until the next successful fetch.
    ///
    /// A guard existed for exactly this and could not see it — it tested
    /// `lastError`, and the no-session return set nothing. A boolean two files
    /// from the thing it protects is not a guard. The optional is, because the
    /// compiler will not let a caller ignore it.
    ///
    /// Ninth instance of this shape in the project and the first to lose
    /// anything; see `PhotoService.paths()` for the same fix.
    func conversations() async -> [Conversation]? {
        guard let me = await SupabaseAuth.shared.currentUserID() else {
            lastError = "You're not signed in."
            return nil
        }
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
            var list = rows.compactMap { Self.conversation(from: $0, me: me) }
            let cards = await Self.cards(for: list.map(\.partnerID))
            for index in list.indices {
                Self.applyCard(cards[list[index].partnerID], to: &list[index])
            }
            return list
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// What each of these people currently calls themselves, and what they look
    /// like, by user id.
    ///
    /// One request for the whole list rather than one per row — a chat list of
    /// twenty would otherwise be twenty round trips before it could draw.
    /// Failure is silent and returns nothing: the conversation's own stored
    /// name and a generated portrait are the fallback, which is a worse row
    /// rather than a broken screen.
    ///
    /// **The name is here for the same reason the photograph is.** A
    /// conversation carries `user_a_name` / `user_b_name`, written once when the
    /// thread was created out of a name `likes` had itself copied from somewhere
    /// earlier — a copy of a copy, frozen, and never corrected. A person who
    /// sets or changes their name after liking somebody is called the old thing
    /// in that chat forever. `discovery_cards` is already the one table a
    /// signed-in user may read about another, it already holds this, and a copy
    /// on the conversation row is a second thing to keep in step.
    struct Card {
        var displayName: String?
        var photoPath: String?
    }

    static func cards(for ids: [String]) async -> [String: Card] {
        let unique = Array(Set(ids))
        guard !unique.isEmpty else { return [:] }
        let rows = (try? await PostgREST.rows("rest/v1/discovery_cards", query: [
            "select": "user_id,display_name,photo_paths",
            "user_id": "in.(\(unique.joined(separator: ",")))",
        ])) ?? []

        var found: [String: Card] = [:]
        for row in rows {
            guard let id = row["user_id"] as? String else { continue }
            let name = (row["display_name"] as? String)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            found[id] = Card(
                displayName: (name?.isEmpty == false) ? name : nil,
                photoPath: (row["photo_paths"] as? [String])?.first
            )
        }
        return found
    }

    /// Applies whatever the card knows, leaving the stored values where it
    /// knows nothing. Shared by the three fetches so a thread reached from the
    /// list, from a notification tap and from accepting a like cannot disagree
    /// about who it is with.
    private static func applyCard(_ card: Card?, to conversation: inout Conversation) {
        guard let card else { return }
        if let name = card.displayName { conversation.partnerName = name }
        conversation.partnerPhotoPath = card.photoPath
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

    // MARK: - Read state

    /// Marks everything the other person has said in this thread as read.
    ///
    /// **`0009` built for this and nothing ever called it.** The column, the
    /// policy — `auth.uid() <> sender_id`, so only the recipient may — and the
    /// column grant have all existed since chat shipped, unused, which is why
    /// the app has never had an unread count or a badge.
    ///
    /// Failure is silent and deliberate: it costs a badge that is one too high
    /// until the next read, and interrupting somebody reading a message to tell
    /// them the *marking* failed would be worse than the wrong number.
    func markRead(in conversationID: String) async {
        guard let me = await SupabaseAuth.shared.currentUserID() else { return }
        _ = try? await PostgREST.update(
            "rest/v1/messages",
            query: [
                "conversation_id": "eq.\(conversationID)",
                // Never your own. The policy refuses it anyway, and a refusal
                // would take the whole statement with it.
                "sender_id": "neq.\(me)",
                // Only the ones still unread, so re-opening a thread does not
                // rewrite timestamps that already mean something.
                "read_at": "is.null",
            ],
            body: ["read_at": PostgREST.string(Date())]
        )
    }

    /// How many messages are waiting, across every thread.
    ///
    /// **No conversation filter is needed and that is not an oversight.**
    /// `messages` is readable only to participants — `0009`'s select policy —
    /// so a bare query for unread rows not sent by you returns exactly the ones
    /// addressed to you. Row-level security is doing the join.
    ///
    /// `nil` means *could not ask*, never zero. The badge is set from this, and
    /// a failed request reading as "nothing unread" would silently clear a badge
    /// that should be showing — the same defect this codebase has now met seven
    /// times.
    func unreadCount() async -> Int? {
        await unreadByConversation().map { $0.values.reduce(0, +) }
    }

    /// How many are waiting in each thread, by conversation id.
    ///
    /// **One request answers both this and the icon's total**, which is the
    /// whole reason the counting is shaped this way: the chat list draws a
    /// number per row and the app icon draws their sum, and asking twice for the
    /// same rows would be a second round trip for arithmetic.
    ///
    /// Threads with nothing waiting are absent rather than present as zero, so
    /// a caller reads `unread[id] ?? 0` and a row with no entry draws no badge.
    func unreadByConversation() async -> [String: Int]? {
        guard let me = await SupabaseAuth.shared.currentUserID() else { return nil }
        do {
            let rows = try await PostgREST.rows("rest/v1/messages", query: [
                "read_at": "is.null",
                "sender_id": "neq.\(me)",
                "select": "conversation_id",
            ])
            lastError = nil
            var counts: [String: Int] = [:]
            for row in rows {
                guard let id = row["conversation_id"] as? String else { continue }
                counts[id, default: 0] += 1
            }
            return counts
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    // MARK: - Reporting

    /// Files a report about somebody. See `0014_reports.sql`.
    ///
    /// Separate from the block, and both happen: `BanList` is what makes them
    /// disappear, this is what tells us why. A block that quietly also filed a
    /// report would be reporting people who only wanted to unmatch.
    func report(_ personID: String, named name: String, body: String) async -> Bool {
        guard let me = await SupabaseAuth.shared.currentUserID() else {
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
        guard let me = await SupabaseAuth.shared.currentUserID() else { return nil }
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
            if let made = await Self.resolved(inserted.first, me: me) {
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

    /// One conversation by its own id.
    ///
    /// **For a tapped notification, which knows the id and should not have to
    /// wait for a list.** Opening a thread used to mean loading every
    /// conversation and searching it, and on a cold launch that fetch races
    /// `restoreSession` — so the tap landed on an empty chat list saying "No
    /// conversations yet" and pushed the thread a second or two later, which
    /// reads as the tap having gone to the wrong place and then correcting
    /// itself. One row is one round trip and needs nothing else to have
    /// happened.
    ///
    /// `validAccessToken()` inside `PostgREST.send` is what makes this safe
    /// during a cold launch: it refreshes rather than reading the in-memory
    /// token, which is nil until `restoreSession` has been round the network.
    func conversation(id: String) async -> Conversation? {
        guard let me = await SupabaseAuth.shared.currentUserID() else { return nil }
        do {
            let rows = try await PostgREST.rows("rest/v1/conversations", query: [
                "id": "eq.\(id)",
                "select": "id,user_a,user_b,user_a_name,user_b_name,"
                    + "user_a_photo_seed,user_b_photo_seed,last_message,last_message_at,last_message_kind",
            ])
            return await Self.resolved(rows.first, me: me)
        } catch {
            return nil
        }
    }

    /// One row, with the partner's current name and face applied.
    ///
    /// **The single-conversation fetches used to skip this entirely**, so a
    /// thread opened from a notification tap drew the generated portrait and the
    /// frozen name while the same thread opened from the list drew the real
    /// ones — the very bug `cards(for:)` exists to fix, still present on the two
    /// paths that do not go through the list.
    private static func resolved(_ row: [String: Any]?, me: String) async -> Conversation? {
        guard let row, var made = conversation(from: row, me: me) else { return nil }
        applyCard(await cards(for: [made.partnerID])[made.partnerID], to: &made)
        return made
    }

    private func conversation(with partnerID: String) async -> Conversation? {
        guard let me = await SupabaseAuth.shared.currentUserID() else { return nil }
        let pair = [me, partnerID].map { $0.lowercased() }.sorted()
        do {
            let rows = try await PostgREST.rows("rest/v1/conversations", query: [
                "user_a": "eq.\(pair[0])",
                "user_b": "eq.\(pair[1])",
                "select": "id,user_a,user_b,user_a_name,user_b_name,"
                    + "user_a_photo_seed,user_b_photo_seed,last_message,last_message_at,last_message_kind",
            ])
            return await Self.resolved(rows.first, me: me)
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
                "select": "id,sender_id,body,created_at,read_at,attachment_path,attachment_kind",
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
                    attachmentKind: row["attachment_kind"] as? String,
                    readAt: (row["read_at"] as? String).flatMap(PostgREST.date)
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
        guard let me = await SupabaseAuth.shared.currentUserID() else { return false }
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
