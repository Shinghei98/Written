import SwiftUI

/// A note to send with an invitation.
///
/// The second way to like somebody: the heart says only that, this says
/// something. It rides on the like rather than becoming a message, because
/// there is no conversation yet — one exists only once a like has been
/// accepted, and this is what is meant to persuade somebody to accept it.
///
/// `BiographicsSheet` again, as `ReportSheet` does: a title, a subtitle, a field
/// and a named confirm is exactly its shape, and a fourth hand-rolled sheet
/// would be a fourth place for the app's idea of a decision to drift.
struct LikeMessageSheet: View {
    let name: String
    let onSend: (String) -> Void
    let onCancel: () -> Void

    @State private var text = ""
    @FocusState private var isFocused: Bool

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        BiographicsSheet(
            title: "Send \(name) a message!",
            subtitle: "Including a message in your invitation puts you on top of the stack.",
            // **Nothing to send is not a send.** An empty confirm would write a
            // plain like wearing the clothes of a written one, which is worse
            // than the heart the card already offers — and the column refuses an
            // empty string anyway, so the alternative is a refusal explained
            // after the fact.
            confirmEnabled: !trimmed.isEmpty,
            // Matching `ProfileActionsSheet`: the same feed is behind it, and it
            // wants the same distance.
            dim: 0.42,
            confirmTitle: "Send",
            onConfirm: { onSend(trimmed) },
            onCancel: onCancel
        ) {
            TextField("Say something", text: $text, axis: .vertical)
                .font(BrandFont.body(15))
                .foregroundStyle(GardenPalette.ink)
                .lineLimit(3...6)
                .focused($isFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(SignInPalette.field, in: RoundedRectangle(cornerRadius: 14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(SignInPalette.fieldBorder, lineWidth: 1)
                }
        }
        // The keyboard, without waiting to be asked. This sheet exists only to
        // be typed into — the same reason `VerificationCodeView` takes focus,
        // and the same delay, because focus requested mid-presentation is
        // silently dropped.
        .task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            isFocused = true
        }
    }
}
