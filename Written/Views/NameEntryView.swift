import SwiftUI

/// Account creation, step three: what the user wants to be called.
///
/// The names currently go no further than this screen — there is no profile
/// store yet. `onContinue` carries them out so that wiring one in later is a
/// change at the call site, not here.
struct NameEntryView: View {
    var onContinue: (_ firstName: String, _ lastName: String?) -> Void = { _, _ in }

    @State private var firstName = ""
    @State private var lastName = ""
    @State private var isMissingFirstName = false
    @FocusState private var focusedField: Field?

    private enum Field {
        case first, last
    }

    var body: some View {
        ZStack {
            SignInPalette.canvas.ignoresSafeArea()

            VStack(spacing: 0) {
                Text("What's your name?")
                    .font(BrandFont.title(32))
                    .foregroundStyle(SignInPalette.ink)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.top, 70)

                Text("Put down whatever you wish your dates to call you. You can edit any time.")
                    .font(.system(size: 16))
                    .foregroundStyle(SignInPalette.muted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .padding(.horizontal, 28)
                    .padding(.top, 14)

                field(
                    label: "First name",
                    placeholder: "Your first name",
                    text: firstNameBinding,
                    contentType: .givenName,
                    field: .first,
                    submitLabel: .next,
                    errorMessage: isMissingFirstName ? "You must enter a first name." : nil
                )
                .padding(.horizontal, 28)
                .padding(.top, 28)

                field(
                    label: "Last name (optional)",
                    placeholder: "Your last name",
                    text: $lastName,
                    contentType: .familyName,
                    field: .last,
                    submitLabel: .done
                )
                .padding(.horizontal, 28)
                .padding(.top, 16)

                lastNameNote
                    .padding(.horizontal, 28)
                    .padding(.top, 16)

                Spacer(minLength: 24)

                // Always tappable, like the phone step: a missing first name is
                // reported on the field, which a disabled button can't do.
                Button("Continue", action: submit)
                    .buttonStyle(PressShrinkButtonStyle())
                    .frame(width: 176)
                    .padding(.bottom, 12)
            }
        }
        .preferredColorScheme(.light)
        .task {
            // Same reason as the code screen: focus asked for during a push is
            // dropped, so it waits for the transition to settle.
            try? await Task.sleep(nanoseconds: 400_000_000)
            focusedField = .first
        }
    }

    private func field(
        label: String,
        placeholder: String,
        text: Binding<String>,
        contentType: UITextContentType,
        field: Field,
        submitLabel: SubmitLabel,
        errorMessage: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(SignInPalette.muted)

                TextField(placeholder, text: text)
                    .font(.system(size: 20))
                    .foregroundStyle(SignInPalette.ink)
                    .textContentType(contentType)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: field)
                    .submitLabel(submitLabel)
                    .onSubmit {
                        focusedField = field == .first ? .last : nil
                    }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(SignInPalette.field, in: RoundedRectangle(cornerRadius: 20))
            .overlay {
                if errorMessage != nil {
                    RoundedRectangle(cornerRadius: 20)
                        .strokeBorder(SignInPalette.error, lineWidth: 1.5)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 13))
                    .foregroundStyle(SignInPalette.error)
            }
        }
    }

    private var lastNameNote: some View {
        Text("Last name is optional, and only shared with matches.")
            .font(.system(size: 13))
            .foregroundStyle(SignInPalette.muted)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }

    private var trimmedFirstName: String {
        firstName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Empty stays `nil` rather than "" — absent and blank are the same thing
    /// here, and one of them shouldn't reach a profile record.
    private var trimmedLastName: String? {
        let trimmed = lastName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func submit() {
        guard !trimmedFirstName.isEmpty else {
            withAnimation(.easeOut(duration: 0.2)) { isMissingFirstName = true }
            focusedField = .first
            return
        }
        isMissingFirstName = false
        onContinue(trimmedFirstName, trimmedLastName)
    }

    /// The equality guard is load-bearing: the text field writes its unchanged
    /// value back when it takes focus, and `submit` focuses it — without this the
    /// error is cleared in the same breath it is set.
    private var firstNameBinding: Binding<String> {
        Binding(
            get: { firstName },
            set: { newValue in
                guard newValue != firstName else { return }
                firstName = newValue
                if isMissingFirstName {
                    withAnimation(.easeOut(duration: 0.2)) { isMissingFirstName = false }
                }
            }
        )
    }
}

#Preview {
    NameEntryView()
}
