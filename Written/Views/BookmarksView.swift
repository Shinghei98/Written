import SwiftUI

/// The profiles this account has saved, drawn exactly as Explore draws them.
///
/// **`DiscoveryCard` verbatim, and a feed built the same way**, because a saved
/// profile is the same object as an unsaved one and two card layouts would drift
/// the moment either was touched. What differs is upstream of the card: the
/// people come from `bookmarks` rather than from everybody, and the feed emits
/// **one round** rather than cycling forever.
///
/// That last part is the one deliberate departure from Explore. The rotation
/// exists because discovery is endless and a person has to be able to come round
/// again with different photographs; a bookmarks list is finite and somebody
/// scrolling it is looking for a particular person, so repeating them would make
/// a list of four read as a list of forty.
struct BookmarksView: View {

    @ObservedObject var viewModel: DistillViewModel
    var onClose: () -> Void = {}

    @StateObject private var model = BookmarksModel()

    /// The profile whose ellipsis was tapped, and the one being reported.
    /// Separate, so the two sheets never both draw.
    @State private var pendingActions: DiscoveryFeed.Profile?
    @State private var pendingReport: DiscoveryFeed.Profile?
    @State private var pendingInvite: DiscoveryFeed.Profile?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                GardenPalette.parchment.ignoresSafeArea()

                Group {
                    if model.isLoading {
                        ProgressView().tint(GardenPalette.muted)
                    } else if model.items.isEmpty {
                        empty
                    } else {
                        feed(width: geometry.size.width)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                header
            }
            .statusBanner(model.failure)
            .overlay {
                if let profile = pendingActions {
                    ProfileActionsSheet(
                        name: profile.name,
                        onRemove: {
                            model.remove(profile.personID)
                            pendingActions = nil
                        },
                        onReport: {
                            pendingActions = nil
                            pendingReport = profile
                        },
                        onCancel: { pendingActions = nil }
                    )
                }
            }
            .overlay {
                if let profile = pendingReport {
                    ReportSheet(
                        name: profile.name,
                        onSend: { text in
                            let id = profile.personID
                            let name = profile.name
                            // Blocked here rather than on the server's answer,
                            // the same trade `DiscoveryView` and `ChatView`
                            // make: the report is worth retrying, getting away
                            // from somebody is not something to make
                            // conditional on a network.
                            viewModel.banPerson(id)
                            model.drop(id)
                            pendingReport = nil
                            Task {
                                _ = await ChatService.shared.report(id, named: name, body: text)
                            }
                        },
                        onCancel: { pendingReport = nil }
                    )
                }
            }
            .overlay {
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
            }
        }
        .preferredColorScheme(.light)
        .task { await model.load(hiding: viewModel.bans.keys(.person)) }
    }

    /// Pinned, unlike Explore's — this page is somewhere you arrived from
    /// somewhere else, so the way back has to stay on screen rather than
    /// scrolling away with the first card.
    private var header: some View {
        HStack(spacing: 12) {
            Button(action: onClose) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(GardenPalette.ink)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")

            Text("Bookmarks")
                .font(BrandFont.title(22))
                .foregroundStyle(GardenPalette.ink)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .background(GardenPalette.parchment.opacity(0.96))
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "bookmark")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(GardenPalette.muted.opacity(0.7))

            Text(model.couldNotReach ? "Couldn't reach your bookmarks." : "Nothing saved yet.")
                .font(BrandFont.title(22))
                .foregroundStyle(GardenPalette.ink)

            // **Two sentences, not one.** "Nothing saved yet" is a claim about
            // this account; offline, the app cannot make it. The same split
            // `ChatView` draws for an unreachable conversation list.
            Text(model.couldNotReach
                 ? "Check your connection and try again."
                 : "Tap the bookmark on anyone in Explore to keep them here.")
                .font(.system(size: 15))
                .foregroundStyle(GardenPalette.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 42)
        }
    }

    private func feed(width: CGFloat) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 14) {
                ForEach(model.items) { profile in
                    DiscoveryCard(
                        profile: profile,
                        containerWidth: width,
                        isLiked: model.hasLiked(profile.personID),
                        isMessaged: model.hasMessaged(profile.personID),
                        onLike: { model.like(profile.personID) },
                        onMessage: { pendingInvite = profile },
                        // Always true here — this is the list of saved people —
                        // and tapping it takes them out from under the reader.
                        // That is the right behaviour on *this* page, unlike in
                        // Explore, where a like deliberately waits for the next
                        // scroll: there the card is the feedback, and here the
                        // card leaving *is* the feedback.
                        isBookmarked: true,
                        onBookmark: { model.unbookmark(profile.personID) },
                        onMore: { pendingActions = profile }
                    )
                }
            }
            .padding(.top, 56)
            .padding(.bottom, 24)
        }
    }
}

/// The bookmarks page's data.
///
/// Deliberately **not** `DiscoveryModel` with a flag. That model carries the
/// rotation, the top-up-on-scroll, the separation rule and the like-purge, none
/// of which apply to a finite saved list, and a boolean threaded through all of
/// them would make both behaviours harder to reason about than two small models.
@MainActor
final class BookmarksModel: ObservableObject {

    @Published private(set) var items: [DiscoveryFeed.Profile] = []
    @Published private(set) var failure: String?
    @Published private(set) var isLoading = true
    /// Whether the last load failed rather than came back empty — the two draw
    /// different empty states.
    @Published private(set) var couldNotReach = false

    @Published private(set) var liked: Set<String> = []
    @Published private(set) var messaged: Set<String> = []

    func hasLiked(_ personID: String) -> Bool { liked.contains(personID) }
    func hasMessaged(_ personID: String) -> Bool { messaged.contains(personID) }

    func load(hiding blocked: Set<String> = []) async {
        isLoading = true
        defer { isLoading = false }

        async let peopleTask = BookmarkService.shared.bookmarked()
        async let likedTask = LikeService.shared.invitations()

        let invitations = await likedTask
        liked = invitations.liked
        messaged = invitations.withNote

        // `nil` is *could not ask*, `[]` is *nothing saved*. Conflating them is
        // how an offline page tells somebody their bookmarks are gone.
        guard let people = await peopleTask else {
            couldNotReach = true
            failure = nil
            items = []
            return
        }
        couldNotReach = false

        let visible = people.filter { !blocked.contains($0.id.lowercased()) }
        guard !visible.isEmpty else {
            items = []
            return
        }

        // **One round, one card each** — see the note on the view. Built through
        // `DiscoveryFeed` rather than by hand so the photograph and line
        // selection are the same code Explore uses, then stopped after every
        // person has appeared once.
        var feed = DiscoveryFeed(people: visible)
        items = feed.nextItems(visible.count).compactMap {
            if case .profile(let profile) = $0 { return profile }
            return nil
        }
    }

    func like(_ personID: String, message: String? = nil) {
        let note = message?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !liked.contains(personID) else { return }
        liked.insert(personID)
        if note?.isEmpty == false { messaged.insert(personID) }

        Task { @MainActor in
            guard await LikeService.shared.like(personID: personID, message: note) == false else { return }
            liked.remove(personID)
            messaged.remove(personID)
            if await LikeService.shared.lastFailureWasMissingPerson {
                drop(personID)
                failure = "That profile is no longer available."
                return
            }
            failure = await LikeService.shared.lastError ?? "That like didn't save."
        }
    }

    /// Takes somebody out of the list, and out of `bookmarks`.
    func unbookmark(_ personID: String) {
        let removed = items.filter { $0.personID == personID }
        drop(personID)

        Task { @MainActor in
            guard await BookmarkService.shared.remove(personID) == false else { return }
            // Put them back where they were rather than at the end: this page
            // is a list somebody arranged by saving things, and a failed
            // un-save that reordered it would be a second surprise on top of
            // the first.
            items.append(contentsOf: removed)
            failure = await BookmarkService.shared.lastError ?? "That didn't save."
        }
    }

    /// Blocked or reported from the actions sheet — gone from here, and pushed
    /// to the remove list like Explore's.
    func remove(_ personID: String) {
        drop(personID)
        Task { @MainActor in
            guard await RemoveListService.shared.remove(personID) == false else { return }
            failure = await RemoveListService.shared.lastError
        }
    }

    /// Off this page only. The row in `bookmarks` is untouched, because the
    /// three callers that use it — a like on somebody since deleted, a report,
    /// a block — are all reasons to stop *drawing* a person rather than reasons
    /// to unpick a list the user curated.
    func drop(_ personID: String) {
        items.removeAll { $0.personID == personID }
    }
}
