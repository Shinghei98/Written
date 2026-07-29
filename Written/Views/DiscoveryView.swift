import SwiftUI

/// The feed: other people, scrolled through.
///
/// **An ordinary scroll view, deliberately.** It was a pager for three rounds —
/// one profile to a screen, a swipe committing to the next — and every gesture
/// complaint in that time came from hand-rolling what UIKit already does. Two
/// competing `DragGesture`s were arbitrated first per event, then locked per
/// gesture, then ungated on one side; each fix moved the problem rather than
/// removing it.
///
/// Nesting a horizontal paging scroll view inside a vertical free one is how
/// Instagram is built, and the axis disambiguation, the momentum and the
/// rubber-banding all come with it. Cards are their own height now, so two can
/// be on screen at once and the feed can rest anywhere between them.
struct DiscoveryView: View {
    @StateObject private var model = DiscoveryModel()
    @State private var isSharing = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                GardenPalette.parchment.ignoresSafeArea()

                if model.items.isEmpty {
                    empty
                } else {
                    feed(width: geometry.size.width)
                }

                shareButton
            }
            .overlay {
                if isSharing {
                    ShareLinkSheet(
                        onShared: { post in
                            // Straight to the top rather than waiting for a
                            // reload to find it. Sharing something and not
                            // seeing it reads as a failure.
                            model.prepend(post)
                            isSharing = false
                        },
                        onCancel: { isSharing = false }
                    )
                }
            }
        }
        .preferredColorScheme(.light)
        .task { await model.load() }
    }

    private func feed(width: CGFloat) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 14) {
                ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                    Group {
                        switch item {
                        case .profile(let profile):
                            DiscoveryCard(profile: profile, containerWidth: width)
                        case .shared(let post):
                            SharedPostCard(post: post, containerWidth: width)
                        }
                    }
                        // Safe here in a way it was not before. A `LazyVStack`
                        // inside a `ScrollView` builds only what is near the
                        // viewport, so this fires as the reader arrives. In the
                        // old plain `VStack` every child was built at once, all
                        // twelve fired together, and each asked for six more —
                        // which froze the app on launch.
                        .onAppear { model.extend(reaching: index) }
                }
            }
            .padding(.top, 12)
            // The tab bar floats over the bottom of every page.
            .padding(.bottom, MainTabBar.overlayHeight)
        }
    }

    /// Above the tab bar and clear of it, in the corner rather than in the
    /// flow: the feed is the screen's subject and this is a way to add to it,
    /// not a thing to read.
    private var shareButton: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button { isSharing = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(GardenPalette.card)
                        .frame(width: 52, height: 52)
                        .background(GardenPalette.gold, in: Circle())
                        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Share a video")
                .padding(.trailing, 22)
                .padding(.bottom, MainTabBar.overlayHeight + 8)
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "book")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(GardenPalette.gold)
            Text("Nobody to see yet")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(GardenPalette.ink)
            Text(model.failure ?? "Profiles will appear here as people join.")
                .font(.system(size: 14))
                .foregroundStyle(GardenPalette.muted)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 40)
    }
}

/// Holds the feed.
@MainActor
final class DiscoveryModel: ObservableObject {
    @Published private(set) var items: [DiscoveryFeed.Item] = []
    @Published private(set) var failure: String?

    private var feed: DiscoveryFeed?

    func load() async {
        guard items.isEmpty else { return }
        // Both at once: the shared posts are a small query and waiting for them
        // serially would show a feed of profiles that then reshuffled itself.
        async let peopleTask = DiscoveryService.shared.people()
        async let postsTask = SharedPostService.shared.posts()
        let (people, posts) = await (peopleTask, postsTask)

        guard !people.isEmpty else {
            failure = await DiscoveryService.shared.lastError
            return
        }
        var feed = DiscoveryFeed(people: people, posts: posts)
        items = feed.nextItems(12)
        self.feed = feed
        failure = nil
    }

    /// Puts a just-shared video at the top, rather than waiting for a reload to
    /// discover it. Sharing something and not seeing it reads as a failure.
    func prepend(_ post: SharedPostService.Post) {
        items.insert(.shared(post), at: 0)
    }

    /// Grows the feed as the reader nears its end. The rotation rules already
    /// make it endless; the list only has to keep up.
    func extend(reaching index: Int) {
        guard var feed, index >= items.count - 3 else { return }
        items += feed.nextItems(6)
        self.feed = feed
    }
}

/// One person, as an Instagram post — the same furniture as
/// `ExampleProfileCard`, for the same reason.
///
/// That layout is the one every user already reads a stranger through, so the
/// caption underneath is read as *a person's words* rather than as output. The
/// example card on the profile preview makes exactly that claim about the
/// viewer's own library; a feed that dropped the format would be making a
/// weaker version of it about everyone else's.
///
/// What differs is the photo: two of them, swiped between, because a discovery
/// card is something you interrogate rather than glance at.
struct DiscoveryCard: View {
    let profile: DiscoveryFeed.Profile
    /// The feed's width, so the photo's height can be worked out rather than
    /// measured. `TabView` does not size itself to its content and ignores
    /// `aspectRatio`, so something has to tell it how tall to be.
    let containerWidth: CGFloat

    @State private var page = 0

    private static let horizontalPadding: CGFloat = 20

    private var photoHeight: CGFloat {
        (containerWidth - Self.horizontalPadding * 2) / ExampleProfileCard.photoAspect
    }
    /// "23 · Central West End" — each part dropped when unknown, so a card with
    /// no age still reads cleanly instead of carrying a stray separator.
    private var subtitle: String? {
        let parts = [profile.age.map(String.init), profile.district].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
            photos
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

    private var headerRow: some View {
        HStack(spacing: 10) {
            // The first photo, so the avatar and the post agree about who this
            // is even as the pager moves on to the second.
            PortraitView(seed: profile.photoSeeds.first ?? 0, initial: profile.name)
                .frame(width: 34, height: 34)
                .clipShape(Circle())
                .overlay { Circle().strokeBorder(GardenPalette.gold.opacity(0.35), lineWidth: 1) }

            VStack(alignment: .leading, spacing: 1) {
                Text(profile.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(GardenPalette.ink)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(GardenPalette.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(GardenPalette.muted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// Edge to edge, the way a post is, and paged sideways between the two.
    ///
    /// `TabView` rather than an offset and a drag gesture. It is a UIKit paging
    /// scroll view underneath, which is what buys the rubber-band at the ends,
    /// the momentum, and — the part that matters most here — a horizontal pan
    /// recogniser that knows to let a vertical one through to the scroll view
    /// above it. Three rounds of arbitrating that by hand is what this replaces.
    private var photos: some View {
        TabView(selection: $page) {
            ForEach(Array(profile.photoSeeds.enumerated()), id: \.offset) { index, seed in
                PortraitView(seed: seed, initial: profile.name)
                    .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(height: photoHeight)
        .overlay(alignment: .bottom) { dots }
    }

    /// Which of the two you are on. Drawn over the photo rather than under it,
    /// so the card's height does not change as the count does.
    @ViewBuilder
    private var dots: some View {
        if profile.photoSeeds.count > 1 {
            HStack(spacing: 5) {
                ForEach(0..<profile.photoSeeds.count, id: \.self) { index in
                    Circle()
                        .fill(Color.white.opacity(index == page ? 0.95 : 0.45))
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.black.opacity(0.22)))
            .padding(.bottom, 12)
        }
    }

    /// Decorative, as on the example card: none of these do anything, so they
    /// take no taps and are hidden from VoiceOver.
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

    private var caption: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(profile.lines.enumerated()), id: \.offset) { index, line in
                // The name runs into the first line the way it does on a real
                // caption, so the block reads as one utterance rather than as
                // two labelled fields.
                if index == 0 {
                    (
                        Text(profile.name).font(.system(size: 15, weight: .semibold))
                        + Text(" " + line).font(.system(size: 15))
                    )
                    .foregroundStyle(GardenPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(line)
                        .font(.system(size: 15))
                        .foregroundStyle(GardenPalette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 16)
    }
}
