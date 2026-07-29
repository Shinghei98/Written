import Security
import Social
import UIKit
import UniformTypeIdentifiers

/// Share a YouTube link into Written from anywhere on the phone.
///
/// Built on the template's `SLComposeServiceViewController`, which already is
/// the sheet this needs: a text view for the message, Post and Cancel, and the
/// system's own presentation. Hosting SwiftUI here would be more code to arrive
/// somewhere less native.
///
/// **Deliberately self-contained.** It repeats a little of the app — the
/// Supabase host and anon key, a keychain read, the link parsing — rather than
/// sharing those files, because the project uses Xcode's synchronized folders:
/// everything under `Written/` belongs to the app target, and putting files in
/// two targets means exactly the `project.pbxproj` surgery that arrangement
/// exists to avoid. The repeated pieces are small, public and change rarely; a
/// broken project file would cost more than they do.
///
/// The one thing it does not duplicate is authority. It reads the session the
/// app already holds and writes as that user, under the same row-level security
/// as everything else.
class ShareViewController: SLComposeServiceViewController {

    /// The link the host app handed over, once it has been read. Loading an
    /// attachment is asynchronous, so it is not known when the sheet appears.
    private var link: String?
    private var videoID: String?
    /// Whatever the host app actually handed over, kept for the message shown
    /// when it cannot be parsed. "That isn't a YouTube link" is not much use
    /// when the link plainly was one; saying what arrived is.
    private var received: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        placeholder = "Say something about it — optional"
        Task { @MainActor in
            received = await sharedItem()
            link = received.flatMap(Self.firstLink(in:))
            videoID = link.flatMap(SharePoster.videoID(from:))
            if videoID == nil {
                // Nothing to share. Said immediately rather than letting someone
                // type a sentence about a link that will be refused at Post —
                // and quoting what arrived, because the first version of this
                // said "not a YouTube link" about links that were.
                textView.text = ""
                placeholder = received.map { "Can't read a video from: \($0.prefix(80))" }
                    ?? "Nothing was shared"
            }
            // Post is disabled until this runs, because `isContentValid` cannot
            // answer before the attachment has loaded.
            validateContent()
        }
    }

    /// The message is optional; the link is not.
    override func isContentValid() -> Bool { videoID != nil }

    override func didSelectPost() {
        let message = contentText ?? ""
        guard let link else { return complete() }
        Task {
            await SharePoster.post(link: link, message: message)
            await MainActor.run { complete() }
        }
    }

    override func configurationItems() -> [Any]! { [] }

    private func complete() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    /// Whatever was shared, as text.
    ///
    /// **Text as well as URLs**, which is what this got wrong. Only
    /// `public.url` attachments were read, and an app that shares its link as
    /// plain text — or as a sentence with the link inside it, which is what most
    /// share sheets actually send — was skipped entirely, leaving nothing to
    /// parse and a message blaming the link.
    private func sharedItem() async -> String? {
        let wanted = [UTType.url.identifier, UTType.plainText.identifier, UTType.text.identifier]
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []

        for item in items {
            for provider in item.attachments ?? [] {
                for type in wanted where provider.hasItemConformingToTypeIdentifier(type) {
                    let loaded = try? await provider.loadItem(forTypeIdentifier: type)
                    if let url = loaded as? URL { return url.absoluteString }
                    if let text = loaded as? String, !text.isEmpty { return text }
                    if let data = loaded as? Data,
                       let text = String(data: data, encoding: .utf8), !text.isEmpty {
                        return text
                    }
                }
            }
            // Some apps put the link only in the item's own text.
            if let text = item.attributedContentText?.string, !text.isEmpty { return text }
        }
        return nil
    }

    /// The first web address inside whatever arrived.
    ///
    /// `URL(string:)` on the whole thing is not enough: a share is often a
    /// sentence with a link in it, and one space is all it takes for that to
    /// return nil. `NSDataDetector` finds the link wherever it sits.
    private static func firstLink(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.host != nil { return trimmed }

        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        return detector?.firstMatch(in: trimmed, range: range)?.url?.absoluteString
    }
}

// MARK: - Writing it

/// The smallest client that can attribute a row to the signed-in user.
private enum SharePoster {
    static let host = "https://fwnezkbesjoazlpaflbq.supabase.co"

    /// Public by design — it ships inside the app binary too. Row-level security
    /// is what protects the data, not this key.
    static let anonKey = """
        eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9\
        .eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZ3bmV6a2Jlc2pvYXpscGFmbGJxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODUyMDQwNDUsImV4cCI6MjEwMDc4MDA0NX0\
        .ZDITVhCgRMJvBqlkVeViHS6d12yltY63i9h3JcXwoGo
        """

    /// Mirrors `SharedPostService.parse`. The id is the identity — a watch link,
    /// a `youtu.be` link and a Short are three ways of writing one video — and
    /// the eleven-character check is what makes a Short with a trailing slug
    /// fail here rather than become a card that renders nothing.
    static func videoID(from link: String) -> String? {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host?.lowercased() else { return nil }
        let path = url.pathComponents.filter { $0 != "/" }

        if host.hasSuffix("youtu.be") { return path.first.flatMap(valid) }
        guard host.hasSuffix("youtube.com") else { return nil }

        if path.first == "watch",
           let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "v" })?.value {
            return valid(v)
        }
        if let kind = path.first, ["shorts", "embed", "live", "v"].contains(kind), path.count > 1 {
            return valid(path[1])
        }
        return nil
    }

    private static func valid(_ candidate: String) -> String? {
        let id = candidate.prefix { $0 != "?" && $0 != "&" }
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        guard id.count == 11, id.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return String(id)
    }

    static func post(link: String, message: String) async {
        guard let videoID = videoID(from: link),
              let refresh = keychain("supabase_refresh_token"),
              let session = await exchange(refresh: refresh)
        else { return }

        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        var row: [String: Any] = [
            "sharer_id": session.userID,
            "sharer_name": session.name,
            "provider": "youtube",
            "video_id": videoID,
        ]
        if !trimmed.isEmpty { row["message"] = trimmed }

        var request = URLRequest(url: URL(string: host + "/rest/v1/shared_posts")!)
        request.httpMethod = "POST"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer " + session.token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [row])
        _ = try? await URLSession.shared.data(for: request)
    }

    /// The refresh token, out of the keychain group the app and this share.
    private static func keychain(_ key: String) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.written.datingapp.tokens",
            kSecAttrAccount as String: key,
            kSecAttrAccessGroup as String: "947DHTL37S.com.written.datingapp",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &result) != errSecSuccess {
            // Written before the app named a group, which is where the session
            // of anyone already signed in still lives. Same fallback the app
            // makes, for the same reason: nobody should have to sign in again
            // because of a change to where a token is filed.
            query.removeValue(forKey: kSecAttrAccessGroup as String)
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
            else { return nil }
        }
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private struct Session { let token: String; let userID: String; let name: String }

    /// A refresh token is all the extension is given; an access token is what
    /// PostgREST wants. The name comes from the user's own row, which their own
    /// policy already allows them to read.
    private static func exchange(refresh: String) async -> Session? {
        var request = URLRequest(
            url: URL(string: host + "/auth/v1/token?grant_type=refresh_token")!
        )
        request.httpMethod = "POST"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["refresh_token": refresh]
        )

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = body["access_token"] as? String,
              let user = body["user"] as? [String: Any],
              let userID = user["id"] as? String
        else { return nil }

        return Session(token: token, userID: userID, name: await name(token: token) ?? "Someone")
    }

    private static func name(token: String) async -> String? {
        var request = URLRequest(
            url: URL(string: host + "/rest/v1/users?select=first_name&limit=1")!
        )
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        return rows.first?["first_name"] as? String
    }
}
