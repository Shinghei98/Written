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
struct ProfileActionsSheet: View {
    let name: String
    let onRemove: () -> Void
    let onReport: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            GardenPalette.ink.opacity(0.18)
                .ignoresSafeArea()
                // Tapping away is a way out. It cancels rather than choosing,
                // which is the only safe reading of a tap that landed outside
                // two buttons, one of which accuses somebody.
                .onTapGesture(perform: onCancel)

            VStack(spacing: 0) {
                Text(name)
                    .font(BrandFont.body(15))
                    .foregroundStyle(GardenPalette.muted)
                    .lineLimit(1)
                    .padding(.horizontal, 22)
                    .padding(.top, 18)
                    .padding(.bottom, 14)

                Divider().overlay(GardenPalette.ink.opacity(0.08))

                row("Remove", tint: GardenPalette.ink, action: onRemove)
                    .accessibilityHint("Takes \(name) out of your Explore for good")

                Divider().overlay(GardenPalette.ink.opacity(0.08))

                row("Report", tint: Self.reportRed, action: onReport)
                    .accessibilityHint("Tells us about \(name), and removes them")
            }
            .frame(maxWidth: 280)
            .background(GardenPalette.card, in: RoundedRectangle(cornerRadius: 22))
            .overlay {
                RoundedRectangle(cornerRadius: 22)
                    .strokeBorder(GardenPalette.ink.opacity(0.06), lineWidth: 1)
            }
            .shadow(color: GardenPalette.ink.opacity(0.18), radius: 24, y: 10)
            .padding(.horizontal, 40)
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
                .font(BrandFont.body(17))
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
