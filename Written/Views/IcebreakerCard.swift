import SwiftUI

/// What two people who just matched have in common, at the top of the thread.
///
/// > You two both listen to J-Pop. You can talk about Ado, or ask them about
/// > Fujii Kaze!
///
/// **The sentence is different for each of them**, and that is the whole point
/// — the first specific is the reader's own and the second is the partner's, so
/// the version one person sees must never be shown to the other. That is why it
/// is drawn rather than stored as a message: `messages` is read by both
/// participants, so one row could only ever carry a neutral sentence, and
/// `sender_id` is `not null` besides, so a system message has no sender to
/// write it as. `0036` stores the ingredients and
/// `ChatService.conversation(from:me:)` turns them the right way round.
///
/// **This is where the language lives, and the split is deliberate.** The
/// trigger does set intersection and knows nothing about English; the verb
/// belongs to the theme's kind and belongs here, for the same reason
/// `Ontology.line(for:subject:)` is in Swift rather than in SQL. A schema is a
/// poor place to keep prose, and copy that has to be changed by a migration
/// will not be changed.
struct IcebreakerCard: View {

    let icebreaker: ChatService.Icebreaker

    var body: some View {
        // **`DayDivider`'s treatment, deliberately** — the same card fill, the
        // same hairline, the same shadow, and a rounded rectangle rather than a
        // capsule only because this runs to several lines and a capsule's ends
        // would bow around a paragraph.
        //
        // Borrowing that look is the point rather than a shortcut. A day pill is
        // the one thing already in this thread that is *about* the conversation
        // instead of part of it — nobody reads "Yesterday" as something the
        // other person said — so matching it puts the icebreaker in the
        // category it belongs to without needing a label to explain that. It
        // must never read as a bubble.
        (
            Text("Tips: ").font(.system(size: 12, weight: .semibold))
            + Text(sentence).font(.system(size: 12, weight: .medium))
        )
        .foregroundStyle(GardenPalette.muted)
        .lineSpacing(2)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(GardenPalette.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(GardenPalette.ink.opacity(0.06), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
        // Kept off the full width. A day pill hugs two words and this hugs a
        // sentence, but neither should reach the bubbles' own margins — a box
        // the width of the thread reads as a message again.
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        // **One utterance to VoiceOver**, not two runs. The label is a sentence
        // and reads as one; assembling it from the parts announces the colon.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tips: " + sentence)
    }

    private var sentence: String {
        let opening = "You two both \(verb) \(icebreaker.theme)."

        // **The same subject on both sides is an ordinary outcome**, not a bug:
        // the sport and creator branches set both to the shared thing, because
        // there is nothing more specific to say. Repeating it — "talk about
        // tennis, or ask them about tennis" — would read as a broken template,
        // so the sentence collapses to the half that still means something.
        guard icebreaker.mine.caseInsensitiveCompare(icebreaker.theirs) != .orderedSame else {
            return opening + " Ask \(icebreaker.partnerPronoun) about \(icebreaker.mine)!"
        }

        return opening
            + " You can talk about \(icebreaker.mine),"
            + " or ask \(icebreaker.partnerPronoun) about \(icebreaker.theirs)!"
    }

    /// The verb the theme takes.
    ///
    /// Unknown kinds fall through to "are into", which is deliberately vague
    /// and always grammatical — a kind added to `0036` and not here should read
    /// slightly flat rather than produce "You two both  tennis."
    private var verb: String {
        switch icebreaker.kind {
        case "music_genre": return "listen to"
        case "sport": return "play"
        default: return "are into"
        }
    }
}

#Preview("Genre") {
    ZStack {
        GardenPalette.parchment.ignoresSafeArea()
        IcebreakerCard(icebreaker: .init(
            theme: "J-Pop", kind: "music_genre",
            mine: "Ado", theirs: "Fujii Kaze", partnerPronoun: "her"
        ))
    }
}

#Preview("Sport, one subject") {
    ZStack {
        GardenPalette.parchment.ignoresSafeArea()
        IcebreakerCard(icebreaker: .init(
            theme: "tennis", kind: "sport",
            mine: "tennis", theirs: "tennis", partnerPronoun: "them"
        ))
    }
}
