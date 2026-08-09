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
/// **`DiscoveryCard`'s shape without its verbs**, like `MatchPhotoCard` before
/// it: no heart, no envelope, no bookmark. This page is reached *after* an
/// invitation exists, so offering to send one is offering something already
/// spent.
struct MatchPostsView: View {

    let name: String
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
    var onClose: () -> Void = {}

    var body: some View {
        ZStack(alignment: .top) {
            GardenPalette.parchment.ignoresSafeArea()

            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 22) {
                        ForEach(Array(paths.enumerated()), id: \.offset) { index, path in
                            post(path: path, caption: caption(at: index))
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

            header
        }
        .preferredColorScheme(.light)
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

    private func post(path: String, caption: String?) -> some View {
        VStack(spacing: 0) {
            ProfilePhotoView(ref: .stored(path), initial: name)
                // The same 4:5 the grid uses, so a photograph is the shape here
                // that it was in the tile somebody tapped.
                .aspectRatio(4.0 / 5.0, contentMode: .fill)
                .frame(maxWidth: .infinity)
                .clipped()

            // Absent rather than blank when there is nothing shared: a caption
            // slot with no caption reads as text that failed to load.
            if let caption {
                Text(caption)
                    .font(.system(size: 14))
                    .foregroundStyle(GardenPalette.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(GardenPalette.card)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption.map { "\(name). \($0)" } ?? name)
    }
}
