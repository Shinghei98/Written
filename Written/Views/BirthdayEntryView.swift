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
/// **Continue does not leave the page.** It raises `BirthdayConfirmCard`, which
/// reads the date back in words and asks again. A birthday is the one answer
/// here that cannot be corrected later without a support request, and the digits
/// somebody types are the least readable form of it — `12 / 19 / 1998` is four
/// glyphs to check, "You're 27, born December 19, 1998" is a sentence you can
/// tell is wrong at a glance.
struct BirthdayEntryView: View {

    var onContinue: (Date, Int) -> Void = { _, _ in }

    @State private var month = ""
    @State private var day = ""
    @State private var year = ""
    /// Set by a failed Continue, never by arriving: three red boxes for not
    /// having typed yet is scolding somebody for nothing.
    @State private var problem: String?
    /// The date the confirm card is currently asking about. Non-nil *is* the
    /// card being up, so the two cannot disagree about which date is being
    /// confirmed — a separate `isShowing` flag plus a stored date could, and the
    /// failure would be confirming a date the user had since edited.
    @State private var confirming: Date?

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
                .padding(.horizontal, 28)
                .padding(.top, 34)
                // Clears the moment they start correcting it. The sheet gets
                // this for free by recomputing `showsError` from the entry;
                // here the reason is held rather than derived — an age refusal
                // is not visible in the date's shape — so it has to be dropped
                // by hand, or a fixed date would sit behind a red border and a
                // sentence saying it was wrong.
                .onChange(of: month + "/" + day + "/" + year) { _ in
                    problem = nil
                    raiseCardIfComplete()
                }

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
                        .padding(.top, 10)
                }

                Spacer(minLength: 24)

                Button("Continue", action: submit)
                    .buttonStyle(PressShrinkButtonStyle())
                    .frame(width: 176)
                    .padding(.bottom, 12)
            }

            // **Over everything, anchored to the bottom**, rather than a
            // `.sheet`. A sheet would take the keyboard down with it and then
            // give it back on Edit, so the page would jump twice for a
            // correction the user has not made yet; this rises in front of the
            // keyboard and leaves it exactly where it was.
            if let confirming {
                BirthdayConfirmCard(
                    birthday: confirming,
                    onEdit: { withAnimation(Self.cardMotion) { self.confirming = nil } },
                    onConfirm: { confirm(confirming) }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(1)
            }
        }
        .preferredColorScheme(.light)
#if DEBUG
        // `-birthday confirm` / `-birthday error`. See `DebugLaunch`.
        .onAppear {
            switch DebugLaunch.birthdayState {
            case "confirm":
                month = "12"; day = "19"; year = "1998"
                confirming = Calendar.current.date(
                    from: DateComponents(year: 1998, month: 12, day: 19)
                )
            case "error":
                problem = "You must enter a valid date of birth."
            default:
                break
            }
        }
#endif
    }

    /// Slow enough to read as something arriving rather than appearing, and
    /// damped rather than bouncy: this is a check, not a celebration.
    private static let cardMotion = Animation.spring(response: 0.38, dampingFraction: 0.86)

    /// Validates, then asks rather than proceeds.
    ///
    /// The three refusals below all stop here and never raise the card — there
    /// is nothing to confirm about a date that cannot exist, and showing "You're
    /// 4" over a card asking whether it is right would be reading a rejected
    /// answer back as though it had been accepted.
    /// Raise the card the moment the year is finished, with the keyboard still
    /// up — the reference does this and it is better than waiting for Continue.
    ///
    /// **Typing the last digit *is* the answer**, so asking for a second action
    /// before reading it back adds a step to the one page in onboarding that
    /// cannot be corrected later without a support request. The card rises in
    /// front of the keyboard rather than replacing it, so Edit puts the caret
    /// back where it was instead of bringing the keyboard up again.
    ///
    /// **It stays silent about refusals.** `submit` turns the boxes red for an
    /// impossible date, one 130 years back, or an age under 18; raising a card
    /// automatically must not do that, because a person halfway through typing
    /// 1998 has momentarily written 199, and telling them off mid-word is
    /// worse than saying nothing. So this only ever *raises* — the refusals
    /// still belong to Continue.
    private func raiseCardIfComplete() {
        guard confirming == nil,
              year.count == 4,
              let entered,
              let birthday = Calendar.current.date(from: entered),
              let age = Identity.age(on: birthday),
              (0...130).contains(age),
              age >= DistillViewModel.minimumAge
        else { return }
        withAnimation(Self.cardMotion) { confirming = birthday }
    }

    private func submit() {
        guard let entered, let birthday = Calendar.current.date(from: entered) else {
            withAnimation(.easeOut(duration: 0.15)) {
                problem = "You must enter a valid date of birth."
            }
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
        withAnimation(Self.cardMotion) { confirming = birthday }
    }

    private func confirm(_ birthday: Date) {
        confirming = nil
        onContinue(birthday, Calendar.current.component(.year, from: birthday))
    }
}

/// The card that reads a birthday back before it is committed.
///
/// Measured off the reference: inset 21 points from each edge, a 22-point
/// radius, near-white on parchment. Left-aligned throughout, unlike everything
/// else on this page — it is a passage to read rather than a page to look at,
/// and centred prose in a box reads as a dialog.
struct BirthdayConfirmCard: View {

    let birthday: Date
    var onEdit: () -> Void = {}
    var onConfirm: () -> Void = {}

    private var age: Int { Identity.age(on: birthday) ?? 0 }

    private var spelled: String {
        let formatter = DateFormatter()
        // Fixed format, so `en_US_POSIX` — the same rule `SyncService.day`
        // follows. Without it a device set to another calendar reads the year
        // back in that calendar, which on this card of all places would be a
        // number the user does not recognise as theirs.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "MMMM d, yyyy"
        return formatter.string(from: birthday)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 0) {
                Text("You're \(age)")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(GardenPalette.ink)

                Text("Born \(spelled).")
                    .font(.system(size: 15))
                    .foregroundStyle(GardenPalette.ink)
                    .padding(.top, 12)

                Text("Your accuracy of your age is important for the safety of our community and this platform.")
                    .font(.system(size: 15))
                    .foregroundStyle(GardenPalette.ink)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)

                HStack(spacing: 14) {
                    // **Edit is the wider target of the two and sits first**,
                    // because it is the one somebody reaches for when the card
                    // has told them something is wrong, and it is the one that
                    // costs nothing. Confirm is filled because it is the way on,
                    // not because it is the recommendation.
                    Button(action: onEdit) {
                        Text("Edit")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(GardenPalette.ink)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(Color.white, in: Capsule())
                            .overlay { Capsule().strokeBorder(SignInPalette.hairline, lineWidth: 1) }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    Button(action: onConfirm) {
                        Text("Confirm")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.white)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(GardenPalette.ink, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 22)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(red: 1, green: 0.996, blue: 0.992), in: RoundedRectangle(cornerRadius: 22))
            .overlay {
                RoundedRectangle(cornerRadius: 22)
                    .strokeBorder(GardenPalette.ink.opacity(0.08), lineWidth: 1)
            }
            .padding(.horizontal, 21)
            .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .accessibilityAddTraits(.isModal)
    }
}

#Preview {
    BirthdayEntryView()
}

#Preview("Confirm card") {
    ZStack {
        GardenPalette.parchment.ignoresSafeArea()
        BirthdayConfirmCard(
            birthday: Calendar.current.date(from: DateComponents(year: 1998, month: 12, day: 19))!
        )
    }
}
