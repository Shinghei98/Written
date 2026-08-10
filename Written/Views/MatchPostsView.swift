import SwiftUI

/// Every photograph a match has, one card each, in the order they arranged them.
///
/// **The reference is Instagram's "Posts", reached by tapping a tile in the
/// grid**, and the important part of that reference is what it *does not* do:
/// it shows the account's posts once, in order, and stops. So does this. No
/// rotation, no pairing, no repetition — six photographs are six cards, one
/// photograph is one card, and the last one is followed by the end of the list.
///
/// **That is the opposite rule from `DiscoveryFeed`, deliberately.** The feed
/// repeats people because discovery is endless and a person seen once with two
/// photographs is a person you have barely met; this is one particular person,
/// already matched, opened on purpose. Repeating them here would make a profile
/// of four pictures read as a profile of forty — the same argument
/// `BookmarksView` makes for taking one round and stopping.
///
/// **The card itself is `DiscoveryCard`, verbatim.** It used to be a bare
/// photograph with a caption strip under it, which meant one person had two
/// treatments — the framed card in Explore and something plainer on the page you
/// reach *after* matching, which is where somebody actually reads a profile.
/// `BookmarksView` set the precedent for reusing it rather than drawing a second
/// version, and the same argument applies twice over here.
///
/// **Nothing about `DiscoveryCard` had to change to make the verbs right**, and
/// that is worth knowing before anybody adds a flag to it. Handed `isLiked`, it
/// already fills the heart red and disables it, greys the envelope and disables
/// that too, and leaves the bookmark live — because saving somebody is a note to
/// yourself rather than an answer to them, which is written beside the button.
/// An invitation exists by definition on this page: `match_profile()` returns
/// rows only to somebody holding a like or a conversation.
struct MatchPostsView: View {

    let personID: String
    let name: String
    let age: Int?
    let district: String?
    /// In the order the owner arranged them — `photo_paths` is `position`
    /// order, and `PhotoService.slots` exists precisely so that order survives.
    let paths: [String]
    /// One per photograph, positionally. `nil` where there was nothing true to
    /// say about the two of you — see `MatchProfileService.captions`.
    let captions: [String?]
    /// Which tile was tapped. The list opens on it rather than at the top,
    /// because the tap named a photograph and arriving somewhere else would
    /// read as the tap having missed.
    let opening: Int

    var isBookmarked = false
    var onBookmark: () -> Void = {}
    var onMore: () -> Void = {}
    var onClose: () -> Void = {}

    var body: some View {
        ZStack(alignment: .top) {
            GardenPalette.parchment.ignoresSafeArea()

            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 14) {
                            ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                                DiscoveryCard(
                                    profile: card,
                                    containerWidth: geometry.size.width,
                                    // An invitation has already been sent and
                                    // spent — see the note on this type.
                                    isLiked: true,
                                    // Whether it carried a note is not on
                                    // `MatchProfileService.Profile`, and the
                                    // visible difference is one greyed glyph
                                    // against another. Not worth widening the
                                    // gated function's row for.
                                    isMessaged: false,
                                    isBookmarked: isBookmarked,
                                    onBookmark: onBookmark,
                                    onMore: onMore
                                )
                                .id(index)
                            }
                        }
                        .padding(.top, Self.headerHeight + 12)
                        .padding(.bottom, 32)
                    }
                    .onAppear {
                        // No animation: the page should already be there when it
                        // arrives, not scroll into place while somebody watches.
                        proxy.scrollTo(opening, anchor: .top)
                    }
                }
            }

            header
        }
        .preferredColorScheme(.light)
    }

    /// One card per photograph, built from what the gated function returned.
    ///
    /// The id is per *appearance*, matching `DiscoveryFeed.Profile`'s own rule —
    /// one person's six photographs are six rows, and `ForEach` given six
    /// identical ids is undefined behaviour, which hung the app outright the
    /// last time it happened with recurring shared posts.
    ///
    /// **`lines` is empty rather than a placeholder** where a caption ran out.
    /// The card draws nothing there, which is right: two real libraries share one
    /// or two specific things and almost never six, and inventing the other four
    /// is the single thing this feature must not do.
    private var cards: [DiscoveryFeed.Profile] {
        paths.enumerated().map { index, path in
            DiscoveryFeed.Profile(
                id: "\(personID)-\(index)",
                personID: personID,
                name: name,
                age: age,
                district: district,
                photos: [.stored(path)],
                lines: caption(at: index).map { [$0] } ?? []
            )
        }
    }

    private static let headerHeight: CGFloat = 44

    /// `Posts`, and whose. Two lines, as the reference has them — the title says
    /// what the list is and the name says whose it is, and neither is obvious
    /// from a page of photographs alone.
    private var header: some View {
        ZStack {
            VStack(spacing: 0) {
                Text("Posts")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(GardenPalette.ink)
                Text(name)
                    .font(.system(size: 13))
                    .foregroundStyle(GardenPalette.muted)
            }

            HStack {
                Button(action: onClose) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(GardenPalette.ink)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")

                Spacer()
            }
        }
        .frame(height: Self.headerHeight)
        .padding(.horizontal, 8)
        .background(GardenPalette.parchment.opacity(0.96))
    }

    private func caption(at index: Int) -> String? {
        captions.indices.contains(index) ? captions[index] : nil
    }
}
