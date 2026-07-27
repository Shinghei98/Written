import SwiftUI

enum SignInMethod {
    case apple, google, phone
}

/// Launch screen: the logo write-on plays once, then the two entry points.
///
/// Tapping "Sign in" swaps the bottom stack for the provider buttons. The stack
/// is bottom-anchored, so the legal text and the trailing button ride upwards as
/// the taller set of buttons takes their place, and the logo — positioned
/// independently of the stack — stays exactly where it is.
///
/// The background photo of the reference design is deliberately not here yet —
/// the canvas matches the GIF's own off-white so the animation sits flush on it.
struct SignInView: View {
    var onCreateAccount: () -> Void = {}
    var onSignIn: (SignInMethod) -> Void = { _ in }

    @State private var isChoosingProvider = false

    var body: some View {
        ZStack {
            SignInPalette.canvas.ignoresSafeArea()

            // Positioned off the screen rather than stacked above the buttons, so
            // growing the bottom stack never nudges the logo.
            GeometryReader { geometry in
                AnimatedGIFView(name: "written_logo_slogan_animation")
                    .frame(width: min(340, geometry.size.width - 48))
                    .position(x: geometry.size.width / 2, y: geometry.size.height * 0.30)
                    .accessibilityLabel("Written — let your love story be written")
            }

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                legalText
                    .padding(.horizontal, 28)
                    .padding(.bottom, 22)

                buttonStack

                trailingButton
                    .padding(.top, 14)
                    .padding(.bottom, 12)
            }
        }
        .preferredColorScheme(.light) // the palette and the GIF are light-only
    }

    private var buttonInset: CGFloat { 40 }

    /// The black capsule is the *same* view in both states — it only re-titles
    /// itself. Swapping it for a different black button instead would cross-fade
    /// two capsules over each other while the stack resizes, which reads as a
    /// shake. Only the two white buttons are inserted, and they fade with no
    /// offset or scale of their own: any transform here rasterizes the label and
    /// makes the text look blurry mid-animation.
    private var buttonStack: some View {
        VStack(spacing: 12) {
            if isChoosingProvider {
                Button(action: { onSignIn(.apple) }) {
                    Label {
                        Text("Sign in with Apple")
                    } icon: {
                        Image(systemName: "applelogo")
                            .font(.system(size: 19))
                    }
                }
                .buttonStyle(PressShrinkButtonStyle(fill: .white, foreground: SignInPalette.ink, border: SignInPalette.hairline))
                .transition(providerTransition)

                Button(action: { onSignIn(.google) }) {
                    Label {
                        Text("Sign in with Google")
                    } icon: {
                        GoogleGlyph()
                    }
                }
                .buttonStyle(PressShrinkButtonStyle(fill: .white, foreground: SignInPalette.ink, border: SignInPalette.hairline))
                .transition(providerTransition)
            }

            Button(action: isChoosingProvider ? { onSignIn(.phone) } : onCreateAccount) {
                SwappingLabel(isChoosingProvider ? "Sign in with Phone Number" : "Create account")
            }
            .buttonStyle(PressShrinkButtonStyle())
        }
        .padding(.horizontal, buttonInset)
    }

    /// Offset against the 0.3s layout move so the legal text is never seen
    /// sliding through a button: on the way in the gap opens first and the
    /// buttons fade into it, on the way out they clear before the text arrives.
    private var providerTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.animation(.easeOut(duration: 0.18).delay(0.15)),
            removal: .opacity.animation(.easeIn(duration: 0.12))
        )
    }

    private var trailingButton: some View {
        Button(action: {
            // No bounce: a spring that overshoots on a bottom-anchored stack is
            // exactly what looks like a shake.
            withAnimation(.easeInOut(duration: 0.3)) {
                isChoosingProvider.toggle()
            }
        }) {
            SwappingLabel(isChoosingProvider ? "Back" : "Sign in")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(SignInPalette.ink)
                .padding(.vertical, 14)
                .padding(.horizontal, 24)
        }
        .buttonStyle(.plain)
    }

    private var legalText: some View {
        Text(legalAttributedString)
            .font(.system(size: 13))
            .foregroundStyle(SignInPalette.muted)
            .multilineTextAlignment(.center)
            .lineSpacing(3)
            .tint(SignInPalette.ink)
    }

    /// Markdown gives the tappable links; the underline is applied afterwards
    /// because Markdown has no syntax for it.
    private var legalAttributedString: AttributedString {
        let markdown = """
        By tapping 'Sign in' / 'Create account', you agree to our \
        [Terms of Service](https://written.app/terms). Learn how we process your data in our \
        [Privacy Policy](https://written.app/privacy) and [Cookies Policy](https://written.app/cookies).
        """
        var string = (try? AttributedString(markdown: markdown)) ?? AttributedString(markdown)
        for run in string.runs where run.link != nil {
            string[run.range].underlineStyle = .single
            string[run.range].font = .system(size: 13, weight: .semibold)
            string[run.range].foregroundColor = SignInPalette.ink
        }
        return string
    }
}

/// Swaps one string for another without the two ever being drawn on top of each
/// other: a plain cross-dissolve superimposes both wordings for a moment, which
/// reads as blurred text. The outgoing label clears first, then the new one
/// arrives.
///
/// The fade is driven by opacity rather than by a transition on a re-`id`ed
/// `Text`, because changing the label's identity inside a `ButtonStyle` fades
/// the styled body along with it — the black capsule washes out to grey.
struct SwappingLabel: View {
    private let text: String

    @State private var displayed: String
    @State private var opacity: Double = 1

    init(_ text: String) {
        self.text = text
        _displayed = State(initialValue: text)
    }

    var body: some View {
        Text(displayed)
            .opacity(opacity)
            .task(id: text) {
                guard displayed != text else { return }
                withAnimation(.easeIn(duration: 0.12)) { opacity = 0 }
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled else { return }
                displayed = text
                withAnimation(.easeOut(duration: 0.14)) { opacity = 1 }
            }
    }
}

/// Capsule button that holds a shrink for as long as the finger is down and
/// springs back on release.
struct PressShrinkButtonStyle: ButtonStyle {
    var fill: Color = SignInPalette.ink
    var foreground: Color = SignInPalette.canvas
    var border: Color?
    /// `false` sizes the capsule to its label instead of filling the row.
    var expands = true
    /// Defaults match the sign-up screens; the garden's card needs a smaller pill.
    var font: Font = .system(size: 17, weight: .semibold)
    var horizontalPadding: CGFloat = 28
    var minHeight: CGFloat = 54

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(font)
            .foregroundStyle(foreground)
            .padding(.horizontal, expands ? 0 : horizontalPadding)
            .frame(maxWidth: expands ? .infinity : nil, minHeight: minHeight)
            .background(fill, in: Capsule())
            .overlay {
                if let border {
                    Capsule().strokeBorder(border, lineWidth: 1)
                }
            }
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Stand-in for the Google mark: the official multicolour "G" is a licensed
/// asset, so drop the real one into the asset catalog before shipping.
private struct GoogleGlyph: View {
    var body: some View {
        Text("G")
            .font(.system(size: 20, weight: .bold, design: .default))
            .foregroundStyle(
                AngularGradient(
                    colors: [
                        Color(red: 0.26, green: 0.52, blue: 0.96), // blue
                        Color(red: 0.20, green: 0.66, blue: 0.33), // green
                        Color(red: 0.98, green: 0.74, blue: 0.02), // yellow
                        Color(red: 0.92, green: 0.26, blue: 0.21), // red
                        Color(red: 0.26, green: 0.52, blue: 0.96)
                    ],
                    center: .center
                )
            )
            .accessibilityHidden(true)
    }
}

enum SignInPalette {
    /// Matches the GIF's own background so the animation has no visible edge.
    static let canvas = Color(red: 252 / 255, green: 252 / 255, blue: 252 / 255)
    static let ink = Color(red: 0.07, green: 0.07, blue: 0.07)
    static let muted = Color(red: 0.42, green: 0.42, blue: 0.42)
    static let hairline = Color(red: 0.86, green: 0.86, blue: 0.86)
    static let field = Color(red: 0.93, green: 0.93, blue: 0.93)
    static let error = Color(red: 0.91, green: 0.13, blue: 0.15)
    static let disabled = Color(red: 0.62, green: 0.61, blue: 0.59)
}

#Preview {
    SignInView()
}
