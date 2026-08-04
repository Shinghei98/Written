import AVFoundation
import PhotosUI
import SwiftUI

/// The six slots, the picker, and the crop frame — everything the photo page is
/// made of except the page.
///
/// Lifted out of `PhotoEntryView` rather than copied, because the dashboard now
/// shows the same six and has to edit them the same way. Two grids that had to
/// stay in step would not: the slot ratio, the dashed empty state, the video
/// branch in `load`, and the rule that a photo is cropped for real while a video
/// keeps a rectangle are each a decision that was paid for once, and a second
/// copy is a second place to get them wrong.
///
/// The media itself belongs to the caller. Onboarding and the dashboard are
/// looking at one set of photographs, not two.
struct PhotoGrid: View {
    @Binding var media: [PickedMedia?]

    /// What each empty slot asks for. Shown during onboarding, where the
    /// prompts are doing the work of explaining what the page is for; the
    /// dashboard passes nothing and gets a plain "add" instead, since by then
    /// the grid needs no introduction.
    var prompts: [String] = []

    var columns: Int = 2
    var cornerRadius: CGFloat = 24

    /// Which slot is choosing, and what it chose.
    ///
    /// A single presented picker rather than one `PhotosPicker` button per
    /// slot. The button form swallowed the long press: a `PhotosPicker` *is* a
    /// button, and its own tap handling wins over any gesture attached around
    /// it, so the slots could never be armed for removal. Presenting it from a
    /// plain view leaves the gestures to the slot, which is what makes both a
    /// tap and a hold possible on the same thing.
    @State private var pickingIndex: Int?
    @State private var isPresentingPicker = false
    @State private var picked: PhotosPickerItem?
    @State private var isLoadingPick = false
    @State private var loadingIsVideo = false
    @State private var cropping: Crop?

    /// Which slot is armed for removal, by key. Nil when nothing is wobbling.
    ///
    /// The same shape the dashboard's entries use, so the long press, the
    /// wobble and the cross are literally the same code rather than a second
    /// version of it.
    @State private var editing: String?

    private func key(_ index: Int) -> String { "photo-\(index)" }

    /// The photo being framed, and the slot it will land in.
    private struct Crop: Identifiable {
        let index: Int
        let source: PickedMedia
        var id: Int { index }
    }

    var body: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: 12),
                count: columns
            ),
            spacing: 12
        ) {
            ForEach(0..<6, id: \.self) { index in
                slot(index)
            }
        }
        // A tap anywhere puts the armed slot away. Simultaneous, so it does not
        // swallow the tap that opens a picker — the dashboard's own entries are
        // disarmed the same way.

        // **Photographs only, and this one line is the whole of it.**
        //
        // Video is picked up again by changing this back to
        // `.any(of: [.images, .videos])` — nothing else in this file needs
        // touching, because every video branch below is written and simply
        // unreachable while the picker refuses to offer one.
        //
        // It is out because the upload is unfinished: `PhotoService.encode`
        // passes a video through untouched for want of a re-encoding pass, so a
        // raw iPhone capture fails at the bucket's ceiling. Offering a picker
        // full of videos that cannot be uploaded is worse than a picker without
        // them.
        //
        // `matching:` filters inside Apple's own picker process, so videos are
        // *absent* from the library rather than shown and refused — there is
        // nothing left for this app to enforce afterwards. Chat attachments are
        // untouched and still take video; that path is finished.
        .photosPicker(
            isPresented: $isPresentingPicker,
            selection: $picked,
            matching: .images
        )
        .onChange(of: picked) { item in
            guard let item, let index = pickingIndex else { return }
            // Cleared straight away: choosing the same photograph twice in a row
            // is otherwise a no-op the binding never reports.
            picked = nil
            loadingIsVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
            isLoadingPick = true
            Task {
                let source = await Self.load(item)
                isLoadingPick = false
                guard let source else { return }
                // Both kinds get framed. What differs is what the framing
                // produces: a cropped file for a photo, a remembered rectangle
                // for a video.
                cropping = Crop(index: index, source: source)
            }
        }
        .overlay { if isLoadingPick { loadingPick } }
        .animation(.easeOut(duration: 0.15), value: isLoadingPick)
#if DEBUG
        // `-loading video` / `-loading photo`; see `DebugLaunch`. It follows the
        // state it fakes, which now lives here rather than on the page.
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
                onCancel: { cropping = nil },
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

    private func slot(_ index: Int) -> some View {
        ZStack {
            if let media = media[index] {
                Image(uiImage: media.thumbnail)
                    .resizable()
                    .scaledToFill()

                // Unreachable while the picker is photographs only, and kept
                // for when it is not.
                if media.isVideo {
                    // Otherwise a video is indistinguishable from a still,
                    // since what's drawn *is* a still — its first frame.
                    Image(systemName: "play.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.white)
                        .padding(9)
                        .background(.black.opacity(0.45), in: Circle())
                }
            } else {
                empty(prompt: index < prompts.count ? prompts[index] : "")
            }
        }
        .frame(maxWidth: .infinity)
        // The shape a post is actually shown at, from the one place that
        // defines it — the same constant `CropView` frames to. A slot that is
        // nearly-but-not-quite the post ratio promises a composition it then
        // doesn't deliver.
        .aspectRatio(ExampleProfileCard.photoAspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    GardenPalette.ink.opacity(media[index] == nil ? 0.18 : 0),
                    // Dashed while empty: a slot you could fill, rather than a
                    // card that is missing something.
                    style: StrokeStyle(lineWidth: 1, dash: media[index] == nil ? [5, 4] : [])
                )
        }
        // Before the gestures, so the whole slot answers to them rather than
        // only the parts with something drawn in them.
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .onTapGesture {
            // A tap while something is armed puts it away rather than opening a
            // picker — the same thing tapping outside an armed row does.
            if editing != nil {
                withAnimation(.easeOut(duration: 0.18)) { editing = nil }
                return
            }
            pickingIndex = index
            isPresentingPicker = true
        }
        // Only a filled slot can be removed, and only a filled slot wobbles —
        // an empty one has nothing to take away, and a cross over a dashed
        // outline would be offering to delete a hole.
        .removable(editing: editing == key(index) && media[index] != nil, index: index) {
            withAnimation(.easeOut(duration: 0.18)) {
                media[index] = nil
                editing = nil
            }
        }
        .editableOnLongPress(media[index] == nil ? .constant(nil) : $editing, key: key(index))
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

                if !prompt.isEmpty {
                    Text(prompt)
                        .font(.system(size: 13))
                        .foregroundStyle(GardenPalette.muted)
                        .multilineTextAlignment(.center)
                        .lineSpacing(1)
                        .padding(.horizontal, 14)
                }
            }
        }
    }

    /// Holds the grid still while a pick is read, rather than letting it return
    /// to a grid with a hole in it.
    private var loadingPick: some View {
        ZStack {
            GardenPalette.parchment.opacity(0.86)
            VStack(spacing: 10) {
                ProgressView().tint(GardenPalette.gold)
                Text(loadingIsVideo ? "Loading video…" : "Loading photo…")
                    .font(.system(size: 13))
                    .foregroundStyle(GardenPalette.muted)
            }
        }
        .allowsHitTesting(true)
    }

    /// Turns a picked item into a file plus a thumbnail, whichever kind it is.
    ///
    /// **The movie branch is dormant** while the picker offers photographs only
    /// — see the `.photosPicker` above. It is correct and simply unreachable,
    /// and it is kept rather than removed so restoring video is one line there
    /// rather than a rewrite here.
    ///
    /// The branch is on what the item actually *is* rather than on what the
    /// picker was configured to allow — `supportedContentTypes` is the item's
    /// own answer, and asking it is what stops a video being loaded down the
    /// image path and coming back undrawable. That is also why it stays: the
    /// safety does not depend on the filter being right.
    /// Internal rather than private: the chat's compose bar picks media too, and
    /// a second copy of this would be a second place for the video path's traps
    /// to be got wrong — `loadTransferable(type: Data.self)` silently failing on
    /// movies is the one this already documents.
    static func load(_ item: PhotosPickerItem) async -> PickedMedia? {
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

}
