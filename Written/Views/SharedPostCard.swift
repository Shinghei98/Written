import SwiftUI

/// A video somebody shared, as a post.
///
/// The same furniture as `DiscoveryCard` — header, media, action row, caption —
/// because a shared video *is* a post, and giving it its own layout would say
/// otherwise. What differs is only what fills those slots.
struct SharedPostCard: View {
    let post: SharedPostService.Post
    let containerWidth: CGFloat
    /// Whether this is the card in the middle of the screen. See
    /// `DiscoveryView.activeShare`.
    var isActive = false

    /// Sound is off until asked for, and asking is per card rather than for the
    /// feed: unmuting one video should not mean the next one arrives talking.
    @State private var isMuted = true
    /// The player said it cannot show this one. Some uploaders disable
    /// embedding, which is a real answer rather than a fault — so the card says
    /// so and offers the way to watch it, instead of showing YouTube's grey
    /// panel and a numeric code inside a parchment frame.
    @State private var isUnavailable = false

    private static let horizontalPadding: CGFloat = 20

    /// The same 4:5 a photograph gets — an Instagram post's shape, from the one
    /// constant that defines it.
    ///
    /// This was 16:9 on the argument that a landscape video letterboxed into a
    /// portrait frame wastes half of it. True, and beside the point: the feed is
    /// a column of posts and a video is one of them, so it takes a post's shape.
    /// A 16:9 video will sit in the middle of this frame with space above and
    /// below, which is what Instagram does with one too.
    private var mediaHeight: CGFloat {
        (containerWidth - Self.horizontalPadding * 2) / ExampleProfileCard.photoAspect
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
            media
            actionRow
            caption
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GardenPalette.card, in: RoundedRectangle(cornerRadius: 24))
        .overlay {
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(GardenPalette.ink.opacity(0.06), lineWidth: 1)
        }
        .padding(.horizontal, Self.horizontalPadding)
    }

    /// An arrow and a byline where a profile card has a face and an age.
    ///
    /// The arrow is the whole point of the line: this is not a person, it is
    /// something a person passed on, and the difference should be legible before
    /// the words are read.
    private var headerRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.turn.up.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(GardenPalette.gold)

            // `foregroundStyle` on a `Text` being concatenated is iOS 17; the
            // colour goes on the joined result instead, so the two halves are
            // distinguished by weight rather than by shade. That reads better
            // anyway — the name is the emphasis, not a different colour of ink.
            (
                Text("shared by ").font(.system(size: 14))
                + Text(post.sharerName).font(.system(size: 14, weight: .semibold))
            )
            .foregroundColor(GardenPalette.ink)

            Spacer(minLength: 0)

            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(GardenPalette.muted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var media: some View {
        if isUnavailable {
            unavailable
        } else if post.provider == .youtube {
            ZStack(alignment: .bottomTrailing) {
                EmbedWebView(
                    videoID: post.videoID,
                    isPlaying: isActive,
                    isMuted: isMuted,
                    onUnavailable: { isUnavailable = true }
                )
                .frame(height: mediaHeight)
                    // Black behind it, not parchment: a 16:9 video in a 4:5
                    // frame leaves a band above and below, and warm paper either
                    // side of a video reads as a layout mistake where black
                    // reads as the letterboxing it is.
                    .background(Color.black)

                muteButton
            }
            // The card decides what plays, so the player has no controls of its
            // own — which leaves the tap free to mean the one thing a muted
            // autoplaying video needs it to.
            .contentShape(Rectangle())
            .onTapGesture { isMuted.toggle() }
        } else {
            // A provider the app does not know how to render. It should be
            // impossible today, since there is one, but a card that draws
            // nothing at all would be a hole in the feed with no explanation.
            unavailable
        }
    }

    /// Can't be played here — with the way to play it anyway.
    ///
    /// A dead end would be the wrong answer: the video exists, somebody wanted
    /// to show it, and only the embedding is refused.
    private var unavailable: some View {
        ZStack {
            GardenPalette.ink.opacity(0.06)
            VStack(spacing: 10) {
                Image(systemName: "play.slash")
                    .font(.system(size: 20, weight: .light))
                    .foregroundColor(GardenPalette.muted)
                Text("This one can't be played here")
                    .font(.system(size: 13))
                    .foregroundColor(GardenPalette.muted)
                if let watch = URL(string: "https://www.youtube.com/watch?v=\(post.videoID)") {
                    Link(destination: watch) {
                        Text("Watch on YouTube")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(GardenPalette.gold)
                            .padding(.horizontal, 14)
                            .frame(height: 32)
                            .overlay { Capsule().strokeBorder(GardenPalette.gold.opacity(0.4), lineWidth: 1) }
                    }
                }
            }
        }
        .frame(height: mediaHeight)
    }

    /// Says what tapping will do, and shows the current state. Small and in the
    /// corner: it is a hint about the card rather than a control the eye should
    /// land on first.
    private var muteButton: some View {
        Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: 30, height: 30)
            .background(Color.black.opacity(0.45), in: Circle())
            .padding(12)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// Decorative, exactly as on the other cards: none of these do anything, so
    /// they take no taps and are hidden from VoiceOver.
    private var actionRow: some View {
        HStack(spacing: 16) {
            Image(systemName: "heart")
            Image(systemName: "bubble.right")
            Image(systemName: "paperplane")
            Spacer(minLength: 0)
            Image(systemName: "bookmark")
        }
        .font(.system(size: 19, weight: .regular))
        .foregroundStyle(GardenPalette.ink.opacity(0.75))
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// What the sharer said, opening with their name in bold — the same shape a
    /// profile's caption takes, since both are a person talking.
    @ViewBuilder
    private var caption: some View {
        if let message = post.message, !message.isEmpty {
            (
                Text(post.sharerName).font(.system(size: 15, weight: .semibold))
                + Text(" " + message).font(.system(size: 15))
            )
            .foregroundStyle(GardenPalette.ink)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 16)
        } else {
            // No message is a real choice — someone can pass a video on without
            // saying anything — so the card closes cleanly rather than leaving
            // the caption's padding behind as a gap.
            Color.clear.frame(height: 16)
        }
    }
}
