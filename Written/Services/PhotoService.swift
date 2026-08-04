import Foundation
import UIKit

/// Puts the profile photographs somewhere they survive.
///
/// **`PhotoEntryView` has picked, framed and displayed them since the first
/// build and dropped every one on Continue.** So a profile had no face, a
/// reinstall lost what was chosen, and the discovery feed drew generated
/// portraits from six random integers. This is the half that was missing.
///
/// Shaped like `MediaService`, which does the same job for chat attachments —
/// same bucket-then-row pattern, same private bucket read through short-lived
/// signed URLs, and the same reason for building the object path by hand rather
/// than with `appendingPathComponent` (see the note in `upload`).
actor PhotoService {

    static let shared = PhotoService()

    private static let bucket = "profile-photos"

    /// Longest edge after re-encoding. A profile photograph is shown at most a
    /// screen wide, and a raw iPhone capture is several times that for no gain
    /// anybody can see — the bucket's 15 MB ceiling exists for when this fails,
    /// not as the working case.
    private static let maxEdge: CGFloat = 1600
    private static let jpegQuality: CGFloat = 0.82

    private(set) var lastError: String?

    /// Read-once, for the one caller that reports a failure it did not cause —
    /// see `AppShell`. Clearing it is what stops the same refusal being drawn
    /// again on a later trip through the shell.
    func clearLastError() { lastError = nil }

    /// Uploads what the photo page collected and records the order.
    ///
    /// **Order is the point of the table.** A bucket knows names, not sequence,
    /// and the grid position somebody put a picture in is the order they meant —
    /// so `position` is the array index, and re-uploading writes over that
    /// position rather than appending a seventh photograph.
    ///
    /// Returns the object paths in position order, which is what the discovery
    /// card carries.
    @discardableResult
    func upload(_ media: [PickedMedia?]) async -> [String] {
        guard let token = await SupabaseAuth.shared.validAccessToken() else {
            lastError = "You're not signed in."
            return []
        }
        // After the token, never before: the refresh is what fills the id in on
        // a cold launch, and reading it first reports "not signed in" for a
        // session that is merely not restored yet.
        guard let userID = await SupabaseAuth.shared.userID else {
            lastError = "No account id."
            return []
        }

        var paths: [String] = []

        for (position, item) in media.enumerated() {
            guard let item else { continue }
            guard let path = await send(
                item, position: position, userID: userID, token: token
            ) else { continue }
            paths.append(path)
        }

        if !paths.isEmpty { lastError = nil }
        return paths
    }

    /// One slot, saved on its own.
    ///
    /// **The dashboard has no Continue button**, so a photograph changed there
    /// has to save the moment it changes — and re-sending all six because one of
    /// them moved would spend somebody's connection re-uploading pictures that
    /// are already sitting in the bucket.
    ///
    /// Returns nil on success, or the reason it failed. A `String?` rather than
    /// a throw because every caller wants the same thing with it — to put it in
    /// front of the user — and `lastError` alone is what let this path stay
    /// silent for as long as it did.
    func upload(_ item: PickedMedia, at position: Int) async -> String? {
        guard let token = await SupabaseAuth.shared.validAccessToken() else {
            lastError = "You're not signed in."
            return lastError
        }
        guard let userID = await SupabaseAuth.shared.userID else {
            lastError = "No account id."
            return lastError
        }
        guard await send(item, position: position, userID: userID, token: token) != nil else {
            return lastError ?? "The photo didn't save."
        }
        lastError = nil
        return nil
    }

    /// Takes a photograph down, from both halves.
    ///
    /// **The bucket and the table have to be cleared together**, and the object
    /// goes first: a row pointing at a file that is gone draws a broken picture,
    /// while a file with no row pointing at it is merely unreferenced. If the
    /// second step fails, the first has already made the photograph unreadable.
    ///
    /// The path is read back rather than assumed to be `<position>.jpg`. It is
    /// today, but it was `.mp4` for video and would be again — reconstructing a
    /// key from a convention is how a delete silently misses.
    func remove(position: Int) async -> String? {
        guard let token = await SupabaseAuth.shared.validAccessToken() else {
            lastError = "You're not signed in."
            return lastError
        }
        guard let userID = await SupabaseAuth.shared.userID else {
            lastError = "No account id."
            return lastError
        }

        if let path = await path(position: position, userID: userID, token: token) {
            _ = await delete(
                url: URL(string: "\(AppConfig.supabaseURL.absoluteString)/storage/v1/object/\(Self.bucket)/\(path)"),
                token: token
            )
        }

        var components = URLComponents(
            url: AppConfig.supabaseURL.appendingPathComponent("rest/v1/photos"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "user_id", value: "eq.\(userID)"),
            URLQueryItem(name: "position", value: "eq.\(position)")
        ]
        guard await delete(url: components?.url, token: token) else {
            return lastError ?? "Couldn't remove that photo."
        }
        lastError = nil
        return nil
    }

    /// The photographs this account already has, newest state first — used on a
    /// fresh device, where the files exist and nothing local points at them.
    func paths() async -> [String] {
        guard let token = await SupabaseAuth.shared.validAccessToken(),
              let userID = await SupabaseAuth.shared.userID else { return [] }

        var components = URLComponents(
            url: AppConfig.supabaseURL.appendingPathComponent("rest/v1/photos"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "select", value: "object_path,position"),
            URLQueryItem(name: "user_id", value: "eq.\(userID)"),
            URLQueryItem(name: "order", value: "position.asc")
        ]
        guard let url = components?.url else { return [] }

        var request = URLRequest(url: url)
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { return [] }

        return rows.compactMap { $0["object_path"] as? String }
    }

    /// The same rows, keeping the slot each one belongs to.
    ///
    /// `paths()` discards the position because the discovery card only wants an
    /// ordered list. The grid wants the arrangement: somebody can have
    /// photographs in slots 0, 2 and 5, and dropping them into 0, 1, 2 would
    /// silently rearrange a profile its owner laid out.
    func slots() async -> [(position: Int, path: String)] {
        guard let token = await SupabaseAuth.shared.validAccessToken(),
              let userID = await SupabaseAuth.shared.userID else { return [] }

        var components = URLComponents(
            url: AppConfig.supabaseURL.appendingPathComponent("rest/v1/photos"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "select", value: "object_path,position"),
            URLQueryItem(name: "user_id", value: "eq.\(userID)"),
            URLQueryItem(name: "order", value: "position.asc")
        ]
        guard let url = components?.url else { return [] }

        var request = URLRequest(url: url)
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { return [] }

        return rows.compactMap { row in
            guard let path = row["object_path"] as? String,
                  let position = row["position"] as? Int,
                  (0..<6).contains(position)
            else { return nil }
            return (position, path)
        }
    }

    /// A signed URL to read one back.
    ///
    /// The bucket is private — every signed-in user may read it, but only
    /// through a request that proves they are signed in. Asking for the URL *is*
    /// the permission check. An hour is far longer than a card stays on screen
    /// and short enough that a copied link is not a lasting hole, which matters
    /// more here than for chat: this is somebody's face.
    ///
    /// Deliberately not shared with `MediaService.readURL`, which hardcodes its
    /// own bucket. Two nearly identical functions beat one with a bucket
    /// parameter that lets a caller sign a URL into the wrong bucket by typo.
    func readURL(for path: String) async -> URL? {
        guard let token = await SupabaseAuth.shared.validAccessToken(),
              let url = URL(
                string: "\(AppConfig.supabaseURL.absoluteString)/storage/v1/object/sign/\(Self.bucket)/\(path)"
              )
        else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["expiresIn": 3600])

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0),
              let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let signed = body["signedURL"] as? String
        else { return nil }
        // The API answers a path relative to `/storage/v1` **with a leading
        // slash**, so resolving it against a base URL discards `/storage/v1` and
        // returns an address that 404s. Concatenated instead — the same trap
        // `MediaService` records.
        return URL(string: "\(AppConfig.supabaseURL.absoluteString)/storage/v1\(signed)")
    }

    // MARK: - The two halves

    /// Encode, put, record — the three steps both entry points share.
    private func send(
        _ item: PickedMedia, position: Int, userID: String, token: String
    ) async -> String? {
        guard let payload = await encode(item) else {
            lastError = "Couldn't prepare that photo."
            return nil
        }
        guard let path = await put(
            payload, userID: userID, position: position, token: token
        ) else { return nil }

        await record(
            path: path, position: position, item: item,
            userID: userID, token: token
        )
        return path
    }

    /// The object key currently recorded for one slot, if any.
    private func path(position: Int, userID: String, token: String) async -> String? {
        var components = URLComponents(
            url: AppConfig.supabaseURL.appendingPathComponent("rest/v1/photos"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "select", value: "object_path"),
            URLQueryItem(name: "user_id", value: "eq.\(userID)"),
            URLQueryItem(name: "position", value: "eq.\(position)")
        ]
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { return nil }
        return rows.first?["object_path"] as? String
    }

    /// One DELETE, against Storage or PostgREST — both answer the same shape.
    private func delete(url: URL?, token: String) async -> Bool {
        guard let url else {
            lastError = "Couldn't build the address."
            return false
        }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            lastError = "Couldn't reach the server."
            return false
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            lastError = (body?["message"] as? String) ?? "Delete failed (\(status))."
            return false
        }
        return true
    }

    /// Re-encoded on the way out, not on the way in.
    ///
    /// A video keeps its file and carries a crop rect instead — the same trade
    /// `PickedMedia` documents, since cropping during a compression pass that is
    /// already running is nearly free and cropping now would cost a second one.
    /// Video re-encoding is not done here yet, so a video is uploaded as picked
    /// and the bucket's ceiling is what stops an enormous one.
    private func encode(_ item: PickedMedia) async -> (data: Data, ext: String, mime: String)? {
        // **Video is commented out rather than left live**, and this is the
        // reason it is not offered in the picker either. There is no re-encoding
        // pass, so this uploaded whatever the camera produced — a raw iPhone
        // capture is far past the bucket's ceiling, which means the upload fails
        // at the door after the person has already waited for it.
        //
        // Left here, unreachable and visible, because the missing piece is one
        // `AVAssetExportSession` and deleting the branch would hide that.
        //
        // if item.isVideo {
        //     guard let data = try? Data(contentsOf: item.url) else { return nil }
        //     return (data, "mp4", "video/mp4")
        // }
        guard !item.isVideo else { return nil }
        // The thumbnail *is* the framed photograph — `PhotoEntryView` crops for
        // real before it gets here, so there is nothing else to apply.
        let image = item.thumbnail
        let scale = min(1, Self.maxEdge / max(image.size.width, image.size.height))
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        let resized = UIGraphicsImageRenderer(size: target).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let data = resized.jpegData(compressionQuality: Self.jpegQuality) else { return nil }
        return (data, "jpg", "image/jpeg")
    }

    private func put(
        _ payload: (data: Data, ext: String, mime: String),
        userID: String,
        position: Int,
        token: String
    ) async -> String? {
        // `<user_id>/<position>.<ext>` — the owner first, because `0015`'s
        // policies read `storage.foldername(name)[1]` and compare it to
        // `auth.uid()`. Position rather than a UUID so replacing a picture
        // overwrites the one it replaces instead of leaving an orphan behind.
        let path = "\(userID)/\(position).\(payload.ext)"

        // Built as a string, **not** with `appendingPathComponent`: that method
        // percent-encodes the separator, so a two-segment key arrives as one
        // flat name, `foldername` finds no owner, and the write is refused. The
        // identical trap is documented in `MediaService.put`.
        guard let url = URL(
            string: "\(AppConfig.supabaseURL.absoluteString)/storage/v1/object/\(Self.bucket)/\(path)"
        ) else {
            lastError = "Couldn't build the upload address."
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(payload.mime, forHTTPHeaderField: "Content-Type")
        // The name is deterministic, so re-picking position 2 must overwrite it.
        request.setValue("true", forHTTPHeaderField: "x-upsert")

        do {
            let (data, response) = try await URLSession.shared.upload(for: request, from: payload.data)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                lastError = (body?["message"] as? String) ?? "Photo upload failed (\(status))."
                return nil
            }
            return path
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// The row that says where this one sits.
    private func record(
        path: String, position: Int, item: PickedMedia,
        userID: String, token: String
    ) async {
        let body: [String: Any] = [
            "user_id": userID,
            "position": position,
            "object_path": path,
            "kind": item.isVideo ? "video" : "photo",
            "crop_x": item.cropRect.origin.x,
            "crop_y": item.cropRect.origin.y,
            "crop_w": item.cropRect.width,
            "crop_h": item.cropRect.height
        ]

        var request = URLRequest(url: AppConfig.supabaseURL.appendingPathComponent("rest/v1/photos"))
        request.httpMethod = "POST"
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // `merge-duplicates` is safe here: `0009` is the only migration that
        // revokes update, and it does not touch this table — so the upsert's
        // `on conflict do update` has the privileges it needs. Re-picking a
        // position rewrites its row rather than colliding on the primary key.
        request.setValue("resolution=merge-duplicates,return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        if let (data, response) = try? await URLSession.shared.data(for: request),
           !(200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0) {
            lastError = String(data: data, encoding: .utf8) ?? "Couldn't record the photo."
        }
    }
}
