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
        VStack(spacing: 0) {
            ForEach(Array(model.profiles.enumerated()), id: \.element.id) { index, profile in
                DiscoveryCard(profile: profile)
                    .frame(width: size.width, height: size.height)
                    .onAppear {
                        // Extend well before the reader arrives, so the feed
                        // never shows its own edge.
                        if index >= model.profiles.count - 3 { model.extend() }
                    }
            }
        }
        .frame(width: size.width, alignment: .top)
        .offset(y: -CGFloat(model.index) * size.height + model.drag)
        .animation(.interactiveSpring(response: 0.32, dampingFraction: 0.86), value: model.index)
        .gesture(
            DragGesture(coordinateSpace: .global)
                .onChanged { model.drag = $0.translation.height }
                .onEnded { value in
                    model.drag = 0
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
    func extend() {
        guard var feed else { return }
        profiles += feed.next(6)
        self.feed = feed
    }

    func advance(by delta: Int) {
        index = max(0, min(profiles.count - 1, index + delta))
    }
}

/// One person's card: two pictures and up to two lines.
struct DiscoveryCard: View {
    let profile: DiscoveryFeed.Profile

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)

            // Two photographs, the second peeled back behind the first, so a
            // card reads as more than one picture without asking for a second
            // gesture to see it.
            ZStack(alignment: .topLeading) {
                ForEach(Array(profile.photoSeeds.enumerated().reversed()), id: \.offset) { i, seed in
                    PortraitView(seed: seed, initial: profile.name)
                        .aspectRatio(ExampleProfileCard.photoAspect, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 24))
                        .rotationEffect(.degrees(i == 0 ? 0 : 4), anchor: .bottomLeading)
                        .offset(x: CGFloat(i) * 14, y: CGFloat(-i) * 12)
                        .shadow(color: .black.opacity(i == 0 ? 0.12 : 0.06), radius: 12, y: 6)
                        .zIndex(i == 0 ? 1 : 0)
                }
            }
            .padding(.trailing, 18)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(profile.name)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(GardenPalette.ink)
                    if let age = profile.age {
                        Text("\(age)")
                            .font(.system(size: 20))
                            .foregroundStyle(GardenPalette.muted)
                    }
                }
                if let district = profile.district {
                    Text(district)
                        .font(.system(size: 14))
                        .foregroundStyle(GardenPalette.muted)
                }
                ForEach(Array(profile.lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 15))
                        .foregroundStyle(GardenPalette.softInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 18)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        // Clear of the tab bar, which floats over every page.
        .padding(.bottom, MainTabBar.overlayHeight)
    }
}
