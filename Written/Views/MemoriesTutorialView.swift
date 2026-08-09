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
    /// **Invented covers, not borrowed ones.** The real page draws artwork
    /// Apple Music supplied; a fixture cannot, and shipping somebody's sleeve
    /// as decoration is a licence question nobody needs for a tutorial. Two
    /// tones and a note read as a record at 30 points, which is all this has to
    /// do — the row is recognisable by its shape, not by whose album it is.
    private static let entries: [(name: String, share: Double, top: Color, bottom: Color)] = [
        ("Fujii Kaze", 1.00, Color(red: 0.85, green: 0.53, blue: 0.36), Color(red: 0.51, green: 0.26, blue: 0.26)),
        ("Ado",        0.82, Color(red: 0.37, green: 0.42, blue: 0.68), Color(red: 0.19, green: 0.20, blue: 0.36)),
        ("King Gnu",   0.61, Color(red: 0.45, green: 0.60, blue: 0.45), Color(red: 0.22, green: 0.33, blue: 0.27)),
        ("Aimyon",     0.44, Color(red: 0.80, green: 0.70, blue: 0.40), Color(red: 0.45, green: 0.37, blue: 0.22)),
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
                    // **Swipe the card to move between pages.** Continue is
                    // still the obvious way through; this is for the hand that
                    // has just been shown three gestures and reaches for a
                    // fourth. Backwards as well as forwards, unlike the button
                    // — a reader who wants the previous page has a reason, and
                    // the dots already say where they are.
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 24)
                            .onEnded { value in
                                guard abs(value.translation.width) > abs(value.translation.height)
                                else { return }
                                go(value.translation.width < 0 ? 1 : -1)
                            }
                    )

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
        .overlay { if page == 3 { addSheetMock } }
        .preferredColorScheme(.light)
        .onAppear { restartAnimation(for: page) }
    }

    private func next() {
        guard page < Self.pages.count - 1 else {
            onFinish()
            return
        }
        go(1)
    }

    /// Move by one page, or do nothing at the ends.
    ///
    /// A swipe past the last page does **not** finish the tutorial: leaving is
    /// a decision, and a flick is not one. Continue is the only way out.
    private func go(_ delta: Int) {
        let upcoming = page + delta
        guard Self.pages.indices.contains(upcoming) else { return }
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
    }

    /// Three rows' worth, so the fourth is off the bottom and the list has
    /// somewhere to go.
    private static let windowHeight: CGFloat = 3 * 46

    private func row(
        _ entry: (name: String, share: Double, top: Color, bottom: Color),
        isWobbling: Bool
    ) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 6)
                .fill(LinearGradient(colors: [entry.top, entry.bottom],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 34, height: 34)
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }

            Text(entry.name)
                .font(.system(size: 15))
                .foregroundStyle(GardenPalette.ink)
                .lineLimit(1)

            Spacer(minLength: 8)

            Capsule()
                .fill(GardenPalette.gold.opacity(0.75))
                .frame(width: 56 * entry.share, height: 5)
        }
        // Room for the cross, which hangs past this row's trailing corner and
        // was being cut in half by the card's clip — the same overhang the real
        // page reserves for in `entryStack`.
        .padding(.trailing, 14)
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
                    .offset(x: 8, y: -1)
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

    /// What tapping it opens, drawn rather than presented.
    ///
    /// **Matched to `BiographicsSheet` line for line** — the dim behind it, the
    /// 22-point card, the title in `BrandFont.body(18)`, the subtitle beneath,
    /// the field, and a Save that is disabled because nothing has been typed.
    /// A tutorial that shows a dialog somebody will not recognise when they
    /// meet it has taught them the wrong thing, and the first version was a
    /// small white box clipped inside the card.
    ///
    /// Over the whole page rather than inside the card, because that is where
    /// the real one appears: it is a decision about the page, not part of a
    /// section.
    private var addSheetMock: some View {
        ZStack {
            GardenPalette.ink.opacity(0.28)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                VStack(spacing: 4) {
                    Text("What did we miss?")
                        .font(BrandFont.body(18))
                        .foregroundStyle(GardenPalette.ink)
                    Text("Tell us what we missed.")
                        .font(BrandFont.body(13))
                        .foregroundStyle(GardenPalette.muted)
                }

                RoundedRectangle(cornerRadius: 12)
                    .fill(GardenPalette.parchment)
                    .frame(height: 44)
                    .overlay {
                        HStack(spacing: 0) {
                            // The caret, blinking where one would be.
                            Capsule()
                                .fill(Color.blue)
                                .frame(width: 2, height: 20)
                                .opacity(caretVisible ? 1 : 0)
                            Text("Artist")
                                .font(BrandFont.body(15))
                                .foregroundStyle(GardenPalette.muted.opacity(0.7))
                        }
                    }

                Text("Save")
                    .font(BrandFont.body(15))
                    .foregroundStyle(GardenPalette.parchment)
                    .padding(.horizontal, 34)
                    .padding(.vertical, 11)
                    .background(GardenPalette.gold, in: Capsule())
                    // Disabled, as it is until somebody types — the state this
                    // dialog is actually in when it opens.
                    .opacity(0.45)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 20)
            .background(GardenPalette.card, in: RoundedRectangle(cornerRadius: 22))
            .overlay {
                RoundedRectangle(cornerRadius: 22)
                    .strokeBorder(GardenPalette.ink.opacity(0.08), lineWidth: 1)
            }
            .shadow(color: GardenPalette.ink.opacity(0.18), radius: 22, y: 10)
            .padding(.horizontal, 28)
        }
        .transition(.opacity)
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
