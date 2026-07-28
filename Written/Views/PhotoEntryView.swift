import AVFoundation
import PhotosUI
import SwiftUI

/// One chosen photo or video, as a file on disk plus something to draw.
///
/// A file rather than bytes in memory: a minute of 4K video is hundreds of
/// megabytes, and six slots of it would be enough to have the app killed. The
/// thumbnail is what the grid shows; the URL is what an uploader will want.
struct PickedMedia {
    let url: URL
    /// Already framed for a photo; the poster frame, framed, for a video.
    let thumbnail: UIImage
    let isVideo: Bool

    /// How the user framed it, in unit coordinates across the source.
    ///
    /// Only meaningful for video, where the file is kept whole and this says
    /// which part of it to show. A photo is cropped for real, so its rect is
    /// always the full frame by the time it gets here.
    ///
    /// Kept rather than baked in because the file has to be re-encoded before
    /// upload anyway — a raw iPhone video is larger than a Storage bucket will
    /// take — and cropping during a compression pass you are already running
    /// costs almost nothing, while cropping now would cost a second one.
    let cropRect: CGRect

    static let fullFrame = CGRect(x: 0, y: 0, width: 1, height: 1)
}

/// Receives a picked video as a file rather than as `Data`.
///
/// `loadTransferable(type: Data.self)` is the obvious call and the wrong one for
/// video — where it works it reads the whole thing into memory, and the bytes it
/// returns are not something `UIImage` can draw, so the slot silently fell back
/// to its empty state. `FileRepresentation` hands over a URL instead.
private struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            // The received file is only valid for the duration of the call, so
            // it has to be copied somewhere we control before returning.
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("written-\(UUID().uuidString).mov")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return PickedMovie(url: destination)
        }
    }
}

/// Account creation, the step after the name: what the profile looks like.
///
/// Six slots, each with a prompt rather than an empty square. The prompts do the
/// work the subtitle promises — that a photo needn't be of your face — so they
/// ask for objects, places and evidence of a life as readily as portraits. A
/// grid of six identical "+" boxes gets six selfies; a grid of six questions
/// gets a profile worth reading, which is the whole premise of the app.
///
/// `PhotosPicker` rather than a photo-library permission: it runs out of
/// process, hands back only what the user picked, and needs no
/// `NSPhotoLibraryUsageDescription` and no permission sheet. One tap, which is
/// the prime constraint in `CLAUDE.md` applied to something that isn't a
/// distiller.
struct PhotoEntryView: View {

    /// Carries the chosen media out. Nothing is uploaded from here yet — the
    /// same shape `NameEntryView` had before there was anywhere to put a name.
    var onContinue: ([PickedMedia]) -> Void = { _ in }
    var onSkip: () -> Void = {}

    /// What each slot asks for.
    ///
    /// Deliberately not the reference app's prompts, which lead with a clear
    /// face shot and a head-to-toe — that would contradict the line directly
    /// above them.
    private static let prompts = [
        "Your face, if you want to lead with it",
        "Something you made",
        "Where you spend your time",
        "Doing something you love",
        "An object you'd never throw away",
        "Anything that needs explaining"
    ]

    @State private var media: [PickedMedia?] = Array(repeating: nil, count: 6)
    @State private var picking: [PhotosPickerItem?] = Array(repeating: nil, count: 6)
    @State private var isConfirmingSkip = false

    /// Set while a pick is being read into a `PickedMedia`.
    ///
    /// `PhotosPicker` dismisses the moment something is chosen and the loading
    /// starts *after* it, so the grid came back with an empty slot for however
    /// long the work took — which for a video is seconds, because the movie has
    /// to be exported out of the photo library before a frame can be read from
    /// it. An empty frame is indistinguishable from a tap that did nothing.
    @State private var isLoadingPick = false

    /// Which kind is loading, so the wait can say what it is waiting for. Known
    /// before the load starts: `supportedContentTypes` is the item's own answer.
    @State private var loadingIsVideo = false

    /// The photo being framed, and the slot it will land in.
    private struct Crop: Identifiable {
        let index: Int
        let source: PickedMedia
        var id: Int { index }
    }
    @State private var cropping: Crop?

    private var chosen: [PickedMedia] { media.compactMap { $0 } }

    var body: some View {
        ZStack {
            GardenPalette.parchment.ignoresSafeArea()

            VStack(spacing: 0) {
                skipButton

                Text("Add photos or videos that represent you")
                    .font(BrandFont.title(30))
                    .foregroundStyle(GardenPalette.ink)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .padding(.horizontal, 24)
                    .padding(.top, 6)

                Text("Not all photos need to include your face. It can be a drawing, a dumbbell, a page — anything.")
                    .font(.system(size: 15))
                    .foregroundStyle(GardenPalette.muted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .padding(.horizontal, 32)
                    .padding(.top, 12)

                grid

                // Appears only once there is something to continue *with*.
                // Before that the only way on is Skip, which asks first.
                if !chosen.isEmpty {
                    Button("Continue") { onContinue(chosen) }
                        .buttonStyle(PressShrinkButtonStyle())
                        .frame(width: 176)
                        .padding(.top, 4)
                        .padding(.bottom, 12)
                        .transition(.opacity)
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: chosen.count)
        .preferredColorScheme(.light)
        .overlay { if isConfirmingSkip { confirmSkip } }
        .overlay { if isLoadingPick { loadingPick } }
        .animation(.easeOut(duration: 0.15), value: isLoadingPick)
#if DEBUG
        .task {
            guard let kind = DebugLaunch.pickLoading else { return }
            loadingIsVideo = kind == "video"
            isLoadingPick = true
        }
#endif
        .fullScreenCover(item: $cropping) { crop in
            CropView(
                image: crop.source.thumbnail,
                isVideo: crop.source.isVideo,
                onCancel: {
                    // Clearing the picker too, or choosing the same photo again
                    // would be a no-op the binding never notices.
                    picking[crop.index] = nil
                    cropping = nil
                },
                onCrop: { framed, rect in
                    if crop.source.isVideo {
                        // The file is untouched; the rectangle is the crop, and
                        // the framed poster is what the grid draws meanwhile.
                        media[crop.index] = PickedMedia(
                            url: crop.source.url,
                            thumbnail: framed,
                            isVideo: true,
                            cropRect: rect
                        )
                    } else {
                        media[crop.index] = Self.store(framed)
                    }
                    cropping = nil
                }
            )
        }
    }

    // MARK: - Pieces

    /// Holds the page still while a pick is read, rather than letting it return
    /// to a grid with a hole in it.
    ///
    /// Parchment rather than a dim scrim: the page isn't being interrupted by
    /// something on top of it, it is busy — so it stays the colour it already
    /// was and the wait sits where the answer will appear.
    private var loadingPick: some View {
        ZStack {
            GardenPalette.parchment.opacity(0.92).ignoresSafeArea()

            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                    .tint(GardenPalette.ink)

                Text(loadingIsVideo ? "Preparing your video…" : "Loading…")
                    .font(.system(size: 15))
                    .foregroundStyle(GardenPalette.muted)
            }
        }
        // Swallows taps: the grid underneath is still live otherwise, and a
        // second pick started while the first is loading would land in whichever
        // slot finished last.
        .contentShape(Rectangle())
        .onTapGesture { }
        .transition(.opacity)
    }

    private var skipButton: some View {
        HStack {
            Spacer()
            Button {
                // Nothing chosen at all is the case worth pausing on. Someone
                // who added two and moved on has made a decision; someone who
                // added none may not have realised the page was interactive.
                if chosen.isEmpty {
                    withAnimation(.easeOut(duration: 0.2)) { isConfirmingSkip = true }
                } else {
                    onContinue(chosen)
                }
            } label: {
                Text("Skip")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(GardenPalette.ink)
                    .padding(.horizontal, 20)
                    .frame(height: 38)
                    .overlay {
                        Capsule().strokeBorder(GardenPalette.ink.opacity(0.18), lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    private var grid: some View {
        ScrollView(showsIndicators: false) {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                spacing: 12
            ) {
                ForEach(0..<6, id: \.self) { index in
                    slot(index)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 20)
        }
    }

    private func slot(_ index: Int) -> some View {
        PhotosPicker(
            selection: Binding(
                get: { picking[index] },
                set: { newItem in
                    picking[index] = newItem
                    guard let newItem else { return }
                    loadingIsVideo = newItem.supportedContentTypes.contains { $0.conforms(to: .movie) }
                    isLoadingPick = true
                    Task {
                        let picked = await Self.load(newItem)
                        guard let picked else {
                            // Clearing the selection too, or picking the same
                            // item again after a failure would be a no-op the
                            // binding never notices.
                            picking[index] = nil
                            isLoadingPick = false
                            return
                        }
                        // Both kinds get framed. What differs is what the
                        // framing produces: a cropped file for a photo, a
                        // remembered rectangle for a video.
                        //
                        // Presented before the wait is taken down, so the crop
                        // screen rises over it — the other order shows the grid,
                        // hole and all, for the frames in between.
                        cropping = Crop(index: index, source: picked)
                        isLoadingPick = false
                    }
                }
            ),
            matching: .any(of: [.images, .videos])
        ) {
            ZStack {
                if let picked = media[index] {
                    Image(uiImage: picked.thumbnail)
                        .resizable()
                        .scaledToFill()

                    if picked.isVideo {
                        // Otherwise a video is indistinguishable from a still,
                        // since what's drawn *is* a still — its first frame.
                        Image(systemName: "play.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(.white)
                            .padding(9)
                            .background(.black.opacity(0.45), in: Circle())
                    }
                } else {
                    empty(prompt: Self.prompts[index])
                }
            }
            .frame(maxWidth: .infinity)
            // The shape a post is actually shown at, from the one place that
            // defines it — the same constant `CropView` frames to. A slot that
            // is nearly-but-not-quite the post ratio promises a composition it
            // then doesn't deliver.
            .aspectRatio(ExampleProfileCard.photoAspect, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(
                        GardenPalette.ink.opacity(media[index] == nil ? 0.18 : 0),
                        // Dashed while empty: a slot you could fill, rather than
                        // a card that is missing something.
                        style: StrokeStyle(lineWidth: 1, dash: media[index] == nil ? [5, 4] : [])
                    )
            }
        }
        .buttonStyle(.plain)
    }

    /// Turns a picked item into a file plus a thumbnail, whichever kind it is.
    ///
    /// The branch is on what the item actually *is* rather than on what the
    /// picker was configured to allow — `supportedContentTypes` is the item's
    /// own answer, and asking it is what stops a video being loaded down the
    /// image path and coming back undrawable.
    private static func load(_ item: PhotosPickerItem) async -> PickedMedia? {
        let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }

        if isVideo {
            guard let movie = try? await item.loadTransferable(type: PickedMovie.self),
                  let frame = await firstFrame(of: movie.url)
            else { return nil }
            return PickedMedia(url: movie.url, thumbnail: frame, isVideo: true, cropRect: PickedMedia.fullFrame)
        }

        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data)
        else { return nil }

        // Not written to disk yet — this one is on its way to the crop frame,
        // and only what comes back out of that is worth keeping.
        return PickedMedia(url: URL(fileURLWithPath: ""), thumbnail: image, isVideo: false, cropRect: PickedMedia.fullFrame)
    }

    /// Writes a framed photo to a file, so both kinds hand an uploader the same
    /// thing and nothing holds image bytes for the life of the screen.
    private static func store(_ image: UIImage) -> PickedMedia? {
        guard let data = image.jpegData(compressionQuality: 0.9) else { return nil }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("written-\(UUID().uuidString).jpg")
        try? data.write(to: destination)
        return PickedMedia(url: destination, thumbnail: image, isVideo: false, cropRect: PickedMedia.fullFrame)
    }

    /// A still to represent the video in the grid.
    ///
    /// Taken half a second in rather than at zero: the very first frame of a
    /// phone recording is often black or mid-exposure, which reads as a broken
    /// thumbnail.
    private static func firstFrame(of url: URL) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        let time = CMTime(seconds: 0.5, preferredTimescale: 600)
        guard let cgImage = try? await generator.image(at: time).image else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private func empty(prompt: String) -> some View {
        ZStack {
            GardenPalette.card

            VStack(spacing: 12) {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(GardenPalette.card)
                    .frame(width: 38, height: 38)
                    .background(GardenPalette.ink, in: Circle())

                Text(prompt)
                    .font(.system(size: 13))
                    .foregroundStyle(GardenPalette.muted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(1)
                    .padding(.horizontal, 14)
            }
        }
    }

    /// Shown only when skipping with nothing chosen.
    private var confirmSkip: some View {
        ZStack(alignment: .bottom) {
            GardenPalette.ink.opacity(0.18)
                .ignoresSafeArea()
                .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { isConfirmingSkip = false } }

            VStack(alignment: .leading, spacing: 10) {
                Text("Are you sure?")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(GardenPalette.ink)

                Text("You're nearly done. A profile needs photos before anyone can see it — the prompts are there to help.")
                    .font(.system(size: 15))
                    .foregroundStyle(GardenPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    Button("Skip") {
                        isConfirmingSkip = false
                        onSkip()
                    }
                    .buttonStyle(
                        PressShrinkButtonStyle(
                            fill: GardenPalette.card,
                            foreground: GardenPalette.ink,
                            border: GardenPalette.ink.opacity(0.18),
                            expands: false,
                            font: .system(size: 16, weight: .semibold),
                            horizontalPadding: 32,
                            minHeight: 50
                        )
                    )

                    Button("Add photo") {
                        withAnimation(.easeOut(duration: 0.2)) { isConfirmingSkip = false }
                    }
                    .buttonStyle(
                        PressShrinkButtonStyle(
                            expands: false,
                            font: .system(size: 16, weight: .semibold),
                            horizontalPadding: 32,
                            minHeight: 50
                        )
                    )
                }
                .padding(.top, 6)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GardenPalette.card, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(GardenPalette.ink.opacity(0.06), lineWidth: 1)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 18)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

#Preview {
    PhotoEntryView()
}
