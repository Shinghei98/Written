import SwiftUI

/// The age gate, asked first — before the name, and immediately after the
/// number is verified.
///
/// **The rule had no mechanism until now.** The Terms have said "you must be 18
/// or older" since they were written, and the only place an age could enter the
/// app was an optional row on the dashboard that nobody had to fill in. So the
/// floor was a sentence rather than a gate, and a thirteen-year-old could finish
/// onboarding without ever stating a date. Apple's June 2026 guidance is
/// explicit that an app teenagers may reach has to be age-appropriate in
/// itself, and a reviewer tests that by typing a birth date.
///
/// First, rather than somewhere in the middle, because everything after it —
/// a name, photographs, a gender, who they want to meet — is data collected
/// from somebody the app has no business collecting from.
///
/// Laid out to match `NameEntryView` and `GenderEntryView`: parchment, the
/// title in Quicksand at 32, the subtitle in the muted grey, the same Continue
/// capsule at the foot. The boxes themselves are `BirthdayFields`, shared with
/// the dashboard's sheet so there is one definition of how a date is typed.
struct BirthdayEntryView: View {

    var onContinue: (Date, Int) -> Void = { _, _ in }

    @State private var month = ""
    @State private var day = ""
    @State private var year = ""
    /// Set by a failed Continue, never by arriving: three red boxes for not
    /// having typed yet is scolding somebody for nothing.
    @State private var problem: String?

    private var entered: DateComponents? {
        BirthdayFields.entered(month: month, day: day, year: year)
    }

    var body: some View {
        ZStack {
            GardenPalette.parchment.ignoresSafeArea()

            VStack(spacing: 0) {
                Text("What's your birthday?")
                    .font(BrandFont.title(32))
                    .foregroundStyle(SignInPalette.ink)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.top, 70)

                Text("This app is only available for users above the age of 18.")
                    .font(.system(size: 16))
                    .foregroundStyle(SignInPalette.muted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .padding(.horizontal, 28)
                    .padding(.top, 14)

                BirthdayFields(
                    month: $month, day: $day, year: $year,
                    showsError: problem != nil
                )
                .padding(.top, 34)
                // Clears the moment they start correcting it. The sheet gets
                // this for free by recomputing `showsError` from the entry;
                // here the reason is held rather than derived — an age refusal
                // is not visible in the date's shape — so it has to be dropped
                // by hand, or a fixed date would sit behind a red border and a
                // sentence saying it was wrong.
                .onChange(of: month + "/" + day + "/" + year) { _ in problem = nil }

                // **Said out loud rather than by disabling Continue.** A button
                // that does nothing when tapped cannot say why, and "nothing
                // happened" is how a dead end gets reported as a broken app —
                // which is exactly how the biographics failures were reported
                // before they had somewhere to put their reason.
                if let problem {
                    Text(problem)
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
    }

    private func submit() {
        guard let entered,
              let year = entered.year,
              let birthday = Calendar.current.date(from: entered) else {
            withAnimation(.easeOut(duration: 0.15)) { problem = "Enter a valid date of birth." }
            return
        }

        // The same two tests `DistillViewModel.setBirthday` makes, in the same
        // order, because this is the other door into the same fact. A date in
        // the future or a hundred and thirty years back is a typo rather than a
        // person, and it should not read as an age refusal.
        guard let age = Identity.age(on: birthday), (0...130).contains(age) else {
            withAnimation(.easeOut(duration: 0.15)) { problem = "That doesn't look like a real date." }
            return
        }

        guard age >= DistillViewModel.minimumAge else {
            withAnimation(.easeOut(duration: 0.15)) {
                problem = "You must be 18 or older to use Written."
            }
            return
        }

        problem = nil
        onContinue(birthday, year)
    }
}

#Preview {
    BirthdayEntryView()
}
