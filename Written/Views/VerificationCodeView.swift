import SwiftUI

/// Account creation, step two: the six-digit code sent to the phone number from
/// the previous screen.
///
/// No code is actually sent yet — there is no verification service behind this.
/// `onResend` and `onVerify` are the seams where one gets wired in; until then
/// any six digits are accepted.
struct VerificationCodeView: View {
    /// E.164, for the verification service.
    let phoneNumber: String
    /// The same number as the user typed it, for the "Sent to" line.
    let displayNumber: String

    var onClose: () -> Void = {}
    var onEditNumber: () -> Void = {}
    /// Fires at the end of the whole sign-up flow, not when the code is checked:
    /// the name step is pushed from here first.
    var onSignedUp: (_ firstName: String, _ lastName: String?) -> Void = { _, _ in }
    var onResend: () -> Void = {}

    @State private var code = ""
    @State private var isConfirmingResend = false
    @State private var isEnteringName = false
    @FocusState private var isFocused: Bool

    private let codeLength = 6

    var body: some View {
        ZStack {
            SignInPalette.canvas.ignoresSafeArea()

            VStack(spacing: 0) {
                closeButton

                Text("Enter your verification code")
                    .font(BrandFont.title(32))
                    .foregroundStyle(SignInPalette.ink)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .padding(.horizontal, 24)
                    .padding(.top, 14)

                codeBoxes
                    .padding(.horizontal, 24)
                    .padding(.top, 44)

                sentToLine
                    .padding(.top, 16)

                Spacer(minLength: 24)

                // One button in two guises: asking for a new code is only useful
                // until the code is fully typed, at which point the same spot
                // becomes the way forward.
                Button(isComplete ? "Verify" : "Didn't get a code?") {
                    if isComplete {
                        // Nothing checks the code yet — see the note above.
                        isFocused = false
                        isEnteringName = true
                    } else {
                        isConfirmingResend = true
                    }
                }
                .buttonStyle(PressShrinkButtonStyle(expands: false))
                .padding(.bottom, 12)
            }
        }
        .preferredColorScheme(.light)
        // Focus has to wait for the push to finish. Asking in `onAppear` is
        // silently dropped mid-transition, and because the previous screen's
        // field is still up, the keyboard looks right while the digits would go
        // to the phone field instead.
        .task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            isFocused = true
        }
        .navigationDestination(isPresented: $isEnteringName) {
            NameEntryView(onContinue: onSignedUp)
                .navigationBarBackButtonHidden(true)
                .toolbar(.hidden, for: .navigationBar)
        }
        .alert("Didn't get a code?", isPresented: $isConfirmingResend) {
            Button("Send again") { onResend() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("We can send a new code to \(displayNumber).")
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

    /// The boxes are decoration: one real text field behind them owns the
    /// keyboard, the caret and — through `.oneTimeCode` — autofill from the SMS.
    private var codeBoxes: some View {
        HStack(spacing: 10) {
            ForEach(0..<codeLength, id: \.self) { index in
                CodeBox(
                    digit: digit(at: index),
                    isActive: isFocused && index == code.count
                )
            }
        }
        .overlay {
            TextField("", text: codeBinding)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($isFocused)
                // Invisible by colour rather than by opacity: a hidden or
                // zero-opacity field won't take focus, while at 1% its own text
                // still ghosts through the boxes.
                .foregroundStyle(.clear)
                .tint(.clear)
                .accessibilityLabel("Verification code")
        }
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
    }

    private var sentToLine: some View {
        HStack(spacing: 8) {
            Text("Sent to \(displayNumber) ·")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(SignInPalette.ink)

            Button(action: onEditNumber) {
                Image(systemName: "pencil")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(SignInPalette.ink)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit phone number")
        }
    }

    private var isComplete: Bool { code.count == codeLength }

    private func digit(at index: Int) -> String {
        guard index < code.count else { return "" }
        return String(Array(code)[index])
    }

    private var codeBinding: Binding<String> {
        Binding(
            get: { code },
            set: { code = String($0.filter(\.isNumber).prefix(codeLength)) }
        )
    }
}

/// One digit cell: a tall rounded box, with a blinking caret when it is the one
/// waiting to be filled.
private struct CodeBox: View {
    let digit: String
    let isActive: Bool

    @State private var isCaretVisible = true

    var body: some View {
        RoundedRectangle(cornerRadius: 20)
            .fill(SignInPalette.field)
            .frame(height: 74)
            .overlay {
                if digit.isEmpty {
                    if isActive {
                        Capsule()
                            .fill(SignInPalette.ink)
                            .frame(width: 2, height: 26)
                            .opacity(isCaretVisible ? 1 : 0)
                    }
                } else {
                    Text(digit)
                        .font(.system(size: 26))
                        .foregroundStyle(SignInPalette.ink)
                }
            }
            .onAppear {
                withAnimation(.easeInOut(duration: 0.55).repeatForever()) {
                    isCaretVisible = false
                }
            }
    }
}

#Preview {
    VerificationCodeView(phoneNumber: "+13149125096", displayNumber: "314 912 5096")
}
