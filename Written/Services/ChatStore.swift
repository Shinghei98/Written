import Foundation

/// The device's own copy of the chat, so opening one is a disk read.
///
/// **This is the difference between this chat and the ones people are used to.**
/// WhatsApp, iMessage and Instagram are local-first: the on-device store is what
/// the UI draws, and the network writes into it in the background. There is no
/// loading state for content you already have, which is why their threads do not
/// blink. Before this, every open refetched from nothing and showed an empty
/// screen — and worse, an empty screen that said "No conversations yet", because
/// the view could not tell "still loading" from "there is nothing here".
///
/// Shaped after `RecordStore`: Application Support rather than Caches, one set of
/// files per account, cleared on sign-out.
///
/// **Two file formats, for one reason.** The conversation list is a small JSON
/// array rewritten whole — it is a row per thread and changes rarely. A thread's
/// messages are newline-delimited JSON, one object per line, because history is
/// kept forever: a JSON array would have to be re-encoded and rewritten in full
/// for every message sent, which is O(thread) per send and grows without bound.
/// A line can simply be appended. Reading the whole file back on open is the
/// cheap direction of that trade.
enum ChatStore {

    // MARK: - Where things live

    private static var directory: URL? {
        try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
    }

    /// Everything this store writes begins with this, which is what makes
    /// `clear()` able to find its own files and nobody else's.
    /// **`v2` because `Message` gained `read_at`, and the old files lie.**
    /// A cached message written before that field existed decodes with
    /// `readAt = nil`, which is indistinguishable from genuinely unread — so an
    /// ancient message put the unread band at the top of a thread and kept it
    /// there through every relaunch, while the chat list, which asks the server,
    /// showed nothing. Renaming the file discards those in one move.
    ///
    /// **Bump this whenever `Message` or `Conversation` gains a field whose
    /// absence means something.** An optional that decodes to nil is a value,
    /// not a gap, and every reader downstream will treat it as one. The old
    /// files are left on disk rather than deleted: they are small, and
    /// `signOutLocalState` clears the directory anyway.
    private static var prefix: String { "written-chat-v2-\(AccountScope.current)" }

    private static var conversationsURL: URL? {
        directory?.appendingPathComponent("\(prefix)-conversations.json")
    }

    private static func messagesURL(_ conversationID: String) -> URL? {
        // The id is a uuid from the server, so it is already safe in a filename;
        // the filter is here so a malformed one cannot escape the directory.
        let safe = conversationID.filter { $0.isHexDigit || $0 == "-" }
        guard !safe.isEmpty else { return nil }
        return directory?.appendingPathComponent("\(prefix)-messages-\(safe).jsonl")
    }

    // MARK: - The conversation list

    static func conversations() -> [ChatService.Conversation] {
        guard let conversationsURL,
              let data = try? Data(contentsOf: conversationsURL),
              let rows = try? JSONDecoder().decode([ChatService.Conversation].self, from: data)
        else { return [] }
        return rows
    }

    /// Fire-and-forget, off the main actor — the same reason `RecordStore.save`
    /// is: writing the cache should never be in the way of drawing it.
    static func save(_ conversations: [ChatService.Conversation]) {
        Task.detached(priority: .utility) {
            guard let conversationsURL,
                  let data = try? JSONEncoder().encode(conversations)
            else { return }
            try? data.write(to: conversationsURL, options: .atomic)
        }
    }

    // MARK: - A thread

    static func messages(in conversationID: String) -> [ChatService.Message] {
        guard let url = messagesURL(conversationID),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return [] }

        let decoder = JSONDecoder()
        // A half-written final line is possible if the app was killed mid-append,
        // so a line that will not decode is skipped rather than taking the thread
        // down with it. The server is the source of truth; a lost line comes back
        // on the next fetch.
        return text
            .split(separator: "\n")
            .compactMap { line in
                guard let data = line.data(using: .utf8) else { return nil }
                return try? decoder.decode(ChatService.Message.self, from: data)
            }
    }

    /// Rewrites a thread whole. Used after a merge or a page of older history,
    /// where the order changes rather than growing at the end.
    static func replace(_ messages: [ChatService.Message], in conversationID: String) {
        Task.detached(priority: .utility) {
            guard let url = messagesURL(conversationID) else { return }
            let encoder = JSONEncoder()
            let lines = messages.compactMap { message -> String? in
                guard let data = try? encoder.encode(message) else { return nil }
                return String(data: data, encoding: .utf8)
            }
            let text = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Downloaded photos and videos

    /// Keyed by the object's **path**, not by the URL it was fetched from.
    ///
    /// That distinction is the whole reason this exists. `chat-media` is
    /// private, so every read needs a freshly signed URL — which means the URL
    /// is different on every appearance, and `URLCache` can never hit. Before
    /// this, opening a thread re-downloaded every photo in it, in full, every
    /// time. The path is stable for the life of the message, so it is what the
    /// bytes are filed under.
    ///
    /// Same `prefix` as everything else here, so `clear()` sweeps these on
    /// sign-out without needing to know about them — which matters more for
    /// media than for text: these are other people's photographs.
    private static func attachmentURL(_ path: String) -> URL? {
        // `<conversation>/<uuid>.<ext>` — the separator has to go or it would
        // be read as a directory that does not exist.
        let safe = path.replacingOccurrences(of: "/", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }
        guard !safe.isEmpty else { return nil }
        return directory?.appendingPathComponent("\(prefix)-media-\(safe)")
    }

    static func attachment(for path: String) -> Data? {
        guard let url = attachmentURL(path) else { return nil }
        return try? Data(contentsOf: url)
    }

    static func saveAttachment(_ data: Data, for path: String) {
        Task.detached(priority: .utility) {
            guard let url = attachmentURL(path) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Sign-out

    /// Every chat file for this account.
    ///
    /// **Wired into `DistillViewModel.signOutLocalState`, and it must stay
    /// wired.** This store holds other people's words, so a cache that outlived
    /// the session would be the one thing on this device that did — the exact
    /// failure `AccountScope` exists as a second line of defence against.
    ///
    /// Enumerated rather than tracked, because the thread files are named after
    /// conversation ids this store does not otherwise remember, and a list of
    /// them would be one more thing that could fall out of step with the disk.
    static func clear() {
        guard let directory,
              let names = try? FileManager.default.contentsOfDirectory(
                atPath: directory.path
              )
        else { return }
        for name in names where name.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
