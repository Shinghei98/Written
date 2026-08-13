import SwiftUI

/// The dynamic profile — how somebody presents themselves to a match.
///
/// Laid out like an Instagram account, which is the reference: a circular
/// photograph on the left, the name beside it, and three figures where posts,
/// followers and following sit. Those three are the difference. A follower count
/// is a claim about how many people know you; these are what somebody's
/// attention is actually made of, and there is nothing to inflate.
///
/// **Reachable from exactly two places** — the avatar on an invitation and the
/// avatar on a chatroom banner — and that rule is enforced in Postgres rather
/// than by which buttons exist. `match_profile()` returns nothing to anybody
/// without a like or a conversation, so the school and the bio cannot be
/// reached by guessing a URL or by a future screen forgetting the rule.
struct MatchProfileView: View {

    let personID: String
    /// Drawn immediately from what the caller already has, so the page has a
    /// face and a name before the fetch lands. Everything else waits.
    let fallbackName: String
    let fallbackPhoto: DiscoveryFeed.PhotoRef
    @ObservedObject var viewModel: DistillViewModel
    var onClose: () -> Void = {}

    @State private var profile: MatchProfileService.Profile?
    @State private var isLoading = true
    @State private var failure: String?
    /// Which photograph is open full-screen, by position.
    @State private var openPhoto: Int?
    /// Saved for later, privately — the person bookmarked is never told, never
    /// notified, and cannot read the row. See `0035`.
    @State private var isBookmarked = false
    @State private var isReporting = false
    /// **The ellipsis used to *be* Report**, which left somebody who simply
    /// wanted away from a match with only an accusation to make. It raises the
    /// same three choices Explore does now, and Report is one of them rather
    /// than all of them.
    @State private var isChoosing = false

    var body: some View {
        ZStack(alignment: .top) {
            GardenPalette.parchment.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    heading
                    biographics
                    grid
                }
                .padding(.top, 52)
                .padding(.bottom, 32)
            }

            header
        }
        .preferredColorScheme(.light)
        .statusBanner(failure)
        .overlay {
            // **The whole run, not the one tile.** Tapping a photograph used to
            // open that photograph alone, which made the grid a set of six dead
            // ends; this opens the person's posts and lands on the one tapped,
            // so the others are a scroll away rather than a second tap and a
            // dismissal. What each of those posts *is* is `DiscoveryCard`, so a
            // person's photographs look the same wherever you meet them — see
            // `MatchPostsView`.
            if let openPhoto, let profile, openPhoto < profile.photoPaths.count {
                MatchPostsView(
                    personID: personID,
                    name: profile.name,
                    age: profile.age,
                    district: profile.district,
                    paths: profile.photoPaths,
                    captions: profile.captions,
                    opening: openPhoto,
                    isBookmarked: isBookmarked,
                    onBookmark: toggleBookmark,
                    onMore: { isChoosing = true },
                    onClose: { self.openPhoto = nil }
                )
                .transition(.move(edge: .trailing))
            }

            // **At the top level, not inside the card**, for the reason
            // `DiscoveryCard.onMore` records: the sheet is centred on the
            // *screen*, and an overlay attached to a card centres on the card
            // and is clipped by its corner radius.
            // **Unmatch and Report, and blocking is deliberately not here.**
            // A block can be lifted and an unmatch cannot, so they belong on
            // different surfaces: the one you can undo lives in the block list,
            // where you can see what you have done, and the one you cannot lives
            // in the moment. Offering both side by side would put two
            // similar-sounding choices next to each other where only one is
            // reversible, and the irreversible one is the shorter word.
            if isChoosing {
                ProfileActionsSheet(
                    name: profile?.name ?? fallbackName,
                    // **"Unmatch", not "Remove".** Underneath it is the same
                    // local ban `banPerson` applies everywhere, but a match is
                    // something you leave rather than a card you take off a
                    // pile, and the word is the only thing that says so.
                    removeTitle: "Unmatch",
                    onRemove: {
                        viewModel.banPerson(personID)
                        isChoosing = false
                        onClose()
                    },
                    onReport: {
                        isChoosing = false
                        isReporting = true
                    },
                    onCancel: { isChoosing = false }
                )
            }

            if isReporting {
                ReportSheet(
                    name: profile?.name ?? fallbackName,
                    onSend: { text in
                        let name = profile?.name ?? fallbackName
                        // **Blocked here, not on the server's answer**, exactly
                        // as Explore and Chat do it: the report is worth
                        // retrying, getting away from somebody is not something
                        // to make conditional on a network.
                        viewModel.banPerson(personID)
                        isReporting = false
                        Task {
                            _ = await ChatService.shared.report(personID, named: name, body: text)
                        }
                    },
                    onCancel: { isReporting = false }
                )
            }
        }
        .task { await load() }
        .task { await loadBookmark() }
    }

    /// **Left alone when `bookmarkedIDs()` answers nil**, which means *could not
    /// ask* rather than *nothing saved*. Assigning an empty set on a dropped
    /// request would draw a saved person as unsaved, and the tap that followed
    /// would save them a second time.
    private func loadBookmark() async {
        guard let saved = await BookmarkService.shared.bookmarkedIDs() else { return }
        isBookmarked = saved.contains(personID)
    }

    /// Optimistic, and put back if the write is refused — the same shape the
    /// feed's bookmark takes. Nothing was removed from view, so a revert has
    /// nothing to restore beyond the glyph.
    private func toggleBookmark() {
        let wanted = !isBookmarked
        isBookmarked = wanted
        Task {
            let ok = wanted
                ? await BookmarkService.shared.add(personID)
                : await BookmarkService.shared.remove(personID)
            if !ok { isBookmarked = !wanted }
        }
    }

    private func load() async {
#if DEBUG
        // `-chat profile`. Returns before any query, so the page can be looked
        // at with `0037` unapplied and nobody signed in — and, more to the
        // point, with *both* sides present. A real account on this developer's
        // phone has nobody to be matched with.
        if DebugLaunch.chatTarget == "profile" {
            profile = .sample
            isLoading = false
            return
        }
#endif
        let fetched = await MatchProfileService.shared.profile(
            for: personID,
            viewer: viewModel.viewerForMatching()
        )
        profile = fetched
        isLoading = false
        // Only a real failure. No card at all is an ordinary answer — somebody
        // with no photographs is never published — and reads as the sparse page
        // below rather than as something having gone wrong.
        if fetched == nil { failure = await MatchProfileService.shared.lastError }
    }

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

            Text(profile?.name ?? fallbackName)
                .font(BrandFont.title(20))
                .foregroundStyle(GardenPalette.ink)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .background(GardenPalette.parchment.opacity(0.96))
    }

    /// Avatar, name, and the three domain figures.
    private var heading: some View {
        HStack(alignment: .center, spacing: 18) {
            ProfilePhotoView(
                ref: profile.map { photoRef(for: $0) } ?? fallbackPhoto,
                initial: profile?.name ?? fallbackName
            )
            // 22% of the width, matching the reference's proportion rather than
            // a fixed size — the avatar has to hold its share on an SE and a
            // Pro Max alike.
            .frame(width: Self.avatarSide, height: Self.avatarSide)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 10) {
                Text(profile?.name ?? fallbackName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(GardenPalette.ink)
                    .tracking(1.5)
                    .textCase(.uppercase)

                // **Three columns where posts / followers / following sit, and
                // they name things rather than categories.** "Music 83%" is a
                // shape anybody could infer from the artist names beside it;
                // "Bach 22%" is what this page exists to show, and unlike a
                // follower count there is nothing to inflate.
                //
                // Fewer than three when somebody has fewer, which is the honest
                // shape — padding it out would invent breadth.
                HStack(alignment: .top, spacing: 0) {
                    ForEach(profile?.topSubjects ?? [], id: \.subject) { weight in
                        VStack(spacing: 2) {
                            Text("\(weight.percent)%")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(GardenPalette.ink)
                            // A performer's name runs long — "English Baroque
                            // Soloists, Monteverdi Choir & John Eliot Gardiner"
                            // is 62 characters against a column a third of the
                            // width — so two lines and a floor on the scale,
                            // rather than one line truncated to nothing.
                            Text(weight.subject)
                                .font(.system(size: 12))
                                .foregroundStyle(GardenPalette.muted)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .minimumScaleFactor(0.7)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private static let avatarSide: CGFloat = 86

    private func photoRef(for profile: MatchProfileService.Profile) -> DiscoveryFeed.PhotoRef {
        profile.photoPaths.first.map { .stored($0) } ?? fallbackPhoto
    }

    /// `age | school | district`, then the bio.
    private var biographics: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !factLine.isEmpty {
                Text(factLine)
                    .font(.system(size: 14))
                    .foregroundStyle(GardenPalette.ink)
            }
            if let bio = profile?.bio {
                Text(bio)
                    .font(.system(size: 14))
                    .foregroundStyle(GardenPalette.ink)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    /// **Joined by what exists**, so a missing school does not leave " |  | ".
    /// All three are optional independently: age comes from a birthday nobody
    /// has to give twice, the school is free text, and the district needs a
    /// permission of its own.
    private var factLine: String {
        [profile?.age.map { "\($0)" }, profile?.school, profile?.district]
            .compactMap { $0 }
            .joined(separator: " | ")
    }

    /// Two by three, in the order its owner arranged them.
    private var grid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3),
            spacing: 2
        ) {
            ForEach(Array((profile?.photoPaths ?? []).enumerated()), id: \.offset) { index, path in
                Button { openPhoto = index } label: {
                    // **The square comes from the column, never from the
                    // photograph.** `Color.clear` accepts whatever width the
                    // grid proposes and `.fit` turns it into width x width, so
                    // all six cells are identical whatever the images are.
                    //
                    // Asking the photograph for the ratio is what broke it:
                    // `ProfilePhotoView` is already `.resizable().scaledToFill()`
                    // and so accepts any proposal, and a second
                    // `.aspectRatio(1, contentMode: .fill)` on top of that
                    // resolves against a `LazyVGrid` row whose height is
                    // unconstrained. `.fill` has no stable answer there — the
                    // three columns came out 256, 309 and 355 points wide, and
                    // the content escaped its row and painted over the bio
                    // above. The images were all 600x800; none of it came from
                    // the files.
                    Color.clear
                        // **4:5, the portrait Instagram uses for a post**, not
                        // the square its grid uses. A square crops a person to
                        // their face; the taller frame keeps whatever they
                        // framed, which on a dating profile is the picture.
                        .aspectRatio(4.0 / 5.0, contentMode: .fit)
                        .overlay {
                            ProfilePhotoView(ref: .stored(path), initial: profile?.name ?? "")
                        }
                        .clipped()
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 20)
    }
}
