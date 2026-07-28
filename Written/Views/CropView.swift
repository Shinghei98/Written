import SwiftUI

/// Frames a picked photo to the shape a post is shown at.
///
/// The ratio comes from `ExampleProfileCard.photoAspect` rather than a number
/// typed here, so the crop and the thing it is cropping *for* cannot drift
/// apart. Someone framing a photo is deciding what a stranger sees; if the
/// preview and the post disagree, the decision was meaningless.
///
/// Pan and pinch, with the frame fixed and the image moving under it — the same
/// arrangement the map picker uses, and for the same reason: "what is in the
/// frame" and "what will be saved" can never disagree if only one of them moves.
struct CropView: View {

    let image: UIImage
    /// Only changes the wording. A video is framed by the same gesture on the
    /// same still — it just isn't cut afterwards.
    var isVideo = false
    var onCancel: () -> Void = {}

    /// The framed image, and the same framing as a rectangle in **unit
    /// coordinates** — 0…1 across the source.
    ///
    /// Both, because the two kinds of media need different halves. A photo is
    /// cropped for real and the rect is incidental; a video keeps its file and
    /// the rect *is* the crop, applied when it is played and eventually baked in
    /// by the export pass that has to compress it anyway. Unit coordinates so
    /// the number outlives any particular resolution.
    var onCrop: (UIImage, CGRect) -> Void = { _, _ in }

    /// Width over height. 4:5 — Instagram's portrait post, and what the example
    /// profile card draws.
    private static let aspect = ExampleProfileCard.photoAspect

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    /// Never below 1: zooming out past the frame would leave gaps, and a post
    /// with parchment showing through its corners is not a crop, it's a mistake.
    private static let zoomRange: ClosedRange<CGFloat> = 1...5

    var body: some View {
        GeometryReader { geometry in
            let frame = Self.cropFrame(in: geometry.size)

            ZStack {
                Color.black.ignoresSafeArea()

                imageLayer(frame: frame, container: geometry.size)

                // Everything outside the frame, dimmed. A mask rather than four
                // rectangles, so the corner radius matches the post exactly.
                Rectangle()
                    .fill(.black.opacity(0.55))
                    .ignoresSafeArea()
                    .reverseMask {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .frame(width: frame.width, height: frame.height)
                    }
                    .allowsHitTesting(false)

                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(.white.opacity(0.9), lineWidth: 1.5)
                    .frame(width: frame.width, height: frame.height)
                    .allowsHitTesting(false)

                controls(frame: frame, container: geometry.size)
            }
        }
        .preferredColorScheme(.dark)
    }

    private func imageLayer(frame: CGSize, container: CGSize) -> some View {
        let base = Self.baseScale(image: image.size, frame: frame)

        return Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(width: image.size.width * base, height: image.size.height * base)
            .scaleEffect(scale)
            .offset(offset)
            .gesture(
                SimultaneousGesture(
                    DragGesture()
                        .onChanged { value in
                            offset = CGSize(
                                width: lastOffset.width + value.translation.width,
                                height: lastOffset.height + value.translation.height
                            )
                        }
                        .onEnded { _ in
                            withAnimation(.easeOut(duration: 0.2)) { clamp(frame: frame) }
                            lastOffset = offset
                        },
                    MagnificationGesture()
                        .onChanged { value in
                            scale = min(max(lastScale * value, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
                        }
                        .onEnded { _ in
                            lastScale = scale
                            withAnimation(.easeOut(duration: 0.2)) { clamp(frame: frame) }
                            lastOffset = offset
                        }
                )
            )
    }

    private func controls(frame: CGSize, container: CGSize) -> some View {
        VStack {
            Spacer()

            Text(isVideo ? "Pinch and drag to choose what shows" : "Pinch to zoom, drag to reposition")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.bottom, 14)

            HStack(spacing: 12) {
                Button("Cancel", action: onCancel)
                    .buttonStyle(
                        PressShrinkButtonStyle(
                            fill: .white.opacity(0.14), foreground: .white,
                            expands: false, font: .system(size: 16, weight: .semibold),
                            horizontalPadding: 30, minHeight: 50
                        )
                    )

                Button(isVideo ? "Use video" : "Use photo") {
                    let (framed, rect) = cropped(frame: frame)
                    onCrop(framed, rect)
                }
                .buttonStyle(
                    PressShrinkButtonStyle(
                        fill: .white, foreground: .black,
                        expands: false, font: .system(size: 16, weight: .semibold),
                        horizontalPadding: 30, minHeight: 50
                    )
                )
            }
            .padding(.bottom, 28)
        }
    }

    // MARK: - Geometry

    private static func cropFrame(in container: CGSize) -> CGSize {
        // As wide as the screen allows, then as tall as the ratio demands —
        // unless that overflows, in which case height leads instead.
        let width = min(container.width - 40, (container.height - 200) * aspect)
        return CGSize(width: width, height: width / aspect)
    }

    /// The scale at which the image just covers the frame. Everything else is
    /// measured from here, so `scale == 1` always means "filling it exactly".
    private static func baseScale(image: CGSize, frame: CGSize) -> CGFloat {
        max(frame.width / image.width, frame.height / image.height)
    }

    /// Stops the image being dragged away from the frame it is filling.
    private func clamp(frame: CGSize) {
        let base = Self.baseScale(image: image.size, frame: frame)
        let shown = CGSize(
            width: image.size.width * base * scale,
            height: image.size.height * base * scale
        )
        let slackX = max(0, (shown.width - frame.width) / 2)
        let slackY = max(0, (shown.height - frame.height) / 2)
        offset = CGSize(
            width: min(max(offset.width, -slackX), slackX),
            height: min(max(offset.height, -slackY), slackY)
        )
    }

    /// What is inside the frame, as an image and as a unit rectangle.
    private func cropped(frame: CGSize) -> (UIImage, CGRect) {
        // Orientation first. `cgImage` ignores `imageOrientation`, so cropping a
        // photo taken in portrait without normalising takes the rectangle from a
        // sideways picture — the classic "why is my crop rotated" bug.
        let upright = Self.normalized(image)
        guard let cgImage = upright.cgImage else { return (upright, CGRect(x: 0, y: 0, width: 1, height: 1)) }

        let base = Self.baseScale(image: upright.size, frame: frame)
        let total = base * scale

        // Frame size and centre, expressed in the image's own pixels.
        let size = CGSize(width: frame.width / total, height: frame.height / total)
        let centre = CGPoint(
            x: upright.size.width / 2 - offset.width / total,
            y: upright.size.height / 2 - offset.height / total
        )
        var rect = CGRect(
            x: centre.x - size.width / 2,
            y: centre.y - size.height / 2,
            width: size.width,
            height: size.height
        )
        rect = rect.intersection(CGRect(origin: .zero, size: upright.size))

        // The same framing as fractions of the source, which is what a video
        // keeps: resolution-independent, so it still means the right thing after
        // the export pass downscales the file.
        let unit = CGRect(
            x: rect.minX / upright.size.width,
            y: rect.minY / upright.size.height,
            width: rect.width / upright.size.width,
            height: rect.height / upright.size.height
        )

        // `cgImage` is in pixels; `size` is in points.
        let pixel = upright.scale
        let inPixels = CGRect(
            x: rect.minX * pixel, y: rect.minY * pixel,
            width: rect.width * pixel, height: rect.height * pixel
        )
        guard let cut = cgImage.cropping(to: inPixels) else { return (upright, unit) }
        return (UIImage(cgImage: cut, scale: pixel, orientation: .up), unit)
    }

    /// Redraws the image with its orientation applied, so `cgImage` matches what
    /// the user was looking at.
    private static func normalized(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }
}

private extension View {
    /// Punches the given shape *out* of the receiver.
    func reverseMask<Mask: View>(@ViewBuilder _ mask: () -> Mask) -> some View {
        self.mask {
            Rectangle()
                .overlay(alignment: .center) {
                    mask().blendMode(.destinationOut)
                }
        }
    }
}
