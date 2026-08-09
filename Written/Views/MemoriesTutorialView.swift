import SwiftUI

/// Four pages that teach Memories once, the first time somebody reaches it.
///
/// **A demonstration, not a coach mark.** The three things worth knowing about
/// that page — the list scrolls, an entry can be removed, something missing can
/// be added — were taught by dimming the real page and cutting a hole over the
/// real control. That could not be made safe: the subject of a mark lives in a
/// scroll view, so a fast flick carried it off screen and left a grey page
/// behind, and each fix for that added machinery to a page which was not itself
/// the lesson.
///
/// Here nothing scrolls away. The card below is a fixture — four invented
/// artists, no viewer's data at all — so every page shows the same thing to
/// everybody, and the animations can demonstrate a gesture rather than wait for
/// one. It costs a screen somebody taps through, and buys a sequence that
/// cannot strand anybody and cannot be wrong about what they have connected.
///
/// **Sample names, deliberately.** A real library would make page one honest
/// and pages two to four impossible: the wobble has to be on a particular row,
/// the scroll has to have somewhere to go, and an account with two artists has
/// neither. Fixtures also mean the tutorial reads the same on a phone that has
/// distilled nothing yet, which is exactly when this appears.
struct MemoriesTutorialView: View {

    var onFinish: () -> Void = {}

    @State private var page = 0

    /// The rows the card draws. Four, so there is something to scroll and a
    /// second entry to wobble.
    private static let entries: [(name: String, share: Double)] = [
        ("Fujii Kaze", 1.00),
        ("Ado", 0.82),
        ("King Gnu", 0.61),
        ("Aimyon", 0.44),
    ]

    private static let pages: [String] = [
        "The Memories page shows what we found about you.",
        "Scroll up and down to see all entries.",
        "Long press to remove unwanted entries.",
        "Please add what we missed.",
    ]

    var body: some View {
        ZStack {
            GardenPalette.parchment.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 24)

                Text(Self.pages[page])
                    .font(BrandFont.title(22))
                    .foregroundStyle(GardenPalette.ink)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 32)
                    // Keyed on the page so the sentence changes with a
                    // crossfade rather than reflowing in place, which at two
                    // lines reads as a glitch.
                    .id(page)
                    .transition(.opacity)

                Spacer(minLength: 16)

                card
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)

                Spacer(minLength: 16)

                // **Dots, and no way back.** A tutorial somebody can reverse is
                // a tutorial somebody navigates instead of reads; the dots are
                // there to say how much is left, which is the only thing a
                // reader wants to know.
                HStack(spacing: 6) {
                    ForEach(0..<Self.pages.count, id: \.self) { index in
                        Circle()
                            .fill(GardenPalette.ink.opacity(index == page ? 0.5 : 0.16))
                            .frame(width: 6, height: 6)
                    }
                }
                .padding(.bottom, 18)

                Button(action: next) {
                    // "Continue" throughout, including the last page. The word
                    // says the same thing there — carry on — and a "Done" that
                    // appears only at the end is a label somebody reads once.
                    Text("Continue")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(GardenPalette.parchment)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(GardenPalette.ink, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 32)
                .padding(.bottom, 28)
            }
        }
        .preferredColorScheme(.light)
        .onAppear { restartAnimation(for: page) }
    }

    private func next() {
        guard page < Self.pages.count - 1 else {
            onFinish()
            return
        }
        let upcoming = page + 1
        withAnimation(.easeInOut(duration: 0.25)) { page = upcoming }
        restartAnimation(for: upcoming)
    }

    // MARK: - The card

    /// The same shape as a real Memories card, at a size that fits four rows.
    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: Modality.music.systemImage)
                    .font(.system(size: 12))
                    .foregroundStyle(GardenPalette.gold)
                Text("MUSIC")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(GardenPalette.muted)
                    .tracking(1.2)
            }
            .padding(.bottom, 10)

            Divider().overlay(GardenPalette.ink.opacity(0.08))

            // The window the rows scroll inside. A fixed height so the scroll
            // demonstration has an edge to move against — without one the four
            // rows simply fit and nothing appears to happen.
            VStack(spacing: 0) {
                ForEach(Array(Self.entries.enumerated()), id: \.offset) { index, entry in
                    if index > 0 { Divider().overlay(GardenPalette.ink.opacity(0.06)) }
                    row(entry, isWobbling: page == 2 && index == 1)
                }
            }
            .offset(y: scrollOffset)
            .frame(height: Self.windowHeight, alignment: .top)
            .clipped()

            Divider().overlay(GardenPalette.ink.opacity(0.08))

            placeholder
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(GardenPalette.card, in: RoundedRectangle(cornerRadius: 24))
        .overlay {
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(GardenPalette.ink.opacity(0.06), lineWidth: 1)
        }
        .overlay { if page == 3 { addSheetMock } }
    }

    /// Three rows' worth, so the fourth is off the bottom and the list has
    /// somewhere to go.
    private static let windowHeight: CGFloat = 3 * 46

    private func row(_ entry: (name: String, share: Double), isWobbling: Bool) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 6)
                .fill(GardenPalette.gold.opacity(0.18))
                .frame(width: 30, height: 30)

            Text(entry.name)
                .font(.system(size: 15))
                .foregroundStyle(GardenPalette.ink)
                .lineLimit(1)

            Spacer(minLength: 8)

            Capsule()
                .fill(GardenPalette.gold.opacity(0.75))
                .frame(width: 56 * entry.share, height: 5)
        }
        .frame(height: 46)
        .rotationEffect(.degrees(isWobbling ? wobble : 0), anchor: .center)
        .overlay(alignment: .topTrailing) {
            if isWobbling {
                // The same badge the real page draws, at the same corner.
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(GardenPalette.card)
                    .frame(width: 20, height: 20)
                    .background(GardenPalette.ink.opacity(0.75), in: Circle())
                    .overlay { Circle().strokeBorder(GardenPalette.card, lineWidth: 1.5) }
                    .offset(x: 6, y: -2)
                    .transition(.scale.combined(with: .opacity))
            }
        }
    }

    /// The circle-and-cross, pressed on the last page.
    private var placeholder: some View {
        Image(systemName: "plus.circle")
            .font(.system(size: 24, weight: .light))
            .foregroundStyle(page == 3 ? GardenPalette.ink : GardenPalette.muted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .scaleEffect(page == 3 ? 0.88 : 1)
            .animation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true), value: page == 3)
    }

    /// What tapping it opens, drawn rather than presented: a real sheet would
    /// need dismissing, and this page is a demonstration nobody has to operate.
    private var addSheetMock: some View {
        VStack(spacing: 10) {
            Text("What did we miss?")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(GardenPalette.ink)
            RoundedRectangle(cornerRadius: 10)
                .fill(GardenPalette.parchment)
                .frame(height: 34)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(GardenPalette.ink.opacity(0.35))
                        .frame(width: 1, height: 16)
                        .padding(.leading, 12)
                        .opacity(caretVisible ? 1 : 0)
                }
        }
        .padding(14)
        .background(GardenPalette.card, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
        .padding(.horizontal, 18)
        .transition(.scale(scale: 0.92).combined(with: .opacity))
    }

    // MARK: - The animations

    @State private var scrollOffset: CGFloat = 0
    @State private var wobble: Double = 0
    @State private var caretVisible = false

    /// Each page drives exactly one of these, and the others are put back.
    ///
    /// **Started by hand rather than by `onAppear` on each page**, because all
    /// four pages are one view: the card never leaves the screen, so there is
    /// no appearance to hang an animation on. Restarting on the page index is
    /// the only signal there is.
    private func restartAnimation(for page: Int) {
        withAnimation(.easeInOut(duration: 0.2)) {
            scrollOffset = 0
            wobble = 0
            caretVisible = false
        }

        switch page {
        case 1:
            // Slow, and the whole travel: the point is that there is more below
            // rather than that the list can move.
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                scrollOffset = -(46 * CGFloat(Self.entries.count) - Self.windowHeight)
            }
        case 2:
            withAnimation(.easeInOut(duration: 0.16).repeatForever(autoreverses: true)) {
                wobble = 1.1
            }
        case 3:
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                caretVisible = true
            }
        default:
            break
        }
    }
}
