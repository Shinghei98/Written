import SwiftUI

/// The two questions that come after the name: who somebody is, and who they
/// want to meet.
///
/// **One view drawn twice**, because they are the same screen with different
/// words — three rows and a toggle each. Two near-identical files would drift,
/// and the drift would be invisible until somebody noticed the second page's
/// rows sat two points lower than the first's.
///
/// Laid out to match `NameEntryView`: parchment, the title in Quicksand at 32,
/// a subtitle in the muted grey, and the same `Continue` capsule at the foot.
struct GenderEntryView: View {

    /// What the page is for. The only difference between the two.
    enum Purpose {
        /// "Gender" — who the user is. Written to `users.sex` through
        /// `Identity`, and it is what the rest of the app means by their gender.
        case identity
        /// "Who are you interested in?" — who they want shown to them. Feeds
        /// `DatingPreferences.genders`, which is the same value Settings edits.
        case interest

        var title: String {
            switch self {
            case .identity: return "Gender"
            case .interest: return "Who are you interested in?"
            }
        }

        /// **Only the second page has one.** The first asks something nobody
        /// needs reassuring about; the second is a preference people worry
        /// about committing to, so it says outright that it is not a commitment.
        var subtitle: String? {
            switch self {
            case .identity: return nil
            case .interest: return "Matching preference is fluid. You can edit any time."
            }
        }
    }

    let purpose: Purpose
    var initial: Set<DatingPreferences.Gender> = []
    var onContinue: (Set<DatingPreferences.Gender>) -> Void = { _ in }

    @State private var chosen: Set<DatingPreferences.Gender> = []
    @State private var isMissing = false

    var body: some View {
        ZStack {
            GardenPalette.parchment.ignoresSafeArea()

            VStack(spacing: 0) {
                Text(purpose.title)
                    .font(BrandFont.title(32))
                    .foregroundStyle(SignInPalette.ink)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.top, 70)

                if let subtitle = purpose.subtitle {
                    Text(subtitle)
                        .font(.system(size: 16))
                        .foregroundStyle(SignInPalette.muted)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                        .padding(.horizontal, 28)
                        .padding(.top, 14)
                }

                VStack(spacing: 12) {
                    ForEach(DatingPreferences.Gender.allCases) { gender in
                        row(gender)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, purpose.subtitle == nil ? 34 : 28)

                // **Reported here rather than by disabling Continue**, the same
                // choice the name page makes: a button that does nothing when
                // tapped cannot say why, and "nothing happened" is how a dead
                // end gets reported as a bug.
                if isMissing {
                    Text(purpose == .identity
                         ? "Choose at least one."
                         : "Choose at least one, or you will be shown nobody.")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(red: 0.72, green: 0.18, blue: 0.16))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                        .padding(.top, 14)
                }

                Spacer(minLength: 24)

                Button("Continue", action: submit)
                    .buttonStyle(PressShrinkButtonStyle())
                    .frame(width: 176)
                    .padding(.bottom, 12)
            }
        }
        .preferredColorScheme(.light)
        .onAppear { if chosen.isEmpty { chosen = initial } }
    }

    /// A row, not a checkbox list: the label is the tap target as well as the
    /// toggle, because a 44-point switch beside a wide empty row is a target
    /// people miss.
    private func row(_ gender: DatingPreferences.Gender) -> some View {
        Button {
            if chosen.contains(gender) { chosen.remove(gender) } else { chosen.insert(gender) }
            isMissing = false
        } label: {
            HStack {
                Text(gender.label)
                    .font(.system(size: 20))
                    .foregroundStyle(SignInPalette.ink)

                Spacer()

                // Drawn rather than a `Toggle`, so tapping the row and tapping
                // the switch are one gesture with one handler. A real `Toggle`
                // here would take its own taps and drift out of step with the
                // row around it.
                Capsule()
                    .fill(chosen.contains(gender) ? GardenPalette.gold : SignInPalette.muted.opacity(0.25))
                    .frame(width: 46, height: 28)
                    .overlay(alignment: chosen.contains(gender) ? .trailing : .leading) {
                        Circle()
                            .fill(.white)
                            .frame(width: 24, height: 24)
                            .padding(2)
                            .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                    }
                    .animation(.easeOut(duration: 0.16), value: chosen)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(SignInPalette.field, in: RoundedRectangle(cornerRadius: 20))
            .overlay {
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(
                        isMissing ? Color(red: 0.72, green: 0.18, blue: 0.16).opacity(0.55)
                                  : SignInPalette.hairline,
                        lineWidth: 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen.contains(gender) ? [.isSelected] : [])
    }

    private func submit() {
        guard !chosen.isEmpty else {
            isMissing = true
            return
        }
        onContinue(chosen)
    }
}

#Preview("Gender") {
    GenderEntryView(purpose: .identity)
}

#Preview("Interest") {
    GenderEntryView(purpose: .interest)
}
