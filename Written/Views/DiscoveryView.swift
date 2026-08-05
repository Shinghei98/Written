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
    /// Only for the ban list. The feed is its own model; this is the one thing
    /// it needs that lives elsewhere, and it lives elsewhere because a block is
    /// pushed and restored with everything else the user has struck off.
    @ObservedObject var viewModel: DistillViewModel

    @StateObject private var model = DiscoveryModel()
    /// Nothing sets this while sharing is switched off. Kept declared rather than
    /// commented out with its two call sites, because `shareButton` below reads
    /// it — removing it would mean commenting that out too, and the point of
    /// leaving both intact is that restoring the feature is uncommenting call
    /// sites rather than reassembling views.
    @State private var isSharing = false

    /// Which shared video is nearest the middle of the screen, and so the one
    /// that plays. Nil when none is close enough to count.
    ///
    /// One at a time, deliberately: several players running at once is several
    /// video decoders and, the moment anything is unmuted, several sound
    /// sources. It is also what Instagram does, and for the same reason.
    @State private var activeShare: String?

    /// Whether the feed's sound is on. One switch for all of it — see
    /// `SharedPostCard.isMuted`.
    ///
    /// Not remembered between launches, deliberately: opening an app to
    /// unexpected sound is worse than tapping once to ask for it.
    @State private var isFeedMuted = true
    /// The profile whose ellipsis was tapped, if any.
    @State private var pendingActions: DiscoveryFeed.Profile?
    /// The profile being reported. Separate from the above so the two sheets
    /// never both draw — the actions sheet clears itself as it hands over.
    @State private var pendingReport: DiscoveryFeed.Profile?
    /// The profile being written to with a like.
    @State private var pendingInvite: DiscoveryFeed.Profile?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                GardenPalette.parchment.ignoresSafeArea()

                if model.items.isEmpty {
                    empty
                } else {
                    feed(
                        width: geometry.size.width,
                        viewportCentre: geometry.frame(in: .global).midY
                    )
                }

                // Sharing a video is switched off; see `DiscoveryModel.load`.
                // The button goes with it rather than being left to open a sheet
                // whose result the feed would no longer show.
//                shareButton
            }
            // Drawn whether or not the feed is empty. It used to live only
            // inside the empty state, so with cards on screen a refused like
            // recorded its reason somewhere nobody could see — the heart simply
            // emptied again.
            .statusBanner(model.failure)
            // Centred on the screen, and layered here rather than on the card
            // for that reason — see `DiscoveryCard.onMore`.
            .overlay {
                if let profile = pendingActions {
                    ProfileActionsSheet(
                        name: profile.name,
                        onRemove: {
                            model.remove(profile.personID)
                            pendingActions = nil
                        },
                        // **The same sheet the chat thread raises**, so being
                        // reported means one thing in this app rather than two.
                        // Straight there, with no second confirmation: the
                        // sheet itself is the confirmation, and it has a cancel.
                        onReport: {
                            pendingReport = profile
                            pendingActions = nil
                        },
                        onCancel: { pendingActions = nil }
                    )
                }

                if let profile = pendingInvite {
                    LikeMessageSheet(
                        name: profile.name,
                        onSend: { note in
                            model.like(profile.personID, message: note)
                            pendingInvite = nil
                        },
                        onCancel: { pendingInvite = nil }
                    )
                }

                if let profile = pendingReport {
                    ReportSheet(
                        name: profile.name,
                        onSend: { text in
                            let id = profile.personID
                            let name = profile.name
                            // **Blocked here, not on the server's answer**, and
                            // the reasoning is `ChatView`'s: the report is worth
                            // retrying, getting away from somebody is not
                            // something to make conditional on a network.
                            viewModel.banPerson(id)
                            pendingReport = nil
                            Task {
                                _ = await ChatService.shared.report(id, named: name, body: text)
                            }
                        },
                        onCancel: { pendingReport = nil }
                    )
                }
            }
//            .overlay {
//                if isSharing {
//                    ShareLinkSheet(
//                        onShared: { post in
//                            // Straight to the top rather than waiting for a
//                            // reload to find it. Sharing something and not
//                            // seeing it reads as a failure.
//                            model.prepend(post)
//                            isSharing = false
//                        },
//                        onCancel: { isSharing = false }
//                    )
//                }
//            }
        }
        .preferredColorScheme(.light)
        .task {
            // Two sources of "never show me this person": a report or unmatch,
            // which lives in `bans`, and a plain removal, which has its own
            // table. Unioned here so the feed has one exclusion set — and read
            // before the cards, so nobody removed is ever drawn and then taken
            // away. See `0017_remove_list.sql` for why they are separate.
            let removed = await RemoveListService.shared.removed()
            await model.load(hiding: viewModel.bans.keys(.person).union(removed))
        }
        // Somebody unmatched from the Chat tab while this feed was already
        // built. `load` will not run again — it guards on `items.isEmpty` — so
        // the purge has to be driven by the ban itself.
        .onChange(of: viewModel.bans) { list in model.hide(list.keys(.person)) }
    }

    private func feed(width: CGFloat, viewportCentre: CGFloat) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 14) {
                ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                    Group {
                        switch item {
                        case .profile(let profile):
                            DiscoveryCard(
                                profile: profile,
                                containerWidth: width,
                                // Keyed by person, not by card. The same person
                                // returns every few items with different photos,
                                // and a heart that emptied on the way past would
                                // read as the like having been dropped.
                                isLiked: model.hasLiked(profile.personID),
                                onLike: { model.like(profile.personID) },
                                onMessage: { pendingInvite = profile },
                                onMore: { pendingActions = profile }
                            )
                        case .shared(let post, _):
                            SharedPostCard(
                                post: post,
                                containerWidth: width,
                                isActive: activeShare == post.id,
                                isMuted: $isFeedMuted
                            )
                            // Reports where it is, so the feed can work out
                            // which one is centred. Only the shared cards do
                            // this — a profile has nothing to start or stop, and
                            // measuring them all would be several times the
                            // preference traffic for nothing.
                            .background(
                                GeometryReader { card in
                                    Color.clear.preference(
                                        key: CardCentresKey.self,
                                        value: [post.id: card.frame(in: .global).midY]
                                    )
                                }
                            )
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
        .onPreferenceChange(CardCentresKey.self) { centres in
            // The nearest to the middle, and only if it is genuinely near it. A
            // plain "closest" would keep the last video playing while it sat off
            // the top of the screen, because it would still be the closest of
            // the ones being measured.
            let nearest = centres
                .filter { abs($0.value - viewportCentre) < Self.playbackReach }
                .min { abs($0.value - viewportCentre) < abs($1.value - viewportCentre) }
            if activeShare != nearest?.key { activeShare = nearest?.key }
        }
    }

    /// How far from the middle a card can be and still be the one playing.
    ///
    /// Generous enough that scrolling between two videos does not leave a gap
    /// with neither running, tight enough that one off the edge of the screen
    /// stops.
    private static let playbackReach: CGFloat = 260

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
            // Just the neutral line now — the banner above carries any failure,
            // and printing it in both places says it twice.
            Text("Profiles will appear here as people join.")
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

    /// Who this account has liked, by person id.
    ///
    /// Read from the server on load rather than kept only here: the feed draws a
    /// filled heart from it, and a relaunch that forgot would show every liked
    /// card as untouched.
    @Published private(set) var liked: Set<String> = []

    /// Who this account has blocked, by person id, lowercased.
    ///
    /// Kept beside `liked` and filtered in the same three places, because the
    /// two rules differ only in when they apply: a like leaves the feed on the
    /// next scroll, deliberately, so the heart can be seen filling. A block
    /// leaves at once — there is no feedback to preserve and the whole point is
    /// not seeing them.
    private var banned: Set<String> = []

    private var feed: DiscoveryFeed?

    func hasLiked(_ personID: String) -> Bool { liked.contains(personID) }

    /// Like-only, and idempotent — there is no unlike. The row's primary key is
    /// the pair, so a second tap rewrites what is already there, and nothing in
    /// this schema is ever deleted.
    /// Likes somebody, with an optional note.
    ///
    /// **A note is not blocked by having already liked**, unlike a second bare
    /// heart. Hearting somebody and then finding something to say is an ordinary
    /// sequence, and `LikeService.attachMessage` is the path `0018`'s column
    /// grant was widened to allow — without it the second write is swallowed by
    /// `ignore-duplicates` and reports success.
    func like(_ personID: String, message: String? = nil) {
        let note = message?.trimmingCharacters(in: .whitespacesAndNewlines)
        if liked.contains(personID) {
            guard let note, !note.isEmpty else { return }
            Task {
                guard await LikeService.shared.attachMessage(note, to: personID) == false else { return }
                failure = await LikeService.shared.lastError
            }
            return
        }
        // Shown immediately, taken back if the write fails. A heart that waits
        // for a round trip feels broken at exactly the moment it matters.
        liked.insert(personID)

        // **`items` is deliberately not touched here.** Pulling this person's
        // cards out on the tap took the post out from under the reader's thumb
        // and hid the one piece of feedback the gesture has — a heart they never
        // got to see fill. They leave on the next scroll instead; see `extend`.
        //
        // It also makes the failure path below honest again: nothing was
        // removed, so nothing has to be put back.

        Task {
            let landed = await LikeService.shared.like(personID: personID, message: note)
            guard !landed else { return }
            liked.remove(personID)
            // **Say why.** Reverting the heart on its own is the app taking
            // something back without explaining, which reads as the tap not
            // having registered rather than as a failure. Offline gets its own
            // wording because "not signed in" — what the request layer reports
            // when it cannot get a token — is actively misleading on a plane.
            if !Reachability.shared.isOnline {
                failure = "You're offline — that like didn't save."
            } else {
                failure = await LikeService.shared.lastError ?? "That like didn't save."
            }
            await clearFailureShortly()
        }
    }

    /// Takes the message away again after a moment.
    ///
    /// A banner about one tap that stays until the next launch stops being
    /// information and becomes furniture. The offline banner in `AppShell` is
    /// the opposite case and correctly persists — it describes a condition
    /// rather than an event.
    private func clearFailureShortly() async {
        let shown = failure
        try? await Task.sleep(for: .seconds(4))
        // Only if nothing newer replaced it in the meantime.
        if failure == shown { failure = nil }
    }

    func load(hiding blocked: Set<String> = []) async {
        banned = blocked
        guard items.isEmpty else { return }
        // SHARED VIDEOS ARE SWITCHED OFF. The query goes with the display rather
        // than being left running: fetching rows for a feed that cannot show
        // them is a round trip on every launch buying nothing.
        //
        // Both at once, and it was three: the likes decide what is already
        // filled in on first draw, and waiting for them serially would show a
        // feed that then reshuffled itself.
        async let peopleTask = DiscoveryService.shared.people()
//        async let postsTask = SharedPostService.shared.posts()
        async let likedTask = LikeService.shared.likedPersonIDs()
        let people = await peopleTask
        liked = await likedTask

        guard !people.isEmpty else {
            failure = await DiscoveryService.shared.lastError
            return
        }

        // **Two different kinds of empty, and only one of them is a problem.**
        // No rows at all is handled above and reports whatever went wrong. Rows
        // that are all people you have already liked is not a fault — it is
        // having got to the end — so it must leave `failure` nil and let the
        // empty state say so, rather than complaining about a network that
        // worked perfectly.
        let unliked = people.filter { !liked.contains($0.id) && !banned.contains($0.id.lowercased()) }
        guard !unliked.isEmpty else {
            items = []
            failure = nil
            return
        }
        // The whole switch is this one omitted argument. `posts:` defaults to
        // empty and `DiscoveryFeed.nextItem` emits a `.shared` case only when it
        // is non-empty, so nothing downstream needs touching — restoring the
        // feature is putting `posts: posts` back.
        var feed = DiscoveryFeed(people: unliked)
//        var feed = DiscoveryFeed(people: unliked, posts: posts)
        items = feed.nextItems(12)
        self.feed = feed
        failure = nil
    }

    /// Applies a block to a feed that is already on screen.
    ///
    /// Unlike the like purge this takes items *above* the viewport too, which
    /// moves what is being read — accepted, because the alternative is leaving
    /// somebody just blocked one scroll away.
    /// Takes somebody out of the stack for good, with no accusation.
    ///
    /// **Immediately, unlike a like.** A like defers its removal to the next
    /// scroll so the heart is seen to fill; this is the opposite — somebody who
    /// asked for a profile to be gone should not have to scroll to watch it go.
    ///
    /// Applied before the write and not rolled back if it fails. The row is
    /// worth retrying; being shown again somebody you just removed is not
    /// something to make conditional on a network, and the next launch re-reads
    /// the list either way.
    func remove(_ personID: String) {
        banned.insert(personID)
        items.removeAll(where: isBannedProfile)
        Task {
            guard await RemoveListService.shared.remove(personID) == false else { return }
            failure = await RemoveListService.shared.lastError
        }
    }

    func hide(_ blocked: Set<String>) {
        guard blocked != banned else { return }
        banned = blocked
        items.removeAll(where: isBannedProfile)
    }

    /// Puts a just-shared video at the top, rather than waiting for a reload to
    /// discover it. Sharing something and not seeing it reads as a failure.
    func prepend(_ post: SharedPostService.Post) {
        // Appearance 0: nothing the feed generates uses it, so a freshly shared
        // post cannot collide with the same post arriving in the rotation later.
        items.insert(.shared(post, appearance: 0), at: 0)
    }

    /// Grows the feed as the reader nears its end. The rotation rules already
    /// make it endless; the list only has to keep up.
    func extend(reaching index: Int) {
        // **The purge runs on every row, above the near-the-end guard.** A row
        // appearing is the only scroll signal this view has, and "they go on the
        // next scroll" needs all of them, not just the last three.
        //
        // Strictly *after* `index`, which is the whole of the care here.
        // Removing an item above the viewport shifts everything below it upward
        // and moves what is being read mid-scroll. So the card just liked stays
        // where it is — scroll back and it is still there, heart filled — and
        // what goes is every appearance still ahead.
        if items.count > index + 1 {
            let ahead = items[(index + 1)...]
            if ahead.contains(where: isLikedProfile) {
                items = Array(items[...index]) + ahead.filter { !isLikedProfile($0) }
            }
        }

        guard var feed, index >= items.count - 3 else { return }

        // The rotation still holds everyone it was built with — `people` is
        // `let`, and rebuilding it here would reshuffle the whole feed under
        // somebody mid-scroll. Filtering its *output* costs nothing and leaves
        // the rotation's spacing rule intact.
        //
        // **Bounded.** Asking until six survive would spin forever once
        // everything left in the rotation has been liked, which is reachable:
        // there are six synthetic accounts. A fixed number of attempts means the
        // list simply stops growing instead, which is the truth.
        var fresh: [DiscoveryFeed.Item] = []
        for _ in 0..<4 {
            fresh += feed.nextItems(6).filter { !isLikedProfile($0) && !isBannedProfile($0) }
            if fresh.count >= 6 { break }
        }
        items += fresh
        self.feed = feed
    }

    private func isLikedProfile(_ item: DiscoveryFeed.Item) -> Bool {
        guard case .profile(let profile) = item else { return false }
        return liked.contains(profile.personID)
    }

    private func isBannedProfile(_ item: DiscoveryFeed.Item) -> Bool {
        guard case .profile(let profile) = item else { return false }
        return banned.contains(profile.personID.lowercased())
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

    var isLiked = false
    var onLike: () -> Void = {}
    /// Like this person with something written, rather than with a heart alone.
    var onMessage: () -> Void = {}

    /// Raise the two-row sheet for this person.
    ///
    /// **Reported upward rather than presented here.** The sheet is centred on
    /// the *screen*; an overlay attached to this card would centre on the card
    /// and be clipped by its corner radius. `ChatView` puts its report sheet at
    /// the top level for the same reason.
    var onMore: () -> Void = {}

    @State private var page = 0

    /// The big heart that flashes over the photo on a double tap.
    ///
    /// Not decoration. The heart that records the like is below the fold of the
    /// photo, so without this a double tap in the middle of a picture has no
    /// feedback where the finger actually was, and reads as not having registered.
    @State private var isFlashing = false

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
            ProfilePhotoView(ref: profile.photos.first, initial: profile.name)
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

            // **A button at last.** This drew an ellipsis and did nothing —
            // the universal "there are more options here" glyph, on a card whose
            // only other control is a heart. Somebody who wanted away from a
            // profile had nowhere to go.
            Button(action: onMore) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(GardenPalette.muted)
                    // The glyph is three small dots and the tap target must not
                    // be: 44 square is the smallest thing a thumb finds reliably.
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("More options for \(profile.name)")
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
            ForEach(Array(profile.photos.enumerated()), id: \.offset) { index, ref in
                ProfilePhotoView(ref: ref, initial: profile.name)
                    .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(height: photoHeight)
        .overlay(alignment: .bottom) { dots }
        .overlay { flash }
        // A tap count, and deliberately no `DragGesture` of any kind. The pager
        // underneath is a UIKit paging scroll view and the feed above is another
        // one; the header comment on this file describes three rounds of
        // arbitrating hand-rolled drags between them, and a tap needs none of it.
        .onTapGesture(count: 2) { likeFromPhoto() }
        .accessibilityAction(named: "Like") { likeFromPhoto() }
    }

    private func likeFromPhoto() {
        onLike()
        // Plays even when the person was already liked. The gesture happened, and
        // silence would read as the tap having missed.
        isFlashing = true
        withAnimation(.easeOut(duration: 0.55)) { isFlashing = false }
    }

    @ViewBuilder
    private var flash: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: 86))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.25), radius: 12)
            // Scale and opacity both driven off the one flag, so there is a single
            // animation to cancel if a second double tap arrives mid-flight.
            .scaleEffect(isFlashing ? 1 : 1.35)
            .opacity(isFlashing ? 0.95 : 0)
            .allowsHitTesting(false)
    }

    /// Which of the two you are on. Drawn over the photo rather than under it,
    /// so the card's height does not change as the count does.
    @ViewBuilder
    private var dots: some View {
        if profile.photos.count > 1 {
            HStack(spacing: 5) {
                ForEach(0..<profile.photos.count, id: \.self) { index in
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

    /// The heart is the only one of these that does anything.
    ///
    /// The other three stayed decorative when it went live, and that is a choice
    /// rather than an omission: they are furniture borrowed from the post format
    /// so a stranger's card reads as somebody's words. Wiring one of them up
    /// without somewhere for it to go would be worse than leaving it inert.
    /// They keep `allowsHitTesting(false)` and stay out of VoiceOver; the heart
    /// has neither.
    private var actionRow: some View {
        HStack(spacing: 16) {
            Button(action: likeFromPhoto) {
                Image(systemName: isLiked ? "heart.fill" : "heart")
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(isLiked ? GardenPalette.heart : GardenPalette.ink.opacity(0.75))
                    // A short squeeze on the way in. Symbol-only, so it costs
                    // nothing when the card is rebuilt already liked.
                    .scaleEffect(isLiked ? 1.08 : 1)
                    .animation(.spring(response: 0.3, dampingFraction: 0.55), value: isLiked)
                    // The glyph is 19 points; the target is not.
                    .frame(width: 30, height: 30, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isLiked ? "Liked \(profile.name)" : "Like \(profile.name)")

            // **Out of the decorative group, because this one does something
            // now.** The paperplane and the bookmark stay in it: they are not
            // part of this and must not start looking pressable by accident.
            Button(action: onMessage) {
                Image(systemName: "bubble.right")
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(GardenPalette.ink.opacity(0.75))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Send \(profile.name) a message with your like")

            Group {
                Image(systemName: "paperplane")
                Spacer(minLength: 0)
                Image(systemName: "bookmark")
            }
            .font(.system(size: 19, weight: .regular))
            .foregroundStyle(GardenPalette.ink.opacity(0.75))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
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


/// Where each shared card sits, so the feed can tell which one is centred.
///
/// Keyed by post id rather than by index: the list grows as the reader goes on,
/// and an index would point at a different card after every extension.
struct CardCentresKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}
