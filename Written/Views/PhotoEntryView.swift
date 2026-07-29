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
/// Now shared with `PhotoGrid`, which does the loading.
struct PickedMovie: Transferable {
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

    /// The six. Bound rather than owned: the dashboard edits the same set
    /// afterwards, so there is one array and both screens point at it.
    @Binding var media: [PickedMedia?]

    @State private var isConfirmingSkip = false

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

                ScrollView(showsIndicators: false) {
                    PhotoGrid(media: $media, prompts: Self.prompts)
                        .padding(.horizontal, 20)
                        .padding(.top, 22)
                        .padding(.bottom, 20)
                }

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
    }

    // MARK: - Pieces

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
    PhotoEntryView(media: .constant(Array(repeating: nil, count: 6)))
}
