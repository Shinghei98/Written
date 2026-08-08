import SwiftUI

/// Everybody who has liked you and is still waiting.
///
/// One row per person: their face, what happened, when, and the two answers. The
/// answers sit on the row rather than behind a swipe or a tap-through, because
/// there is nothing else to do on this page — a list whose only purpose is to be
/// answered should not hide the answers.
struct AdmirersView: View {
    @ObservedObject var model: ChatModel
    /// Only for the dynamic profile, which needs this account's own subjects
    /// and domains to work out what the two of them share.
    @ObservedObject var viewModel: DistillViewModel
    /// Whose profile is open, if any.
    @State private var profileTarget: LikeService.Admirer?
    /// Called when accepting has produced a thread, so the caller can push it.
    /// This view does not own the navigation stack it is in.
    var onOpened: (ChatService.Conversation) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .top) {
            GardenPalette.parchment.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    if model.admirers.isEmpty {
                        empty
                    } else {
                        ForEach(model.admirers) { admirer in
                            AdmirerRow(
                                admirer: admirer,
                                isAnswering: model.answering == admirer.id,
                                onChat: { answer(admirer, accept: true) },
                                onDecline: { answer(admirer, accept: false) },
                                onOpenProfile: { profileTarget = admirer }
                            )
                        }
                    }
                }
                .padding(.top, Self.headerHeight)
                .padding(.bottom, MainTabBar.overlayHeight + 12)
            }

            header.background(GardenPalette.parchment)
        }
        .preferredColorScheme(.light)
        .fullScreenCover(item: $profileTarget) { admirer in
            MatchProfileView(
                personID: admirer.id,
                fallbackName: admirer.name,
                fallbackPhoto: admirer.photoRef,
                viewModel: viewModel,
                onClose: { profileTarget = nil }
            )
        }
    }

    private static let headerHeight: CGFloat = 60

    /// A back arrow of its own, because the system bar is hidden here for the same
    /// reason it is everywhere else in this app: the pages carry their own
    /// furniture and a translucent `UINavigationBar` over parchment reads as a
    /// second, colder surface.
    private var header: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(GardenPalette.ink)
                    .frame(width: 38, height: 38)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")

            Text("Admirers")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(GardenPalette.ink)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: Self.headerHeight)
    }

    private func answer(_ admirer: LikeService.Admirer, accept: Bool) {
        Task {
            let conversation = await model.respond(to: admirer, accept: accept)
            guard let conversation else { return }
            onOpened(conversation)
        }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "heart")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(GardenPalette.gold)
            Text("Nobody waiting")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(GardenPalette.ink)
            Text("Likes you haven't answered yet appear here.")
                .font(.system(size: 14))
                .foregroundStyle(GardenPalette.muted)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 44)
        .padding(.top, 60)
    }
}

/// One admirer, with the two ways out.
struct AdmirerRow: View {
    let admirer: LikeService.Admirer
    var isAnswering = false
    var onChat: () -> Void = {}
    var onDecline: () -> Void = {}
    /// One of the two doors to the dynamic profile — see `MatchProfileView`.
    var onOpenProfile: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            // Their real photograph where there is one, as chat and the feed
            // now draw. `PortraitView` only ever gives the generated stand-in.
            //
            // **The face is the way in.** Tapping a person's photograph to see
            // more of them is the gesture every social app has already taught,
            // so it needs no affordance of its own — and putting a "View
            // profile" button here would compete with Accept and Decline, which
            // are what this row is for.
            Button(action: onOpenProfile) {
                ProfilePhotoView(ref: admirer.photoRef, initial: admirer.name)
                    .frame(width: 54, height: 54)
                    .clipShape(Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("See \(admirer.name)'s profile")

            VStack(alignment: .leading, spacing: 3) {
                Text("\(admirer.name) likes you!")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(GardenPalette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                // What they wrote, where the timestamp used to sit alone. This
                // is the whole reason somebody writes one — a note nobody reads
                // is a promise the compose sheet's subtitle breaks.
                if let message = admirer.message {
                    Text(message)
                        .font(.system(size: 14))
                        .foregroundStyle(GardenPalette.ink.opacity(0.8))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(RelativeTime.short(since: admirer.likedAt))
                    .font(.system(size: 13))
                    .foregroundStyle(GardenPalette.muted)
            }
            // The name gives way, the buttons do not. Without this the row shares
            // the squeeze evenly and both labels wrap mid-word — "Cha t" and
            // "Decli ne", which is what this row did until the layout was looked at.
            .layoutPriority(-1)

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                Button(action: onChat) {
                    Text("Chat").lineLimit(1)
                }
                .buttonStyle(
                    PressShrinkButtonStyle(
                        expands: false,
                        font: .system(size: 14, weight: .semibold),
                        horizontalPadding: 15,
                        minHeight: 34
                    )
                )

                Button(action: onDecline) {
                    Text("Decline").lineLimit(1)
                }
                .buttonStyle(
                    PressShrinkButtonStyle(
                        fill: .clear,
                        foreground: GardenPalette.muted,
                        border: SignInPalette.fieldBorder,
                        expands: false,
                        font: .system(size: 14, weight: .semibold),
                        horizontalPadding: 13,
                        minHeight: 34
                    )
                )
            }
            // Sized to the two labels and never compressed below it.
            .fixedSize(horizontal: true, vertical: false)
            // Both go inert together while the answer is in flight. Disabling only
            // the one that was tapped would leave the other live, and answering a
            // like twice with two different answers is a race the database would
            // resolve arbitrarily.
            .disabled(isAnswering)
            .opacity(isAnswering ? 0.4 : 1)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}
