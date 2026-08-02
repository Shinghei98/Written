import SwiftUI

/// The dial on the flirt-level card: a ring of ticks, open at the bottom, with
/// one bold mark where the answer sits and the word for it in the middle.
///
/// Modelled on the pressure gauge in Apple's Weather app, which is the right
/// reference for a reason worth keeping: it shows a *position on a range* rather
/// than a quantity. There is no unit here and no arithmetic to do — "Flirty" is
/// only meaningful relative to "Platonic" and "Freaky" on either side of it, and
/// a dial is the one chart that says so without a legend.
///
/// **It owns its own captions**, unlike every other card here, because "the legs
/// stand above Low and High" is one geometric statement and splitting it across
/// two views is how the two drift apart. Both the arc's ends and the two words
/// are placed from the same width.
struct FlirtGauge: View {

    /// Where the mark sits, 0 at the low leg and 1 at the high one.
    let fraction: Double
    /// The band's own word — "Platonic" through "Freaky".
    let word: String

    /// Diameter as a fraction of the card's width.
    ///
    /// Between the two versions that were wrong: 54% read as a token sitting in
    /// a card rather than as the card's subject, and the reference's own 74%
    /// (411px of 555) was overbearing on a card half a phone wide — the
    /// reference is a full-width card and does not have to share its row.
    static let diameterRatio: Double = 0.60

    /// Thirds. The bottom of the card divides 0-1-2-3, the captions sit at 1 and
    /// 2, and the arc opens exactly wide enough to stand on them.
    ///
    /// Note this is **not** what the reference does — its legs are at ±29% of
    /// the card width while its captions are at ±17%, so the arc oversails them.
    /// Aligning the two was asked for, and it is what sets the opening angle:
    /// the gap is no longer a free choice, and shrinking the dial *widens* it,
    /// because the legs have to reach the same two points from a smaller circle.
    static let legFraction: Double = 1.0 / 3.0

    /// Half the bottom opening, in radians, derived from the leg positions.
    static var halfOpening: Double {
        let r = diameterRatio / 2
        return asin(min(1, (0.5 - legFraction) / r))
    }

    /// The arc's height as a fraction of its width: a full radius above centre,
    /// and only `cos(halfOpening)` below it.
    private static var arcHeightRatio: Double {
        (diameterRatio / 2) * (1 + cos(halfOpening))
    }

    /// Room for the captions, in points rather than as a ratio — the text does
    /// not scale with the card, so neither should the space kept for it.
    private static let captionHeight: CGFloat = 15
    private static let captionGap: CGFloat = 7

    private let tickCount = 48

    var body: some View {
        // A stack rather than one box with the captions `position`ed inside it.
        //
        // They used to be placed below the arc by absolute offset, which put
        // them past the bottom of this view's own frame — so they hung into the
        // card's bottom padding and left no gap under them at all. Laid out as a
        // row, they take their own height and the card's padding does its job.
        VStack(spacing: Self.captionGap) {
            dial
            captions
        }
        .accessibilityElement()
        .accessibilityLabel("Flirt level")
        .accessibilityValue(word)
    }

    private var dial: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let radius = w * Self.diameterRatio / 2
            // Top of the circle at the top of the box, so the ring is not
            // floating in whatever space the caller happened to give it.
            let centre = CGPoint(x: w / 2, y: radius)

            ZStack(alignment: .topLeading) {
                ForEach(0..<tickCount, id: \.self) { index in
                    let t = Double(index) / Double(tickCount - 1)
                    tick(at: t, centre: centre, radius: radius)
                }

                // The reading, drawn last so it sits over the ticks rather than
                // being interrupted by them. Fixed size and the system face,
                // matching `chronotype.label` on the card beside it — a value
                // scaled off the dial's radius grew with the dial and read as a
                // headline rather than as the same kind of reading.
                Text(word)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(GardenPalette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: radius * 1.5)
                    .position(centre)
            }
            .frame(width: w, height: proxy.size.height, alignment: .topLeading)
        }
        .aspectRatio(1 / Self.arcHeightRatio, contentMode: .fit)
    }

    /// `Low` and `High`, directly under the two ends of the arc.
    private var captions: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                caption("Low")
                    .position(x: proxy.size.width * CGFloat(Self.legFraction),
                              y: proxy.size.height / 2)
                caption("High")
                    .position(x: proxy.size.width * CGFloat(1 - Self.legFraction),
                              y: proxy.size.height / 2)
            }
        }
        .frame(height: Self.captionHeight)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(GardenPalette.muted)
            .fixedSize()
    }

    private func tick(at t: Double, centre: CGPoint, radius: CGFloat) -> some View {
        // The nearest tick to the answer is the marker. Comparing distance in
        // `t` rather than testing equality means the mark lands on a real tick
        // at any `fraction`, instead of vanishing between two of them.
        let step = 1.0 / Double(tickCount - 1)
        let isMark = abs(t - fraction) < step / 2

        // Proportional, so the dial keeps its look at any card width.
        let length: CGFloat = radius * (isMark ? 0.24 : 0.16)
        let width: CGFloat = isMark ? 4 : 2

        // Straight down is 90°, and clockwise is increasing, so the low leg sits
        // at 90 + halfOpening and the sweep is whatever is left of the circle.
        let halfOpening = Angle(radians: Self.halfOpening).degrees
        let start = 90 + halfOpening
        let sweep = 360 - 2 * halfOpening
        let angle = Angle.degrees(start + t * sweep)

        return Capsule()
            .fill(
                isMark
                    ? GardenPalette.ink
                    : GardenPalette.badgeGold.opacity(0.30)
            )
            .frame(width: width, height: length)
            // Rotate first, then push outward along the rotated axis: the
            // capsule has to point at the centre, and offsetting before the
            // rotation would swing it around the wrong pivot.
            .offset(y: -(radius - length / 2 - 1))
            .rotationEffect(angle + .degrees(90))
            .position(centre)
    }
}

/// Two hearts, one behind the other.
///
/// SF Symbols has no overlapping pair, and a single `heart.fill` already means
/// *like* everywhere else in this app — on the discovery feed it is the control
/// that sends one. Reusing it as a section label would be the same mistake as
/// `sailboat` standing in for a message in a bottle.
struct OverlappingHearts: View {
    var body: some View {
        ZStack {
            Image(systemName: "heart.fill")
                .font(.system(size: 10, weight: .medium))
                .offset(x: -3)
                // The back heart is lightened rather than outlined, so the two
                // read as overlapping instead of as one blurred shape at the
                // 12pt this is actually drawn at.
                .opacity(0.45)

            Image(systemName: "heart.fill")
                .font(.system(size: 10, weight: .medium))
                .offset(x: 3)
        }
        .frame(width: 16)
    }
}

#Preview {
    VStack(spacing: 16) {
        ForEach(FlirtLevel.allCases, id: \.self) { level in
            FlirtGauge(fraction: level.fraction, word: level.word)
                .frame(width: 169)
        }
    }
    .padding()
    .background(GardenPalette.parchment)
}
