import SwiftUI

/// A stand-in portrait, generated from a seed.
///
/// There are no photographs for the synthetic accounts and there is no way to
/// invent one honestly, so this draws something that is plainly not a person: a
/// seeded gradient, a soft disc where a face would be, and the initial. Six
/// different seeds give one person six visibly different pictures, which is
/// what makes the without-replacement rule in `DiscoveryFeed` something you can
/// check by looking rather than only in a log.
///
/// **The same code path real photographs will use.** The feed asks for a seed
/// and gets a view; when files exist, `PortraitView` gains a branch that loads
/// them and nothing above it changes. `ExampleProfile.photoAsset` is the
/// pattern to follow — loose bundle resources loaded by URL, not an asset
/// catalog, so `Image("name")` will not find them.
struct PortraitPlaceholder: View {
    let seed: Int
    /// Drawn over the gradient. The person's initial, not their whole name — a
    /// placeholder that spells out a name reads as a profile with a missing
    /// photo rather than as a placeholder.
    var initial: String = ""

    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            ZStack {
                LinearGradient(
                    colors: [Self.warm(seed, 0), Self.warm(seed, 1)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                // A head-and-shoulders suggestion, so the frame reads as a
                // portrait at a glance and the feed's rhythm is legible.
                VStack(spacing: -size * 0.10) {
                    Circle()
                        .fill(Color.white.opacity(0.22))
                        .frame(width: size * 0.30, height: size * 0.30)
                    Circle()
                        .fill(Color.white.opacity(0.18))
                        .frame(width: size * 0.62, height: size * 0.62)
                        .offset(y: size * 0.20)
                }
                .offset(y: -size * 0.02)

                Text(initial.prefix(1).uppercased())
                    .font(.system(size: size * 0.20, weight: .semibold, design: .serif))
                    .foregroundColor(.white.opacity(0.85))
            }
            .clipped()
        }
    }

    /// Two related hues off the seed, kept warm so a card does not fight the
    /// parchment around it.
    ///
    /// The hue is spread across the whole wheel but the saturation and
    /// brightness are held in a narrow band — free hue gives six people six
    /// distinguishable pictures, while free brightness would give some of them
    /// portraits too dark to read the initial on.
    private static func warm(_ seed: Int, _ index: Int) -> Color {
        var generator = SeededGenerator(seed: UInt64(abs(seed)) &+ 1)
        let base = Double(generator.next() % 1000) / 1000
        let hue = (base + Double(index) * 0.06).truncatingRemainder(dividingBy: 1)
        return Color(
            hue: hue,
            saturation: 0.32 + Double(index) * 0.06,
            brightness: 0.62 - Double(index) * 0.10
        )
    }
}

/// A seed for somebody who has no `discovery_cards` row to take one from.
///
/// Real accounts have none — that table is written only by
/// `tools/seed_synthetic.py` — so an admirer or a chat partner arrives with a
/// name and nothing to draw. The initial is what identifies them either way;
/// this only has to be *stable*, so the same person is not a different colour on
/// two screens.
///
/// Folded by hand rather than through `hashValue`, which Swift seeds per process:
/// it would give one person a different portrait on every launch, and a different
/// one again on the other device.
enum PortraitSeed {
    static func stable(for userID: String) -> Int {
        var accumulated: UInt64 = 5381
        for byte in userID.utf8 {
            accumulated = accumulated &* 33 &+ UInt64(byte)
        }
        // Small and positive: `PortraitPlaceholder.warm` takes `abs(seed)` into a
        // `UInt64`, so a negative or enormous value is a crash rather than a hue.
        return Int(accumulated % 1000)
    }
}

/// What the feed actually asks for: a picture for a seed.
///
/// One place to change when photographs arrive.
struct PortraitView: View {
    let seed: Int
    var initial: String = ""

    var body: some View {
        PortraitPlaceholder(seed: seed, initial: initial)
    }
}

/// One picture in the feed: a real photograph where the person has one, the
/// generated portrait where they do not.
///
/// **The branch is the whole point.** The six synthetic accounts have seeds and
/// no files; everybody real has object paths and no seeds. `DiscoveryFeed`
/// collapses the two into `PhotoRef` so the draw is one cycle, and this is where
/// that decision becomes two different things on screen.
///
/// Stored photographs are read through a signed URL, because `profile-photos` is
/// private — a public bucket would put people's faces on the open web the moment
/// one link escaped. The URL is fetched per appearance and the *image* is cached
/// by object path, for the reason `MediaService` documents: the signed URL
/// differs every time and so would never hit `URLCache`.
struct ProfilePhotoView: View {
    let ref: DiscoveryFeed.PhotoRef?
    var initial: String = ""

    @State private var image: UIImage?

    var body: some View {
        Group {
            switch ref {
            case .generated(let seed):
                PortraitPlaceholder(seed: seed, initial: initial)

            case .stored(let path):
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    // The placeholder does duty as the loading state too. A
                    // blank rectangle would read as a broken photograph, and
                    // this at least carries the person's initial.
                    PortraitPlaceholder(seed: path.hashValue, initial: initial)
                        .task { image = await ProfilePhotoCache.shared.image(at: path) }
                }

            case nil:
                PortraitPlaceholder(seed: 0, initial: initial)
            }
        }
        .clipped()
    }
}

/// Object path to image, once per path — and once per *install*, not per launch.
///
/// Keyed by **path, not URL**, because a signed URL is different on every
/// request — caching by it would mean every appearance of the same face is a
/// fresh download. The same trap `MediaService` records for chat attachments,
/// and the reason `URLCache` cannot help here at all.
///
/// **The memory-only version is why the app opened slowly.** Every face cost
/// two sequential round trips behind the token refresh — a POST to sign a URL,
/// because the bucket is private and asking for the URL *is* the permission
/// check, then the download — and the dictionary died with the process, so a
/// chat list of six faces paid twelve requests on every cold launch. Apps that
/// feel instant are showing bytes they already had.
///
/// **Stale-while-revalidate, because there is no version to key on.**
/// `public.photos` carries `created_at` and no `updated_at`, and re-picking a
/// slot overwrites the object at the same path — so a path cannot tell you
/// whether its bytes changed. The disk copy is therefore drawn *immediately*
/// and checked *afterwards*: a conditional GET carrying the stored `ETag`
/// answers 304 when nothing moved, and the picture is replaced quietly when it
/// did. The cost of being wrong is one stale face for one appearance; the cost
/// of waiting instead is the delay this exists to remove.
///
/// **Account-scoped, and cleared on sign-out.** These are other people's faces
/// held on disk under an authorisation that ends when the session does —
/// `AccountScope` keys the directory, and `signOutLocalState()` empties it, for
/// the same reason the record and ban stores are cleared there.
actor ProfilePhotoCache {

    static let shared = ProfilePhotoCache()

    private var cached: [String: UIImage] = [:]
    /// Paths already revalidated this launch, so scrolling a list past the same
    /// face twenty times asks once.
    private var revalidated: Set<String> = []

    /// `Caches`, not Application Support: this is derived data that can always
    /// be fetched again, and the OS may evict it under pressure. Putting it in
    /// Application Support would ask the system to preserve somebody else's
    /// face forever.
    private static var directory: URL? {
        guard let base = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let url = base.appendingPathComponent("photo-cache/\(AccountScope.current)",
                                              isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A file name that cannot collide or escape the directory: an object path
    /// contains a slash, and `<user>/0.jpg` written literally would be a write
    /// into a subdirectory that may not exist.
    private static func fileName(for path: String) -> String {
        String(path.map { $0 == "/" ? "_" : $0 })
    }

    private static func fileURL(for path: String) -> URL? {
        directory?.appendingPathComponent(fileName(for: path))
    }

    private static func etagURL(for path: String) -> URL? {
        directory?.appendingPathComponent(fileName(for: path) + ".etag")
    }

    func image(at path: String) async -> UIImage? {
        if let hit = cached[path] {
            Task { await revalidateOnce(path) }
            return hit
        }
        if let url = Self.fileURL(for: path),
           let data = try? Data(contentsOf: url),
           let image = UIImage(data: data) {
            cached[path] = image
            // Drawn now, checked after. The whole point of the disk copy is
            // that nobody waits on the check.
            Task { await revalidateOnce(path) }
            return image
        }
        return await download(path, etag: nil)
    }

    /// Evict one path, for when this device is the thing that changed it.
    ///
    /// A person replacing their own photograph is the one case where staleness
    /// is unacceptable — they took the picture, they expect to see it — and it
    /// is also the one case the device knows about without asking anybody.
    func forget(_ path: String) {
        cached[path] = nil
        revalidated.remove(path)
        if let url = Self.fileURL(for: path) { try? FileManager.default.removeItem(at: url) }
        if let url = Self.etagURL(for: path) { try? FileManager.default.removeItem(at: url) }
    }

    /// Everything, for sign-out.
    static func clear() {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    private func revalidateOnce(_ path: String) async {
        guard !revalidated.contains(path) else { return }
        revalidated.insert(path)
        let etag = Self.etagURL(for: path).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        _ = await download(path, etag: etag)
    }

    @discardableResult
    private func download(_ path: String, etag: String?) async -> UIImage? {
        guard let url = await PhotoService.shared.readURL(for: path) else { return nil }
        var request = URLRequest(url: url)
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        // 304 is the good answer: the bytes on disk are current and cost
        // nothing to keep.
        if http.statusCode == 304 { return cached[path] }
        guard (200..<300).contains(http.statusCode), let image = UIImage(data: data) else {
            return nil
        }

        cached[path] = image
        if let fileURL = Self.fileURL(for: path) { try? data.write(to: fileURL, options: .atomic) }
        if let tag = http.value(forHTTPHeaderField: "ETag"), let tagURL = Self.etagURL(for: path) {
            try? tag.write(to: tagURL, atomically: true, encoding: .utf8)
        }
        return image
    }
}
