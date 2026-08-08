import SwiftUI

/// The two questions that come after the name: who somebody is, and who they
/// want to meet.
///
/// **One view drawn twice**, because they are the same screen with different
/// words — a stack of rows and a Continue capsule each. Two near-identical files
/// would drift, and the drift would be invisible until somebody noticed the
/// second page's rows sat two points lower than the first's.
///
/// What differs is not only the words but the *arity*, and that is the whole
/// reason `Purpose` exists rather than a title string. Gender is one answer and
/// draws radios; who you are open to dating is several and draws checkboxes.
/// Using one control for both would either let somebody claim two genders or
/// stop them saying they date more than one kind of person.
struct GenderEntryView: View {

    /// What the page is for.
    enum Purpose {
        /// "Gender" — who the user is. Written to `users.sex` through
        /// `Identity`, and it is what the rest of the app means by their gender.
        /// **One answer only.**
        case identity
        /// "Who are you open to dating?" — who they want shown to them. Feeds
        /// `DatingPreferences.genders`, which is the same value Settings edits.
        /// **Any number of answers.**
        case interest

        var title: String {
            switch self {
            case .identity: return "Gender"
            case .interest: return "Who are you open to dating?"
            }
        }

        var subtitle: String? {
            switch self {
            case .identity: return nil
            case .interest: return "Select all that apply"
            }
        }

        /// Whether a second tap replaces the answer or adds to it.
        var isSingleChoice: Bool { self == .identity }
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
                        row(label: label(for: gender), isOn: chosen.contains(gender)) {
                            choose(gender)
                        }
                    }

                    // **Only on the interest page, and it is not a fourth
                    // gender.** `DatingPreferences.Gender` deliberately has no
                    // `everyone` case — a set with all three in it *is*
                    // everyone, and an enum case beside them could not express
                    // "men and nonbinary people". This row is a shortcut that
                    // ticks the other three, and it reads as ticked exactly when
                    // they all are, so the storage model is untouched.
                    if !purpose.isSingleChoice {
                        row(label: "Everyone", isOn: isEveryone) { toggleEveryone() }
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
                         ? "Choose one."
                         : "Choose at least one, or you will be shown nobody.")
                        .font(.system(size: 13))
                        .foregroundStyle(BirthdayFields.errorRed)
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

    /// **The two pages name the same three cases differently**, and both
    /// namings are right: the identity page asks what you *are* and the
    /// interest page asks who you would *date*, which in English is a different
    /// word — "Male" against "Men".
    private func label(for gender: DatingPreferences.Gender) -> String {
        guard !purpose.isSingleChoice else { return gender.label }
        switch gender {
        case .male: return "Men"
        case .female: return "Women"
        case .nonbinary: return "Non-binary people"
        }
    }

    private var isEveryone: Bool {
        chosen.count == DatingPreferences.Gender.allCases.count
    }

    private func choose(_ gender: DatingPreferences.Gender) {
        isMissing = false
        if purpose.isSingleChoice {
            // Replaced rather than toggled. A single-choice row that can be
            // tapped *off* leaves the page with no answer and a Continue that
            // refuses, which is a dead end built out of a control that looks
            // like it is working.
            chosen = [gender]
        } else if chosen.contains(gender) {
            chosen.remove(gender)
        } else {
            chosen.insert(gender)
        }
    }

    private func toggleEveryone() {
        isMissing = false
        chosen = isEveryone ? [] : Set(DatingPreferences.Gender.allCases)
    }

    /// A row, not a control with a label beside it: the whole row is the tap
    /// target, because a 24-point box at the end of a wide empty row is a target
    /// people miss.
    private func row(label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(label)
                    .font(.system(size: 17))
                    .foregroundStyle(SignInPalette.ink)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 8)

                // Drawn rather than a `Toggle`, so tapping the row and tapping
                // the indicator are one gesture with one handler. A real
                // control here would take its own taps and drift out of step
                // with the row around it.
                indicator(isOn: isOn)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(
                isOn ? Self.selectedFill : Self.rowFill,
                in: RoundedRectangle(cornerRadius: 22)
            )
            .shadow(color: GardenPalette.ink.opacity(0.05), radius: 3, y: 1)
            .overlay {
                RoundedRectangle(cornerRadius: 22)
                    .strokeBorder(
                        isMissing ? BirthdayFields.errorRed
                                  : (isOn ? GardenPalette.ink.opacity(0.35)
                                          : GardenPalette.ink.opacity(0.06)),
                        lineWidth: 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 22))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    /// **A circle for one answer, a square for several.** The shape is the only
    /// thing on the page that says whether picking a second option will replace
    /// the first, and it is a convention people already read without being told.
    @ViewBuilder
    private func indicator(isOn: Bool) -> some View {
        if purpose.isSingleChoice {
            ZStack {
                Circle()
                    .strokeBorder(isOn ? Color.clear : GardenPalette.ink.opacity(0.30), lineWidth: 1.5)
                    .background(Circle().fill(isOn ? GardenPalette.ink : .clear))
                if isOn {
                    Circle().fill(Color.white).frame(width: 8, height: 8)
                }
            }
            .frame(width: 24, height: 24)
            .animation(.easeOut(duration: 0.14), value: isOn)
        } else {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(isOn ? Color.clear : GardenPalette.ink.opacity(0.30), lineWidth: 1.5)
                .background(RoundedRectangle(cornerRadius: 4).fill(isOn ? GardenPalette.ink : .clear))
                .frame(width: 24, height: 24)
                .overlay {
                    if isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.white)
                    }
                }
                .animation(.easeOut(duration: 0.14), value: isOn)
        }
    }

    /// Near-white on parchment, matching `BirthdayFields.fieldFill`, and a
    /// warmer taupe once chosen — the reference darkens the whole row rather
    /// than only the indicator, which is what makes the answer findable when
    /// you come back to the page.
    private static let rowFill = Color(red: 0.988, green: 0.988, blue: 0.984)
    private static let selectedFill = Color(red: 0.898, green: 0.890, blue: 0.859)

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

#Preview("Open to dating") {
    GenderEntryView(purpose: .interest)
}
