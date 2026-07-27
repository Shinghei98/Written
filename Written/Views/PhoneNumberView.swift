import CoreText
import SwiftUI

/// Account creation, step one. Reached from "Create account" and from
/// "Sign in with Phone Number".
struct PhoneNumberView: View {
    var onClose: () -> Void = {}
    /// Called at the end of sign-up, once the code and name steps are done.
    var onSignedUp: (_ phoneNumber: String, _ firstName: String, _ lastName: String?) -> Void = { _, _, _ in }

    @State private var country: Country = .unitedStates
    @State private var number = ""
    @State private var isShowingNumberChangeInfo = false
    @State private var isShowingCountryPicker = false
    @State private var isVerifying = false
    @State private var error: EntryError?
    @FocusState private var isFieldFocused: Bool

    /// What the field says when the number can't be submitted. The wording for
    /// a malformed number is deliberately vague — it matches what the server
    /// will say once numbers are really being sent for verification.
    enum EntryError {
        case missing, invalid

        var message: String {
            switch self {
            case .missing: return "Enter your phone number to continue"
            case .invalid: return "Something went wrong. Please try again later."
            }
        }
    }

    var body: some View {
        ZStack {
            SignInPalette.canvas.ignoresSafeArea()

            VStack(spacing: 0) {
                closeButton

                Text("What's your phone number?")
                    .font(BrandFont.title(32))
                    .foregroundStyle(SignInPalette.ink)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .padding(.horizontal, 24)
                    .padding(.top, 14)

                Text("Your phone number won't be shown to anyone. We take privacy very seriously.")
                    .font(.system(size: 16))
                    .foregroundStyle(SignInPalette.muted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .padding(.horizontal, 32)
                    .padding(.top, 14)

                entryRow
                    .padding(.horizontal, 24)
                    .padding(.top, 40)

                Button("What if my number changes?") {
                    isShowingNumberChangeInfo = true
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(SignInPalette.ink)
                .padding(.top, 18)

                Spacer(minLength: 24)

                // Always tappable: the field is validated on submit, so an empty
                // or malformed number has to be able to reach `submit()` in
                // order to say what is wrong with it.
                Button("Continue", action: submit)
                    .buttonStyle(PressShrinkButtonStyle())
                    .frame(width: 176)

                Text("Written will send you a text with a verification code. Message and data rates may apply.")
                    .font(.system(size: 12))
                    .foregroundStyle(SignInPalette.muted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .padding(.top, 16)
                    .padding(.bottom, 12)
            }
        }
        .preferredColorScheme(.light)
        .onAppear { isFieldFocused = true }
        // Full screen rather than a sheet: the reference list runs edge to edge
        // with its own close button, and there is nothing to see behind it.
        .fullScreenCover(isPresented: $isShowingCountryPicker) {
            CountryPickerView(
                // Changing country changes what counts as valid, so a standing
                // error no longer describes the current input.
                selection: Binding(
                    get: { country },
                    set: { country = $0; error = nil }
                ),
                onClose: { isShowingCountryPicker = false }
            )
        }
        .navigationDestination(isPresented: $isVerifying) {
            VerificationCodeView(
                phoneNumber: country.dialCode + digits,
                displayNumber: country.displayNationalNumber(digits),
                // The X closes the whole sign-up flow; the pencil steps back
                // here to correct the number.
                onClose: onClose,
                onEditNumber: { isVerifying = false },
                onSignedUp: { firstName, lastName in
                    onSignedUp(country.dialCode + digits, firstName, lastName)
                }
            )
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .navigationBar)
        }
        .alert("What if my number changes?", isPresented: $isShowingNumberChangeInfo) {
            Button("Got it", role: .cancel) {}
        } message: {
            Text("You can update your number any time from Settings. It's only ever used to sign you in.")
        }
    }

    private var closeButton: some View {
        HStack {
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(SignInPalette.ink)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
        }
        .padding(.trailing, 12)
    }

    /// The message lives inside the field's own column, which is what keeps it
    /// aligned with the field's left edge *and* unable to affect the row's
    /// width. Aligning it with a custom guide instead makes the row size itself
    /// to the guide-offset text — wider than the screen — which drags the field
    /// and the padding out with it.
    private var entryRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                isShowingCountryPicker = true
            } label: {
                // Kept tight so the phone field — and so the error message that
                // has to fit under it — gets as much of the row as possible.
                HStack(spacing: 6) {
                    Text(country.flag)
                        .font(.system(size: 18))
                    Text(country.dialCode)
                        .font(.system(size: 18))
                        .foregroundStyle(SignInPalette.ink)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SignInPalette.muted)
                }
                .frame(height: 54)
                .padding(.horizontal, 13)
                .background(SignInPalette.field, in: RoundedRectangle(cornerRadius: 18))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 8) {
                TextField("Phone number", text: numberBinding)
                    .font(.system(size: 18))
                    .foregroundStyle(SignInPalette.ink)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                    .focused($isFieldFocused)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .padding(.horizontal, 16)
                    .background(SignInPalette.field, in: RoundedRectangle(cornerRadius: 18))
                    .overlay {
                        if error != nil {
                            RoundedRectangle(cornerRadius: 18)
                                .strokeBorder(SignInPalette.error, lineWidth: 1.5)
                        }
                    }

                if let error {
                    // One line, shrinking rather than wrapping or widening: the
                    // longer of the two messages is a few points wider than the
                    // column at 13pt.
                    Text(error.message)
                        .font(.system(size: 13))
                        .foregroundStyle(SignInPalette.error)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
        }
    }

    private var digits: String { number.filter(\.isNumber) }

    /// Validates on submit rather than as the user types: a number is not wrong
    /// just because it is half-entered.
    private func submit() {
        guard !digits.isEmpty else {
            showError(.missing)
            return
        }
        guard country.isValidNationalNumber(digits) else {
            showError(.invalid)
            return
        }
        error = nil
        // Hand the keyboard over: without this the phone field keeps focus
        // behind the code screen, which then can't take it.
        isFieldFocused = false
        isVerifying = true
    }

    private func showError(_ entryError: EntryError) {
        withAnimation(.easeOut(duration: 0.2)) { error = entryError }
        isFieldFocused = true
    }

    /// Formats on write rather than in `onChange`, so there is never a frame
    /// where the raw text is on screen. A real edit also clears the error, since
    /// the message described what was in the field a keystroke ago.
    ///
    /// The equality guard matters: the text field writes its unchanged value
    /// back through this binding when it takes focus, and `showError` focuses
    /// the field — without the guard the error is cleared in the same breath it
    /// is set, and never appears at all.
    private var numberBinding: Binding<String> {
        Binding(
            get: { number },
            set: { newValue in
                let formatted = country.format(newValue)
                guard formatted != number else { return }
                number = formatted
                if error != nil {
                    withAnimation(.easeOut(duration: 0.2)) { error = nil }
                }
            }
        )
    }
}

/// Quicksand Regular — the face the logo tagline is set in. The file lives at
/// `Resources/Fonts/Quicksand-Regular.ttf`, with its OFL license beside it as
/// the font's terms require. This is the only place headline type is chosen.
///
/// The static Regular is deliberate: Google's variable `Quicksand[wght].ttf`
/// defaults to Light 300, which is too thin next to the logo.
enum BrandFont {
    private static let name = "Quicksand-Regular"

    /// This project's Info.plist is generated from build settings, and Xcode
    /// does not carry a `UIAppFonts` key through, so the bundled face has to be
    /// registered by hand at launch instead. Must run before the first view
    /// renders, or `Font.custom` silently falls back to the system font.
    static func register() {
        guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else {
            assertionFailure("Quicksand-Regular.ttf is missing from the bundle")
            return
        }
        var error: Unmanaged<CFError>?
        if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
            assertionFailure("Could not register \(name): \(String(describing: error?.takeRetainedValue()))")
        }
    }

    static func title(_ size: CGFloat) -> Font {
        .custom(name, size: size, relativeTo: .largeTitle)
    }
}

#Preview {
    PhoneNumberView()
}
