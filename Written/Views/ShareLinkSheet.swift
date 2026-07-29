import SwiftUI

/// Sharing a video by pasting its link.
///
/// The share extension is the intended way in — tap Share in YouTube, pick
/// Written — and this is not a placeholder for it. Pasting a link is a
/// reasonable thing to want when the video is already open in Safari, and it is
/// the only way any of this can be exercised until a second Xcode target
/// exists.
///
/// Built on `BiographicsSheet`, the same shell the dashboard's editors use, so
/// it is one dialog style rather than two.
struct ShareLinkSheet: View {
    var onShared: (SharedPostService.Post) -> Void = { _ in }
    var onCancel: () -> Void = {}

    @State private var link = ""
    @State private var message = ""
    @State private var failure: String?
    @State private var isSharing = false
    @FocusState private var isFocused: Bool

    private var trimmedLink: String {
        link.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Checked as they type rather than on confirm, so a link that will not work
    /// says so before anything is sent.
    private var isValid: Bool {
        SharedPostService.parse(trimmedLink) != nil
    }

    var body: some View {
        BiographicsSheet(
            title: "Share a video",
            subtitle: "Paste a YouTube link. Add a word about why, if you like.",
            confirmEnabled: isValid && !isSharing,
            onConfirm: share,
            onCancel: onCancel
        ) {
            VStack(spacing: 10) {
                field("YouTube link", text: $link)
                    .focused($isFocused)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                // Says so, rather than only behaving so. Nothing about this
                // field was ever required — the Confirm button is gated on the
                // link alone, the column is left out when it is empty, and the
                // card closes cleanly with no caption — but a placeholder
                // phrased as an instruction reads as one, and people fill in
                // fields they think they have to.
                field("Say something about it — optional", text: $message)

                if let failure {
                    Text(failure)
                        .font(.system(size: 12))
                        .foregroundStyle(GardenPalette.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !trimmedLink.isEmpty && !isValid {
                    // Said while typing, not after a round trip. The link is
                    // either a video or it is not, and the app can tell without
                    // asking anybody.
                    Text("That doesn't look like a YouTube video link.")
                        .font(.system(size: 12))
                        .foregroundStyle(GardenPalette.muted)
                }
            }
        }
        .onAppear { isFocused = true }
    }

    private func field(_ prompt: String, text: Binding<String>) -> some View {
        TextField(prompt, text: text)
            .font(BrandFont.body(15))
            .foregroundStyle(GardenPalette.ink)
            .padding(.vertical, 11)
            .padding(.horizontal, 14)
            .background(GardenPalette.parchment, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(GardenPalette.ink.opacity(0.08), lineWidth: 1)
            }
    }

    private func share() {
        isSharing = true
        failure = nil
        Task {
            do {
                let post = try await SharedPostService.shared.share(
                    link: trimmedLink,
                    message: message
                )
                onShared(post)
            } catch {
                // The sheet stays open. Unlike the biographics editors, this one
                // holds something the user typed out and cannot get back by
                // reopening it — dismissing over a failed share would lose the
                // message along with the link.
                failure = error.localizedDescription
                isSharing = false
            }
        }
    }
}
