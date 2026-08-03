import AVFoundation
import Foundation
import UIKit

/// Puts a picked photo or video into the `chat-media` bucket.
///
/// **The first thing in this project to write to Storage.** Everything else that
/// leaves the device is a row; this is bytes, and the two differ in a way worth
/// stating: a row is protected by the policy on its table, whereas a file is
/// protected by *where it is put*. Objects go to
/// `<conversation_id>/<uuid>.<ext>` and `0010`'s policies read that first path
/// segment back to decide who may see them, so the path is not a detail — it is
/// the authorisation. Change the shape and the policies stop matching.
///
/// Uploads go through `URLSession` directly rather than `PostgREST`: Storage is
/// a different API on the same host, it takes raw bytes rather than JSON, and it
/// wants the file's own content type.
actor MediaService {

    static let shared = MediaService()

    private static let bucket = "chat-media"

    /// What a caller needs to write onto a message.
    struct Upload {
        let path: String
        /// `photo` or `video`, matching `messages.attachment_kind`.
        let kind: String
    }

    private(set) var lastError: String?

    /// Compresses, uploads, and hands back what to store on the message.
    ///
    /// Returns nil rather than throwing, like every other service here, and
    /// records why — but unlike a failed like this one **must** be shown, which
    /// is why `ConversationView` surfaces it. A photo that silently fails to
    /// send is a message the sender believes they sent.
    func upload(_ media: PickedMedia, to conversationID: String) async -> Upload? {
        guard let token = await SupabaseAuth.shared.validAccessToken() else {
            lastError = "You're not signed in."
            return nil
        }

        let payload: (data: Data, ext: String, mime: String, kind: String)?
        if media.isVideo {
            payload = await Self.video(at: media.url)
        } else {
            payload = Self.photo(media.thumbnail)
        }
        guard let payload else {
            lastError = "That file couldn't be prepared for sending."
            return nil
        }
        return await put(payload, to: conversationID, token: token)
    }

    /// A voice memo, already recorded to a file by `VoiceMemo`.
    ///
    /// Separate from `upload(_:to:)` because there is nothing to prepare: the
    /// recorder wrote AAC in an m4a container straight to disk at the bitrate we
    /// want, so re-encoding it would cost time and quality to arrive at the same
    /// file. Everything after the payload is identical, which is what `put`
    /// exists for.
    func uploadVoice(at url: URL, to conversationID: String) async -> Upload? {
        guard let token = await SupabaseAuth.shared.validAccessToken() else {
            lastError = "You're not signed in."
            return nil
        }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            lastError = "That recording couldn't be read."
            return nil
        }
        // `audio/mp4`, not `audio/m4a` — the latter is not a registered type and
        // Storage hands it back on download as something no player will open.
        return await put(
            (data: data, ext: "m4a", mime: "audio/mp4", kind: "audio"),
            to: conversationID, token: token
        )
    }

    private func put(
        _ payload: (data: Data, ext: String, mime: String, kind: String),
        to conversationID: String,
        token: String
    ) async -> Upload? {
        let path = "\(conversationID)/\(UUID().uuidString).\(payload.ext)"

        // Built as a string, **not** with `appendingPathComponent`. That method
        // treats what it is given as a single component and percent-encodes the
        // separator inside it, so a two-segment object key arrives as
        // `convId%2Fuuid.jpg` — one flat name rather than a folder. Storage
        // accepts it, and then `0010`'s policies read `foldername(name)[1]` and
        // find the whole key instead of a conversation id, so the cast to uuid
        // fails and the write is refused.
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
        // Storage would otherwise 409 a repeated name. The name is a fresh UUID
        // so a collision cannot happen, but a retry of the *same* upload can.
        request.setValue("true", forHTTPHeaderField: "x-upsert")

        do {
            let (data, response) = try await URLSession.shared.upload(
                for: request, from: payload.data
            )
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                lastError = (body?["message"] as? String)
                    ?? "Upload failed (\(status))."
                return nil
            }
            lastError = nil
            return Upload(path: path, kind: payload.kind)
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// A signed URL to read one back.
    ///
    /// The bucket is private, so there is no permanent address for an object —
    /// asking for one is itself the permission check, and it fails for anybody
    /// not in the conversation. An hour is far longer than a thread stays open
    /// and short enough that a copied link is not a lasting hole.
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
        // The API answers `/object/sign/<bucket>/<path>?token=…` — a path
        // relative to `/storage/v1`, with a **leading slash**. Resolving that
        // against a base URL is exactly wrong: a leading slash means "from the
        // root", so `URL(string:relativeTo:)` discards `/storage/v1` and returns
        // an address that 404s. Concatenated instead.
        return URL(string: "\(AppConfig.supabaseURL.absoluteString)/storage/v1\(signed)")
    }

    /// The bytes for an attachment, from disk if they are already here.
    ///
    /// **Cache first, and that is the point.** The bucket is private, so reading
    /// an object means signing a URL and then fetching it — two round trips
    /// before anything can be drawn, and the signed URL differs every time so no
    /// HTTP cache can help. Filing the bytes under the stable object path turns
    /// every open after the first into a disk read, which is what makes a thread
    /// full of photos open at once rather than filling in.
    func data(for path: String) async -> Data? {
        if let cached = ChatStore.attachment(for: path) { return cached }

        guard let url = await readURL(for: path),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0)
        else { return nil }

        ChatStore.saveAttachment(data, for: path)
        return data
    }

    /// Files a locally-made image against an object path before it is ever
    /// downloaded — used for the poster frame of a video the sender just sent,
    /// so their own thread shows the still immediately.
    func seedCache(_ data: Data, for path: String) {
        ChatStore.saveAttachment(data, for: path)
    }

    // MARK: - Preparing the bytes

    /// JPEG at a sane size. A 48-megapixel iPhone photo is nobody's chat message.
    private static func photo(_ image: UIImage) -> (Data, String, String, String)? {
        let longest: CGFloat = 1600
        let scale = min(1, longest / max(image.size.width, image.size.height))
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        let renderer = UIGraphicsImageRenderer(size: target)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let data = resized.jpegData(compressionQuality: 0.82) else { return nil }
        return (data, "jpg", "image/jpeg", "photo")
    }

    /// Re-encoded, not sent raw.
    ///
    /// `PickedMedia` says why in its own comment — a raw iPhone video is larger
    /// than a bucket will take. `AVAssetExportPresetMediumQuality` is the cheap
    /// answer and it is the right one here: this is a phone-sized video watched
    /// in a bubble, not an archive.
    private static func video(at url: URL) async -> (Data, String, String, String)? {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetMediumQuality
        ) else { return nil }

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("written-send-\(UUID().uuidString).mp4")
        session.outputURL = output
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true

        await session.export()
        guard session.status == .completed,
              let data = try? Data(contentsOf: output)
        else { return nil }
        // The compressed copy has been read into memory; the file itself is
        // temporary and there is no reason to leave it on disk.
        try? FileManager.default.removeItem(at: output)
        return (data, "mp4", "video/mp4", "video")
    }
}
