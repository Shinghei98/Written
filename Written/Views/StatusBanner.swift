import SwiftUI

/// A line across the top saying something is wrong.
///
/// One component rather than a sixth bespoke error label. Five screens already
/// roll their own — `NameEntryView`, `PhoneNumberView`, `BiographicsSheets`,
/// `GrowProfileView`, `ConversationView` — each a `Text` in `SignInPalette.error`
/// under the field it belongs to. Those are right where they are: they explain a
/// *form*. This is for the other kind, the failure with no field to sit under —
/// a like that would not save, a feed that could not refresh.
///
/// **It overlays and takes no layout height, and that is not a style choice.**
/// CLAUDE.md records that anything consuming height moves the plant, a
/// regression this project has paid for four times, and `promptsReserve` is
/// measured against a garden that must not shift because a banner appeared.
struct StatusBanner: View {
    let message: String
    var isWarning = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isWarning ? "wifi.slash" : "exclamationmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .foregroundStyle(GardenPalette.card)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            // Ink rather than red for the offline case: being on a plane is not
            // an error, it is a circumstance. A refused action gets the red.
            (isWarning ? GardenPalette.ink.opacity(0.88) : SignInPalette.error),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        .padding(.horizontal, 14)
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityElement(children: .combine)
    }
}

/// Attaches a banner to a screen without it costing any height.
///
/// `overlay(alignment: .top)`, never `safeAreaInset`. The inset form is the one
/// that reads more naturally and is exactly the one that would move the garden.
extension View {
    func statusBanner(_ message: String?, isWarning: Bool = false) -> some View {
        overlay(alignment: .top) {
            if let message {
                StatusBanner(message: message, isWarning: isWarning)
                    // Clear of the status bar and any pinned header beneath it.
                    .padding(.top, 6)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: message)
    }
}
