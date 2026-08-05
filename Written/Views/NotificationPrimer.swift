import SwiftUI

/// Asks, in the app's own voice, before iOS asks in its own.
///
/// **iOS allows the question once, ever.** A refusal can only be undone in
/// Settings, which nobody visits — so a system dialog shown cold spends the only
/// attempt this app will ever have, and one distracted tap on "Don't Allow" ends
/// notifications permanently for that account.
///
/// So this comes first and the system dialog is shown only to somebody who has
/// already said yes here. A "not now" costs nothing: nothing is spent, and the
/// question can be put again on another day.
///
/// **It says what arrives rather than asking to be allowed.** "Enable
/// notifications" describes a switch; three lines naming a like, a match and a
/// message describe what somebody would miss — which is the actual argument,
/// and the only one available in the seconds before iOS takes the screen.
///
/// `BiographicsSheet` again, as `ReportSheet` and `LikeMessageSheet` do: a
/// title, a subtitle, some content and two named buttons is exactly its shape,
/// and a fourth hand-rolled sheet would be a fourth place for this app's idea of
/// a decision to drift.
struct NotificationPrimer: View {
    let onAllow: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        BiographicsSheet(
            title: "Know when someone answers",
            subtitle: "Written can tell you the moment it happens. Nothing else.",
            // Matching `ProfileActionsSheet` and `LikeMessageSheet`: this arrives
            // over the feed, and it should sit at the same distance from it as
            // everything else that interrupts it.
            dim: 0.42,
            confirmTitle: "Turn on",
            onConfirm: onAllow,
            onCancel: onDismiss
        ) {
            VStack(alignment: .leading, spacing: 14) {
                line("heart.fill", "Someone likes you")
                line("sparkles", "Someone you invited says yes")
                line("envelope.fill", "A new message")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
        }
    }

    /// The glyph carries the meaning and the gold carries the tone — the same
    /// gold the garden's badges, the unread count and "Say something" use, so
    /// this reads as the app's own colour for *there is something here for you*
    /// rather than as an alert.
    private func line(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(GardenPalette.badgeGold)
                // Fixed, so three glyphs of different widths leave their labels
                // on one left edge.
                .frame(width: 22, alignment: .center)
            Text(text)
                .font(BrandFont.body(15))
                .foregroundStyle(GardenPalette.ink)
        }
    }
}
