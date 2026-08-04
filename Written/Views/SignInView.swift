import SwiftUI

/// Launch screen: the logo write-on plays once, then the one way in.
///
/// **It offered four buttons and three of them signed nobody in.** "Create
/// account" and "Sign in with Phone Number" both opened the phone flow, which
/// ends at `route = .photos` with no authentication call anywhere — the screens
/// are finished and were never wired to anything, because Twilio was rejected
/// on cost. "Sign in with Google" set `route = .home` and did nothing else.
///
/// A tester took the biggest button on the screen, reached the photo page with
/// no session, and was told "You're not signed in" — correctly. They never saw
/// the communication style step either, because the phone path skips
/// `route(for:)` and jumps straight to photos. Their account did not exist, so
/// nothing they did could be saved and nobody could find them in Explore.
///
/// So: one provider, one button. **Sign in with Apple needs no separate
/// sign-up** — the same call creates the account or signs into it — which is
/// what leaves nothing for a second state to say. The toggle went with it.
///
/// `PhoneNumberView` and `VerificationCodeView` stay on disk, unreferenced.
/// They are finished screens and the harm was in reaching them.
///
/// The background photo of the reference design is deliberately not here yet —
/// the canvas matches the GIF's own off-white so the animation sits flush on it.
struct SignInView: View {
    var onSignIn: () -> Void = {}
    /// Phone is back, and this time it authenticates. It sits second rather
    /// than first because Apple costs nothing to run and every phone sign-in
    /// costs an SMS — the free route should be the easy one to take.
    var onPhone: () -> Void = {}

    var body: some View {
        ZStack {
            GardenPalette.parchment.ignoresSafeArea()

            // Positioned off the screen rather than stacked above the buttons, so
            // growing the bottom stack never nudges the logo.
            GeometryReader { geometry in
                AnimatedGIFView(name: "written_logo_slogan_animation")
                    .frame(width: min(340, geometry.size.width - 48))
                    // The GIF is baked on its own near-white (252,252,252), which
                    // used to be the page colour too, so its edge was invisible.
                    // On parchment that rectangle shows, and it has to be blended
                    // away rather than cropped — the animation moves.
                    //
                    // `.darken` keeps whichever of the two is darker per channel:
                    // the GIF's white loses to parchment and vanishes, its black
                    // strokes win and stay. `.multiply` was the obvious choice and
                    // is subtly wrong here — 252 is not 255, so it left a residue
                    // of (240,236,230) against parchment's (243,239,233), a
                    // rectangle three units dark and still visible.
                    //
                    // Safe because the animation is purely black-on-white; there
                    // is no colour in it for `.darken` to alter.
                    .blendMode(.darken)
                    .position(x: geometry.size.width / 2, y: geometry.size.height * 0.30)
                    .accessibilityLabel("Written — let your love story be written")
            }

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                legalText
                    .padding(.horizontal, 28)
                    .padding(.bottom, 22)

                buttonStack
                    .padding(.bottom, 34)
            }
        }
        .preferredColorScheme(.light) // the palette and the GIF are light-only
    }

    private var buttonInset: CGFloat { 40 }

    /// Two routes in, both of which now actually create an account.
    ///
    /// It was a two-state stack — a black capsule re-titling itself between
    /// "Create account" and "Sign in with Phone Number", with Apple and Google
    /// fading in above it — and the care went into never letting two capsules
    /// cross-fade, because that reads as a shake. All of it was in service of
    /// three buttons that authenticated nobody. Neither provider here needs a
    /// separate sign-up: each call creates the account or signs into it, so
    /// there is nothing for a second state to say.
    ///
    /// Apple is the primary because it is free to run and instant. Phone is the
    /// quieter one for people who will not use Sign in with Apple — and every
    /// tap on it sends an SMS somebody pays for.
    private var buttonStack: some View {
        VStack(spacing: 12) {
            Button(action: onSignIn) {
                Label {
                    Text("Continue with Apple")
                } icon: {
                    Image(systemName: "applelogo")
                        .font(.system(size: 19))
                }
            }
            .buttonStyle(PressShrinkButtonStyle())

            Button(action: onPhone) {
                Label {
                    Text("Continue with phone")
                } icon: {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 17))
                }
            }
            .buttonStyle(
                PressShrinkButtonStyle(
                    fill: .white, foreground: SignInPalette.ink, border: SignInPalette.hairline
                )
            )
        }
        .padding(.horizontal, buttonInset)
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
    ///
    /// **These three pointed at `written.app` for months, which is not ours** —
    /// it is a live, unrelated decentralised e-book store — so every one of them
    /// was a dead link promising a document we had never written. They resolve
    /// to `written-stl.com` now, where all three pages exist; the same three
    /// URLs are what Google's OAuth consent screen names, so a change here has
    /// to be made there as well or verification and the app disagree.
    private var legalAttributedString: AttributedString {
        let markdown = """
        By tapping 'Sign in' / 'Create account', you agree to our \
        [Terms of Service](https://written-stl.com/en-us/terms/). Learn how we process your data in our \
        [Privacy Policy](https://written-stl.com/en-us/privacy/) and \
        [Cookies Policy](https://written-stl.com/en-us/cookies/).
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
    /// The label colour on a dark fill — no longer a page background.
    ///
    /// Every screen now opens on `GardenPalette.parchment`, so the app is one
    /// surface from sign-in to the garden. This near-white survives as the
    /// colour of text sitting *on* ink, where parchment would read as dirty.
    static let canvas = Color(red: 252 / 255, green: 252 / 255, blue: 252 / 255)
    static let ink = Color(red: 0.07, green: 0.07, blue: 0.07)
    static let muted = Color(red: 0.42, green: 0.42, blue: 0.42)
    static let hairline = Color(red: 0.86, green: 0.86, blue: 0.86)
    static let field = Color(red: 0.93, green: 0.93, blue: 0.93)

    /// The outline every input carries.
    ///
    /// Needed once the pages moved to parchment: `field` is (237,237,237) and
    /// parchment is (243,239,233), six units apart, so a fill alone no longer
    /// says where a field begins. Warm rather than the cool grey of `hairline`,
    /// because it sits on parchment rather than on white.
    static let fieldBorder = Color(red: 0.82, green: 0.80, blue: 0.76)
    static let error = Color(red: 0.91, green: 0.13, blue: 0.15)
    static let disabled = Color(red: 0.62, green: 0.61, blue: 0.59)
}

#Preview {
    SignInView()
}
