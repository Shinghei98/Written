import ImageIO
import SwiftUI
import UIKit

/// Plays a bundled GIF exactly once and then holds its final frame.
///
/// `UIImageView.animationImages` only supports a uniform per-frame duration, and
/// the logo write-on uses varying delays (50–1800 ms), so the frames are driven
/// by an async task that waits out each frame's own delay instead.
struct AnimatedGIFView: View {
    let name: String
    /// Bumping this replays the animation from the first frame.
    var playToken: Int = 0

    @StateObject private var player = GIFPlayer()

    var body: some View {
        Group {
            if let image = player.frame {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Color.clear
            }
        }
        .task(id: playToken) {
            await player.play(named: name)
        }
    }
}

@MainActor
private final class GIFPlayer: ObservableObject {
    @Published var frame: UIImage?

    private var asset: GIFAsset?

    func play(named name: String) async {
        if asset == nil { asset = GIFAsset(name: name) }
        guard let asset else { return }

        let delays = await asset.delays
        guard !delays.isEmpty else { return }

        // Frames are decoded one ahead of playback rather than all upfront: the
        // first frame shows as soon as it is ready instead of after the whole
        // GIF is decoded, and only two frames are ever held in memory.
        var pending = Task.detached(priority: .userInitiated) { await asset.image(at: 0) }

        for index in delays.indices {
            guard let image = await pending.value else { return }
            if index + 1 < delays.count {
                let next = index + 1
                pending = Task.detached(priority: .userInitiated) { await asset.image(at: next) }
            }

            frame = image

            guard index + 1 < delays.count else { break }
            // Sleep against a deadline so decode time doesn't stretch the timing.
            let deadline = ContinuousClock.now + .seconds(delays[index])
            do {
                try await Task.sleep(until: deadline, clock: .continuous)
            } catch {
                return // cancelled — leave the current frame on screen
            }
        }
    }
}

/// Serializes access to one `CGImageSource`. ImageIO composites optimized GIF
/// frames itself, so each index already yields a full-canvas image.
private actor GIFAsset {
    private let source: CGImageSource?
    let delays: [Double]

    init(name: String) {
        guard let url = Bundle.main.url(forResource: name, withExtension: "gif"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        else {
            self.source = nil
            self.delays = []
            return
        }
        self.source = source
        self.delays = (0..<CGImageSourceGetCount(source)).map { Self.delay(at: $0, in: source) }
    }

    func image(at index: Int) -> UIImage? {
        guard let source, index < delays.count,
              let cgImage = CGImageSourceCreateImageAtIndex(source, index, nil)
        else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private static func delay(at index: Int, in source: CGImageSource) -> Double {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        else { return 0.1 }

        let delay = (gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
            ?? (gif[kCGImagePropertyGIFDelayTime] as? Double)
            ?? 0.1
        // Browsers treat sub-20ms delays as 100ms; match that so the pacing looks
        // like the GIF does everywhere else.
        return delay < 0.02 ? 0.1 : delay
    }
}
