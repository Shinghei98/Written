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
            // dismissal. `MatchPhotoCard` is kept — it is still the right shape
            // for a single photograph and nothing else has to change to use it
            // again.
            if let openPhoto, let profile, openPhoto < profile.photoPaths.count {
                MatchPostsView(
                    name: profile.name,
                    paths: profile.photoPaths,
                    captions: profile.captions,
                    opening: openPhoto,
                    onClose: { self.openPhoto = nil }
                )
                .transition(.move(edge: .trailing))
            }
        }
        .task { await load() }
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

/// One photograph, full width, with the shared line under it.
///
/// **`DiscoveryCard`'s shape without its verbs.** The feed's card is an
/// invitation — a heart, an envelope, a bookmark — and none of that belongs
/// here: this page is reached *after* an invitation exists, so offering to send
/// another would let somebody invite a person they are already talking to. What
/// carries over is the part worth keeping, a photograph with a sentence under
/// it that is about both people.
struct MatchPhotoCard: View {

    let name: String
    let path: String
    let caption: String?
    var onClose: () -> Void = {}

    var body: some View {
        ZStack {
            // Tapping anywhere outside closes it, which is the gesture people
            // try first on a photograph opened from a grid.
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)

            VStack(spacing: 0) {
                ProfilePhotoView(ref: .stored(path), initial: name)
                    .aspectRatio(4 / 5, contentMode: .fill)
                    .clipped()

                // **Absent rather than blank when there is nothing shared.** A
                // caption slot with no caption reads as a photograph that
                // failed to load its text.
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
            .padding(.horizontal, 18)
            .accessibilityLabel(caption.map { "\(name). \($0)" } ?? name)
        }
    }
}
