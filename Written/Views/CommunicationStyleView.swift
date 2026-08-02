import SwiftUI

/// Onboarding, straight after the name: how the user wants to be approached.
///
/// It sits here rather than on the dashboard because both answers are
/// *boundaries*, and a boundary set after the fact has already failed at its
/// job. Asking before anyone can message them is the whole point.
///
/// Neither slider can be left unanswered — both start mid-bar, which is a real
/// answer rather than a refusal, so there is no invalid state and the Continue
/// button never needs disabling. Compare `NameEntryView`, where an empty first
/// name genuinely is a missing answer and is reported on the field.
struct CommunicationStyleView: View {

    var onContinue: (CommunicationStyle) -> Void = { _ in }

    @State private var flirt: Double
    @State private var response: Double

    init(
        initial: CommunicationStyle = .unset,
        onContinue: @escaping (CommunicationStyle) -> Void = { _ in }
    ) {
        self.onContinue = onContinue
        _flirt = State(initialValue: initial.flirtPosition)
        _response = State(initialValue: initial.responsePosition)
    }

    var body: some View {
        ZStack {
            GardenPalette.parchment.ignoresSafeArea()

            VStack(spacing: 0) {
                Text("What's your communication style?")
                    .font(BrandFont.title(32))
                    .foregroundStyle(SignInPalette.ink)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.top, 70)

                Text("Make your boundaries clear.")
                    .font(.system(size: 16))
                    .foregroundStyle(SignInPalette.muted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .padding(.horizontal, 28)
                    .padding(.top, 14)

                slider(
                    title: "Flirt level",
                    low: "Low",
                    high: "High",
                    reading: FlirtLevel(fraction: flirt).word,
                    value: $flirt
                )
                .padding(.horizontal, 28)
                .padding(.top, 40)

                slider(
                    title: "Response time",
                    low: "Slow",
                    high: "Quick",
                    reading: ResponseTime(fraction: response).rawValue,
                    value: $response
                )
                .padding(.horizontal, 28)
                // Twice the gap under the first bar. The two questions are
                // independent, and at 34 the second title sat close enough to
                // the first bar's "Low / High" to read as part of it.
                .padding(.top, 68)

                Spacer(minLength: 24)

                Button("Continue") {
                    onContinue(
                        CommunicationStyle(
                            flirt: FlirtLevel(fraction: flirt),
                            response: ResponseTime(fraction: response),
                            flirtPosition: flirt,
                            responsePosition: response
                        )
                    )
                }
                .buttonStyle(PressShrinkButtonStyle())
                .frame(width: 176)
                .padding(.bottom, 12)
            }
        }
        .preferredColorScheme(.light)
    }

    /// A titled bar with its two ends named, and the band it currently reads.
    ///
    /// The reading is shown even though only the ends are labelled: the bar is
    /// continuous under the finger but the answer is one of four, and without
    /// naming it there is no way to tell that nudging the thumb a little did
    /// nothing — or that nudging it a little further changed the answer.
    private func slider(
        title: String,
        low: String,
        high: String,
        reading: String,
        value: Binding<Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(SignInPalette.ink)

                Spacer(minLength: 8)

                Text(reading)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(GardenPalette.badgeGold)
                    // The word changes as the thumb crosses a boundary, and a
                    // hard swap reads as a glitch at that speed.
                    .animation(.easeOut(duration: 0.15), value: reading)
            }

            WedgeSlider(position: value, accessibilityLabel: title, reading: reading)

            HStack {
                Text(low)
                Spacer(minLength: 8)
                Text(high)
            }
            .font(.system(size: 13))
            .foregroundStyle(SignInPalette.muted)
        }
    }
}

/// The bar itself: a gold wedge, sharp and faint at the low end, thick and solid
/// at the high one, with a black disc riding along it.
///
/// The taper is the whole control. A uniform track would need its labels read to
/// know which way is "more"; a wedge says it before anything is read, and says
/// it the same way for someone who cannot see the labels at all.
struct WedgeSlider: View {

    @Binding var position: Double

    var accessibilityLabel: String = ""
    var reading: String = ""

    /// Big enough to hit without covering the wedge it sits on.
    private let thumb: CGFloat = 26
    private let trackHeight: CGFloat = 30

    var body: some View {
        GeometryReader { proxy in
            // The thumb's centre can only reach its own radius from each edge,
            // so the travel is shorter than the bar. Positions are a fraction of
            // *travel*, not of width, or the ends would be unreachable and a
            // reading of `Low` impossible to set.
            let radius = thumb / 2
            let travel = max(1, proxy.size.width - thumb)
            let x = radius + CGFloat(position.clamped()) * travel

            ZStack(alignment: .leading) {
                WedgeTrack()
                    .fill(
                        LinearGradient(
                            colors: [
                                GardenPalette.badgeGold.opacity(0.18),
                                GardenPalette.badgeGold,
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(height: trackHeight)

                Circle()
                    .fill(GardenPalette.ink)
                    .frame(width: thumb, height: thumb)
                    .shadow(color: .black.opacity(0.22), radius: 4, y: 2)
                    .offset(x: x - radius)
            }
            .frame(height: trackHeight)
            // The whole bar, not just the disc: dragging a 26pt target is
            // fiddly, and tapping anywhere on a slider is expected to move it.
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        position = Double((drag.location.x - radius) / travel).clamped()
                    }
            )
        }
        .frame(height: trackHeight)
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(reading)
        // VoiceOver cannot drag. Without this the answer is unreachable rather
        // than merely awkward — and both answers are boundaries, which is the
        // worst kind of setting to leave unreachable.
        .accessibilityAdjustableAction { direction in
            let step = 1.0 / Double(StyleBand.count)
            switch direction {
            case .increment: position = (position + step).clamped()
            case .decrement: position = (position - step).clamped()
            @unknown default: break
            }
        }
    }
}

/// Sharp at the left, round at the right.
///
/// The right end is capped with a semicircle rather than cut square, so the
/// wedge reads as having grown to its full weight instead of having been
/// trimmed off at the edge.
struct WedgeTrack: Shape {

    var thinEnd: CGFloat = 2
    var thickEnd: CGFloat = 20

    func path(in rect: CGRect) -> Path {
        let mid = rect.midY
        let cap = thickEnd / 2
        // Guard the degenerate frame: a zero-width rect during the first layout
        // pass would put the arc's centre left of the origin and flip the shape.
        let capX = max(rect.minX, rect.maxX - cap)

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: mid - thinEnd / 2))
        path.addLine(to: CGPoint(x: capX, y: mid - cap))
        path.addArc(
            center: CGPoint(x: capX, y: mid),
            radius: cap,
            startAngle: .degrees(-90),
            endAngle: .degrees(90),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.minX, y: mid + thinEnd / 2))
        path.closeSubpath()
        return path
    }
}

/// `Swift.min`, not bare `min`: inside an extension on a numeric type the plain
/// name resolves to the type's own static `min` property, which is a value
/// rather than a function and fails to compile in a way that names neither.
private extension Double {
    func clamped() -> Double { Swift.min(1, Swift.max(0, self)) }
}

#Preview {
    CommunicationStyleView()
}
