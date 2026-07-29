import SwiftUI

/// The feed: other people, one card at a time, swiped up and down.
///
/// Paged rather than free-scrolling. A profile is a thing you consider and then
/// move past, and a scroll view that can rest halfway between two of them turns
/// that into a list you skim — which is the opposite of what the card is for.
struct DiscoveryView: View {
    @StateObject private var model = DiscoveryModel()

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                GardenPalette.parchment.ignoresSafeArea()

                if model.profiles.isEmpty {
                    empty
                } else {
                    pager(in: geometry.size)
                }
            }
        }
        .preferredColorScheme(.light)
        .task { await model.load() }
    }

    private func pager(in size: CGSize) -> some View {
        // Hand-paged rather than `TabView(.page)`: the vertical page style
        // brings its own indicator and its own bounce, and the feed has a tab
        // bar overlaying its bottom edge that both would collide with.
        //
        // **A window, not the whole feed.** A plain `VStack` builds every child
        // immediately — there is no scroll view here for a `LazyVStack` to be
        // lazy against — so rendering the full list meant every card's
        // `onAppear` firing at once. The three at the end each asked the feed to
        // extend, which appended six more, whose `onAppear`s asked again: an
        // endless list growing as fast as it could be built, which froze the app
        // on launch because `AppShell` mounts every tab whether or not you are
        // looking at it. Four cards is all that can ever be on screen or one
        // swipe away from it.
        let low = max(0, model.index - 1)
        let high = min(model.profiles.count - 1, model.index + 2)

        return VStack(spacing: 0) {
            ForEach(low...high, id: \.self) { index in
                DiscoveryCard(profile: model.profiles[index])
                    .frame(width: size.width, height: size.height)
            }
        }
        .frame(width: size.width, alignment: .top)
        .offset(y: -CGFloat(model.index - low) * size.height + model.drag)
        .animation(.interactiveSpring(response: 0.32, dampingFraction: 0.86), value: model.index)
        .gesture(
            // Vertical only. The card's photos page sideways, and both
            // gestures see every touch — each ignores the axis that is not
            // theirs rather than one of them winning outright, which is what
            // lets a swipe across a photo not also throw the feed.
            DragGesture(coordinateSpace: .global)
                .onChanged { value in
                    guard abs(value.translation.height) > abs(value.translation.width) else { return }
                    model.drag = value.translation.height
                }
                .onEnded { value in
                    model.drag = 0
                    guard abs(value.translation.height) > abs(value.translation.width) else { return }
                    // A quarter of the screen, or a flick — the same commit
                    // rule the garden's pull-up uses.
                    let projected = value.predictedEndTranslation.height
                    if projected < -size.height * 0.25 {
                        model.advance(by: 1)
                    } else if projected > size.height * 0.25 {
                        model.advance(by: -1)
                    }
                }
        )
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

/// Holds the feed and how far through it the reader is.
@MainActor
final class DiscoveryModel: ObservableObject {
    @Published private(set) var profiles: [DiscoveryFeed.Profile] = []
    @Published var index = 0
    @Published var drag: CGFloat = 0
    @Published private(set) var failure: String?

    private var feed: DiscoveryFeed?

    func load() async {
        guard profiles.isEmpty else { return }
        let people = await DiscoveryService.shared.people()
        guard !people.isEmpty else {
            failure = await DiscoveryService.shared.lastError
            return
        }
        var feed = DiscoveryFeed(people: people)
        profiles = feed.next(12)
        self.feed = feed
        failure = nil
    }

    /// Grows the feed rather than wrapping it. The rotation rules already make
    /// it endless; the list just has to keep up.
    ///
    /// Driven by where the reader is, never by a card appearing. Appearance is
    /// not a reliable signal here — the pager builds its cards eagerly, so an
    /// `onAppear` that extends the feed extends it again for every card the
    /// extension itself created.
    private func extendIfNeeded() {
        guard var feed, index > profiles.count - 4 else { return }
        profiles += feed.next(6)
        self.feed = feed
    }

    func advance(by delta: Int) {
        index = max(0, min(profiles.count - 1, index + delta))
        extendIfNeeded()
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

    @State private var page = 0
    @State private var dragX: CGFloat = 0

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
        .padding(.horizontal, 20)
        // Clear of the tab bar, which floats over every page.
        .padding(.bottom, MainTabBar.overlayHeight)
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
    private var photos: some View {
        Color.clear
            .aspectRatio(ExampleProfileCard.photoAspect, contentMode: .fit)
            .overlay {
                GeometryReader { geometry in
                    let width = geometry.size.width
                    HStack(spacing: 0) {
                        ForEach(Array(profile.photoSeeds.enumerated()), id: \.offset) { _, seed in
                            PortraitView(seed: seed, initial: profile.name)
                                .frame(width: width, height: geometry.size.height)
                        }
                    }
                    .offset(x: -CGFloat(page) * width + dragX)
                    .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.86), value: page)
                    // Simultaneous, not exclusive. A plain `.gesture` here would
                    // win over the feed's vertical one for every touch that
                    // began on a photo — which is most of the card — and the
                    // feed would stop scrolling.
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 8)
                            .onChanged { value in
                                guard abs(value.translation.width) > abs(value.translation.height)
                                else { return }
                                dragX = value.translation.width
                            }
                            .onEnded { value in
                                dragX = 0
                                guard abs(value.translation.width) > abs(value.translation.height)
                                else { return }
                                let last = profile.photoSeeds.count - 1
                                if value.translation.width < -width * 0.22 {
                                    page = min(last, page + 1)
                                } else if value.translation.width > width * 0.22 {
                                    page = max(0, page - 1)
                                }
                            }
                    )
                }
            }
            .clipped()
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
