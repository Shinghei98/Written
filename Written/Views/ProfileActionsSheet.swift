import SwiftUI

/// The two ways out of somebody's profile, raised by the card's ellipsis.
///
/// **Centred, not an action sheet.** The system's `confirmationDialog` rises
/// from the bottom edge, which on this screen is where the thumb rests and where
/// the tab bar already is — a destructive choice under the finger that was
/// mid-scroll is the wrong place for it. The same dimmed backdrop and card as
/// `BiographicsSheet`, so the app has one idea of what a decision looks like.
///
/// **Two rows, and the order is the point.** Remove is first because it is the
/// common case and the harmless one: most people who want away from a profile
/// have nothing to accuse anyone of. Report is second, in red, and reads as the
/// heavier thing it is. Putting them the other way round would invite a report
/// from somebody who only meant "not for me", and a report is read by a person.
///
/// **Blocking is deliberately absent, and that is a product decision rather than
/// an omission.** It lives in one place — the block list in Settings — because
/// it is the only one of these that can be undone, and a control you can undo
/// wants a place where you can see what you have done. Removing and reporting
/// are decisions about *this* profile taken in the moment; blocking is a list
/// you keep. See `BlockService`.
///
/// **The first row is titled by the caller.** On a stranger it is "Remove"; on
/// somebody you matched with it is "Unmatch", because those are different words
/// for what is, underneath, the same local ban — and a match is a thing you
/// leave rather than a card you take off a pile.
///
/// **Cancel is a card of its own**, separated by a gap. That is what makes it
/// read as "none of these" rather than as a third choice — and it keeps the
/// safe option a clear distance from the destructive one, which is the whole
/// reason iOS action sheets have looked this way for fifteen years.
///
/// The person's name is deliberately absent. It said back what the card behind
/// the sheet already says, and a heading above two buttons is a third thing to
/// read before either can be pressed. It survives in the accessibility hints,
/// where the surrounding card is not available to read.
struct ProfileActionsSheet: View {
    let name: String
    /// "Remove" on a stranger, "Unmatch" on somebody you matched with.
    var removeTitle: String = "Remove"
    let onRemove: () -> Void
    let onReport: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            // **Darker than `BiographicsSheet`'s, and it takes every tap.**
            // That sheet dims to 0.18 and closes when you tap outside, which is
            // right for editing a birthday and wrong here: the feed behind is a
            // scrolling wall of faces, and a decision about one of them should
            // not be dismissible by the same flick that was already in progress.
            //
            // No `onTapGesture`, deliberately — a plain `Color` is hit-testable,
            // so this both dims the feed and makes it unreachable. The way out
            // is Cancel, which is why Cancel is a full-width row of its own
            // rather than a corner glyph.
            GardenPalette.ink.opacity(0.42)
                .ignoresSafeArea()

            // **Two cards, not three rows.** The gap is what makes Cancel read
            // as "none of these" rather than as a third thing you might be
            // choosing — the arrangement every iOS action sheet uses, and the
            // one the reference follows. A Cancel sharing the card with a
            // destructive row is one mis-tap away from being the wrong button.
            VStack(spacing: 10) {
                VStack(spacing: 0) {
                    // No name row. It said back what the card behind it already
                    // says, on a sheet whose whole job is two decisions — and a
                    // heading above two buttons is a third thing to read before
                    // either can be pressed.
                    row(removeTitle, tint: GardenPalette.ink, action: onRemove)
                        .accessibilityHint("Takes \(name) out of your Explore for good")

                    Divider().overlay(GardenPalette.ink.opacity(0.08))

                    row("Report", tint: Self.reportRed, action: onReport)
                        .accessibilityHint("Tells us about \(name), and removes them")
                }
                .background(GardenPalette.card, in: RoundedRectangle(cornerRadius: 20))

                row("Cancel", tint: GardenPalette.ink, action: onCancel)
                    .background(GardenPalette.card, in: RoundedRectangle(cornerRadius: 20))
            }
            .frame(maxWidth: 340)
            .shadow(color: GardenPalette.ink.opacity(0.16), radius: 24, y: 10)
            .padding(.horizontal, 24)
        }
    }

    /// The same red the report sheet and the failure lines use. Named here
    /// rather than reached for inline, so the one destructive colour in the app
    /// has one definition.
    private static let reportRed = Color(red: 0.72, green: 0.18, blue: 0.16)

    /// A full-width row rather than a labelled button: the whole strip answers,
    /// which is what a stacked list of choices has to do — a row that only
    /// responds on its text reads as unreliable rather than as untappable.
    private func row(_ title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                // `.system` semibold rather than `BrandFont`, and that is not a
                // slip: only Quicksand *Regular* is registered, so asking the
                // brand face for weight would synthesise a faux bold — thicker
                // strokes smeared off the regular one, which reads as blurry at
                // this size. The system face has a real semibold, and it is
                // what every other prominent button in the app already uses.
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
