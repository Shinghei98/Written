import SwiftUI

/// A single-value bar whose label rides above the thumb.
///
/// **The label tracks the dot rather than sitting in a fixed place**, which is
/// the whole reason this is not `Slider`. A number pinned to the top of the
/// screen makes the reader look in two places at once; a number over the thumb
/// is read with the same glance as the position.
///
/// Laid out with `GeometryReader` and an offset rather than an overlay on the
/// thumb, because `Slider` does not expose its thumb frame.
struct SyncedSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let label: (Double) -> String

    private static let thumb: CGFloat = 24

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geometry in
                let span = max(geometry.size.width - Self.thumb, 1)
                let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)

                ZStack(alignment: .topLeading) {
                    Text(label(value))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(GardenPalette.ink)
                        .fixedSize()
                        // Centred on the thumb, then clamped inside the track so
                        // the two extremes do not hang off the edge of the card.
                        .frame(width: 90)
                        .offset(x: min(max(fraction * span + Self.thumb / 2 - 45, -12), geometry.size.width - 78))
                }
            }
            .frame(height: 22)

            GeometryReader { geometry in
                let span = max(geometry.size.width - Self.thumb, 1)
                let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(GardenPalette.unreadBand)
                        .frame(height: 4)

                    Capsule()
                        .fill(GardenPalette.gold.opacity(0.65))
                        .frame(width: fraction * span + Self.thumb / 2, height: 4)

                    Circle()
                        .fill(GardenPalette.gold)
                        .frame(width: Self.thumb, height: Self.thumb)
                        .offset(x: fraction * span)
                }
                .frame(height: Self.thumb)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            let x = min(max(drag.location.x - Self.thumb / 2, 0), span)
                            value = range.lowerBound + (x / span) * (range.upperBound - range.lowerBound)
                        }
                )
            }
            .frame(height: Self.thumb)
        }
    }
}

/// Two thumbs on one track.
///
/// **Whichever thumb is nearer the finger is the one that moves**, rather than
/// a fixed "drag the left one first" rule — with both ends at the same value a
/// fixed rule strands the range and it can never be reopened.
///
/// The two are kept at least one step apart so the range never inverts, which
/// would otherwise render as a filled bar of negative width.
struct RangeSlider: View {
    @Binding var low: Double
    @Binding var high: Double
    let range: ClosedRange<Double>

    @State private var dragging: Thumb?

    enum Thumb { case low, high }

    private static let thumb: CGFloat = 24

    var body: some View {
        GeometryReader { geometry in
            let span = max(geometry.size.width - Self.thumb, 1)
            let lowFraction = fraction(low)
            let highFraction = fraction(high)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(GardenPalette.unreadBand)
                    .frame(height: 4)

                Capsule()
                    .fill(GardenPalette.gold.opacity(0.65))
                    .frame(width: max((highFraction - lowFraction) * span, 0), height: 4)
                    .offset(x: lowFraction * span + Self.thumb / 2)

                Circle()
                    .fill(GardenPalette.gold)
                    .frame(width: Self.thumb, height: Self.thumb)
                    .offset(x: lowFraction * span)

                Circle()
                    .fill(GardenPalette.gold)
                    .frame(width: Self.thumb, height: Self.thumb)
                    .offset(x: highFraction * span)
            }
            .frame(height: Self.thumb)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let x = min(max(drag.location.x - Self.thumb / 2, 0), span)
                        let touched = range.lowerBound + (x / span) * (range.upperBound - range.lowerBound)

                        if dragging == nil {
                            dragging = abs(touched - low) <= abs(touched - high) ? .low : .high
                        }
                        if dragging == .low {
                            low = min(touched, high - 1)
                        } else {
                            high = max(touched, low + 1)
                        }
                    }
                    .onEnded { _ in dragging = nil }
            )
        }
        .frame(height: Self.thumb)
    }

    private func fraction(_ value: Double) -> Double {
        (value - range.lowerBound) / (range.upperBound - range.lowerBound)
    }
}
