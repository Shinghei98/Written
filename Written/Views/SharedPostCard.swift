import SwiftUI

/// A video somebody shared, as a post.
///
/// The same furniture as `DiscoveryCard` — header, media, action row, caption —
/// because a shared video *is* a post, and giving it its own layout would say
/// otherwise. What differs is only what fills those slots.
struct SharedPostCard: View {
    let post: SharedPostService.Post
    let containerWidth: CGFloat

    private static let horizontalPadding: CGFloat = 20

    /// 16:9 rather than the 4:5 a photograph gets.
    ///
    /// A video letterboxed into a portrait frame is two thick black bars and a
    /// small picture — the frame would be honouring the card's rhythm at the
    /// expense of the thing the card is for. The row of cards is already varied
    /// in height, since a caption can run to two lines.
    private var mediaHeight: CGFloat {
        (containerWidth - Self.horizontalPadding * 2) * 9 / 16
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
        if let url = post.provider.embed(post.videoID) {
            EmbedWebView(url: url)
                .frame(height: mediaHeight)
        } else {
            // A row whose provider or id cannot make a URL. It should be
            // impossible — the id is validated before anything is stored — but
            // a card that renders nothing at all would be a hole in the feed
            // with no explanation.
            ZStack {
                GardenPalette.ink.opacity(0.06)
                Text("This video can't be shown")
                    .font(.system(size: 13))
                    .foregroundStyle(GardenPalette.muted)
            }
            .frame(height: mediaHeight)
        }
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
