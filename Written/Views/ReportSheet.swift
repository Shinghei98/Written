import SwiftUI

/// Telling us about somebody.
///
/// **Submitting is what blocks them, not opening this.** Unmatch confirms in an
/// alert and this does not, because the sheet *is* the confirmation — a form
/// you have to write in and send is not something a stray thumb completes. The
/// corollary is that backing out backs all the way out: swiping to Report and
/// then cancelling leaves them exactly where they were, which is what somebody
/// who changed their mind means.
struct ReportSheet: View {
    let name: String
    let onSend: (String) -> Void
    let onCancel: () -> Void

    @State private var text = ""
    @FocusState private var isFocused: Bool

    // **This sheet names no second channel, and that is the deliberate half of
    // it.** It carried a phone number through development —
    // `+1 (555) 010-0199`, the reserved fictional range — and the placeholder
    // was caught on the way into build 9 rather than by a tester dialling it.
    // A safety sheet naming a line that rings nowhere is worse than one naming
    // none: it converts "we could not reach anyone" into "they gave us a fake
    // number", which is a different and much worse thing to have done. So the
    // form is the whole of it until there is a channel that actually answers,
    // and adding one back is a one-line change to the subtitle below.

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        BiographicsSheet(
            title: "We take safety very seriously",
            subtitle: "Every report is read by a person, and this one stays "
                + "between you and us. Tell us what happened.",
            confirmEnabled: !trimmed.isEmpty,
            // Matches `ProfileActionsSheet`, which is one of the two things that
            // raises this — handing over between them must not look like the
            // page lighting up.
            dim: 0.42,
            confirmTitle: "Report",
            onConfirm: { onSend(trimmed) },
            onCancel: onCancel
        ) {
            TextField("What happened?", text: $text, axis: .vertical)
                .font(BrandFont.body(15))
                .foregroundStyle(GardenPalette.ink)
                // Left-aligned, unlike the biographics rows. Those take a word;
                // this takes an account of something, and centred prose is
                // harder to read the longer it gets.
                .multilineTextAlignment(.leading)
                .lineLimit(4...8)
                .focused($isFocused)
                .padding(.vertical, 11)
                .padding(.horizontal, 14)
                .background(GardenPalette.parchment, in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(GardenPalette.ink.opacity(0.08), lineWidth: 1)
                }
        }
        .onAppear { isFocused = true }
    }
}
