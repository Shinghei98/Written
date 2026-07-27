import SwiftUI

/// The watering can that appears when a source is connected: it swings in from
/// the upper right, tips over the shoot, and rains water onto it before leaving.
/// Purely decorative — it covers the moment the tree's geometry is recomputed.
///
/// Drawn rather than animated from an asset, to stay in the same ink line as the
/// tree. (`AnimatedGIFView` is available if a drawn can is ever preferred.)
struct WateringCanOverlay: View {
    /// How long the can takes to leave once the work is done; the caller waits
    /// this out before changing the plant underneath it.
    static let exitDuration: Double = 0.42

    /// While true the can stays and keeps pouring. It goes on screen the moment
    /// the user connects a source and pours for as long as the distillation
    /// takes — which is the point of it: it covers the wait, so it can't run on
    /// a timer of its own.
    var isRunning: Bool

    /// Degrees the can is turned at rest and while pouring. Negative, because
    /// the spout is on its left: tipping a left-spouted can means leaning its
    /// top to the left, and turning it the other way lifts the rose into the
    /// air instead of over the plant.
    private static let restAngle: Double = -6
    private static let pourAngle: Double = -34

    @State private var hasArrived = false
    @State private var isPouring = false
    @State private var isLeaving = false

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let side = TreeGeometry.scale(in: CGRect(origin: .zero, size: size))
            let canSize = CGSize(width: side * 0.30, height: side * 0.30 * WateringCanFigure.aspectRatio)
            let centre = CGPoint(
                x: size.width * (hasArrived ? 0.82 : 1.40),
                y: size.height * 0.15
            )
            let angle = isPouring ? Self.pourAngle : Self.restAngle

            ZStack(alignment: .topLeading) {
                WateringCanFigure()
                    .frame(width: canSize.width, height: canSize.height)
                    .rotationEffect(.degrees(angle))
                    .position(centre)
                    .opacity(isLeaving ? 0 : 1)

                if isPouring {
                    // Falls from the rose itself, wherever the tipped can has
                    // put it, rather than from a point guessed in the overlay.
                    spray(
                        from: WateringCanFigure.rosePosition(canCentre: centre, canSize: canSize, degrees: angle),
                        side: side,
                        soilY: size.height * 0.78
                    )
                }
            }
        }
        .allowsHitTesting(false)
        .task {
            withAnimation(.easeOut(duration: 0.45)) { hasArrived = true }
            try? await Task.sleep(nanoseconds: 350_000_000)
            withAnimation(.easeInOut(duration: 0.30)) { isPouring = true }
        }
        // It pours until the work finishes rather than for a set time, so the
        // exit is driven from outside.
        .onChange(of: isRunning) { running in
            guard !running else { return }
            withAnimation(.easeIn(duration: Self.exitDuration)) { isLeaving = true }
        }
    }

    /// Water leaving the rose: a fan of fine drops rather than a line of them,
    /// which is what a rose does and what the reference draws — mostly specks,
    /// a few longer teardrops falling further.
    ///
    /// Each drop drifts a little to the left as it leaves the rose — the way the
    /// tipped rose faces — and then falls free. The sideways carry is spent
    /// early and gravity has the rest, so the path is an arc rather than a
    /// slant. See `Droplet` for how the two are separated.
    private func spray(from rose: CGPoint, side: CGFloat, soilY: CGFloat) -> some View {
        // Deterministic scatter: the drops should look casual, not different on
        // every connect.
        var rng = SeededGenerator(seed: 0xD20D20)

        let drops = (0..<42).map { index -> Droplet.Spec in
            // Squared so most drops stay near the head and the fan thins out
            // downward, rather than spreading evenly like a curtain.
            let reach = CGFloat(pow(rng.next(in: 0.16...1.0), 1.6))
            let heavy = rng.next(in: 0...1) < 0.18
            let fall = (soilY - rose.y) * reach

            return Droplet.Spec(
                id: index,
                start: CGPoint(
                    x: rose.x + CGFloat(rng.next(in: -0.012...0.012)) * side,
                    y: rose.y + CGFloat(rng.next(in: 0...0.02)) * side
                ),
                // Negative: out of the rose to the left, the way it faces, and
                // a good part of the fall's own distance so the drop is
                // visibly carried before gravity takes it.
                drift: -fall * CGFloat(rng.next(in: 0.22...0.42)),
                fall: fall,
                width: side * (heavy ? CGFloat(rng.next(in: 0.008...0.011)) : CGFloat(rng.next(in: 0.004...0.007))),
                stretch: heavy ? 1.9 : 1.15,
                delay: Double(index) * 0.022 + rng.next(in: 0...0.12)
            )
        }

        return ForEach(drops) { drop in
            Droplet(spec: drop)
        }
    }
}

/// One drop, falling under gravity, over and over for as long as the can pours.
///
/// The two axes are animated *separately*, and that is the whole trick: sideways
/// eased out, downward eased in. Interpolating a single position from start to
/// end — which is what this did — gives a straight line at some angle no matter
/// what the endpoints are, so the water left the rose and shot off in one
/// direction rather than arcing over.
///
/// Both cycles run the same length so the pair stay in step when they repeat; a
/// shorter one on the sideways axis would drift out of phase and the drop would
/// jump back to the rose halfway down.
private struct Droplet: View {
    struct Spec: Identifiable {
        let id: Int
        let start: CGPoint
        /// Sideways carry out of the rose, spent at a constant rate.
        let drift: CGFloat
        /// Distance fallen by the end, covered under acceleration.
        let fall: CGFloat
        let width: CGFloat
        let stretch: CGFloat
        let delay: Double
    }

    let spec: Spec
    private let duration: Double = 0.62

    /// Repeating, because the can pours for as long as the distillation takes:
    /// each drop returns to the rose and falls again, and the staggered delays
    /// make that read as a stream rather than as a pulse.
    private var fall: Animation {
        .easeIn(duration: duration).delay(spec.delay).repeatForever(autoreverses: false)
    }
    /// Front-loaded much harder than a plain ease-out: the sideways carry is
    /// all but spent in the first third, while the fall has barely started. The
    /// gap between the two is the bend — with both spread evenly over the same
    /// window the drop tracks a diagonal and never appears to turn.
    private var driftOut: Animation {
        .timingCurve(0.05, 0.9, 0.25, 1.0, duration: duration)
            .delay(spec.delay)
            .repeatForever(autoreverses: false)
    }

    @State private var hasFallen = false

    var body: some View {
        Ellipse()
            .fill(GardenPalette.softInk.opacity(0.62))
            .frame(width: spec.width, height: spec.width * spec.stretch)
            // Gravity: eased in, so the drop is slow leaving the rose and
            // quickest at the bottom of its fall.
            .offset(y: hasFallen ? spec.fall : 0)
            .animation(fall, value: hasFallen)
            // The drift it left with: eased *out*, so it is nearly spent by
            // the time the fall gets going. That difference is the curve — a
            // little to the left, then free fall.
            .offset(x: hasFallen ? spec.drift : 0)
            .animation(driftOut, value: hasFallen)
            .opacity(hasFallen ? 0 : 1)
            .animation(fall, value: hasFallen)
            .position(spec.start)
            .onAppear { hasFallen = true }
    }
}

// MARK: - The can

/// A can seen from the side, drawn as a solid figure: body, base, carry handle,
/// back handle, spout and rose.
///
/// The geometry is the reference's own, measured off it and rotated back to
/// upright — the animation supplies the tilt, and the reference's pose is very
/// nearly our pouring angle. Reading it that way settles three things that were
/// previously invented:
///
/// - The can is a **truncated cone**, not a cylinder: the base measures 0.506 of
///   the body's length across against the top's 0.413.
/// - We see the **base**, not the top. The base is a wide open ellipse with a
///   bright rolled rim; the top is a thin rim seen nearly edge-on, and there is
///   no opening to look into.
/// - The **spout is straight** — two lines converging slightly — and the rose is
///   an oval face with a trapezoid running back from it to the spout.
///
/// Filled rather than outlined, and as stacked shapes rather than one path,
/// because a filled path made of overlapping subpaths punches holes wherever two
/// of them happen to wind opposite ways.
struct WateringCanFigure: View {
    /// Height as a multiple of width, so callers can size it without guessing.
    /// The reference's own: 1.57 L tall against 1.869 L wide.
    static let aspectRatio: CGFloat = 0.84

    /// Where the rose sits, as a fraction of the figure's box. The spray starts
    /// here, so it lives next to the geometry that draws it.
    static let roseUnit = Can.roseCentre

    /// That point in the parent's coordinates once the can has been placed and
    /// tipped. `rotationEffect` turns about the centre, so this is the same
    /// rotation applied to the rose's offset from it.
    static func rosePosition(canCentre: CGPoint, canSize: CGSize, degrees: Double) -> CGPoint {
        let offset = CGPoint(
            x: (roseUnit.x - 0.5) * canSize.width,
            y: (roseUnit.y - 0.5) * canSize.height
        )
        let radians = CGFloat(Angle(degrees: degrees).radians)
        return CGPoint(
            x: canCentre.x + offset.x * cos(radians) - offset.y * sin(radians),
            y: canCentre.y + offset.x * sin(radians) + offset.y * cos(radians)
        )
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let ink = GardenPalette.ink
            let hairline = max(0.6, size.width * Can.outline)

            // Every part is a tube, so each gets the same ladder across it —
            // only the direction changes with how the part is turned.
            let acrossBody = LinearGradient(stops: Can.metalStops, startPoint: Can.shadowEdge, endPoint: Can.litEdge)
            let acrossSpout = LinearGradient(
                stops: Can.tubeStops,
                startPoint: Can.spoutShadowEdge,
                endPoint: Can.spoutLitEdge
            )
            let acrossHandles = LinearGradient(
                stops: Can.tubeStops,
                startPoint: UnitPoint(x: Can.axis - Can.baseRadius, y: 0.5),
                endPoint: UnitPoint(x: Can.axis + Can.baseRadius * 2.0, y: 0.5)
            )

            ZStack {
                // Handles first: they pass behind the body, so the body's fill
                // is what hides their far ends.
                CanHandles().fill(acrossHandles)
                CanHandles().stroke(ink.opacity(0.85), lineWidth: hairline)

                CanSpout().fill(acrossSpout)
                CanSpout().stroke(ink.opacity(0.85), lineWidth: hairline)

                CanBody().fill(acrossBody)
                // The contour holds the figure together: without it the lit
                // side of the cone dissolves into the parchment behind it.
                CanBody().stroke(ink.opacity(0.9), lineWidth: hairline)

                // Vertical seams in the rolled metal — dark hairlines *across*
                // the highlight, which is where the reference shows them.
                CanSeams()
                    .stroke(
                        ink.opacity(0.10),
                        style: StrokeStyle(lineWidth: max(0.4, size.width * 0.006), lineCap: .round)
                    )

                // The base: the end we are looking at. Dark inside, with the
                // rolled rim catching light along the edge nearest the body.
                CanBase().fill(Can.metal(0.13))
                CanBase().stroke(ink.opacity(0.9), lineWidth: hairline)
                CanBaseRim()
                    .stroke(
                        // Graded rather than a flat bright band: it is a rolled
                        // edge under the same light as the body, so it dims
                        // toward the shadow side like everything else.
                        LinearGradient(
                            colors: [Can.metal(0.24), Can.metal(0.55), Can.metal(0.84)],
                            startPoint: Can.shadowEdge,
                            endPoint: Can.litEdge
                        ),
                        style: StrokeStyle(lineWidth: max(0.5, size.width * 0.009), lineCap: .round)
                    )

                // The rose: a trapezoid for its side, and the pale oval face
                // turned across the spout. Left plain — at the size it plays on
                // screen the perforations were noise on a shape barely wider
                // than the pipe behind it.
                CanRoseSide().fill(acrossSpout)
                CanRoseSide().stroke(ink.opacity(0.85), lineWidth: hairline)
                CanRoseFace().fill(Can.metal(0.78))
                CanRoseFace().stroke(ink.opacity(0.9), lineWidth: hairline)
            }
        }
    }
}

/// Proportions shared by every part, as fractions of the figure's box.
///
/// Derived from the reference by taking its base's centre as the origin, its
/// axis as "up", and dividing through by the body's length L — so these are the
/// drawing's own numbers, not a guess at what a watering can looks like.
enum Can {
    /// The body's axis, and the two ends along it.
    static let axis: CGFloat = 0.729
    static let topY: CGFloat = 0.261
    static let baseY: CGFloat = 0.898

    /// Half-widths at those ends. The taper is the point: 0.413 L at the top
    /// against 0.506 L at the base is a cone, and drawing it parallel-sided is
    /// what made the earlier version read as a tin rather than a can.
    static let topRadius: CGFloat = 0.221
    static let baseRadius: CGFloat = 0.271

    /// How open each end's ellipse is. The base is the end facing us and shows
    /// as a wide ellipse; the top is nearly edge-on, a rim rather than a mouth.
    static let topLift: CGFloat = 0.045
    static let baseLift: CGFloat = 0.102

    /// Where the spout leaves the body — the lower third of its side — and how
    /// thick it is there and at the rose. Straight, converging slightly.
    static let spoutRootY: CGFloat = 0.608
    static let spoutHalfAtBody: CGFloat = 0.0615
    static let spoutHalfAtRose: CGFloat = 0.0362

    /// The rose's face, and the trapezoid running back from it to the spout.
    /// Held at the reference's proportions to each other — the trapezoid's wide
    /// end is 0.73 of the face's long axis — but smaller overall than measured,
    /// so the head doesn't outweigh the can it hangs off at this size.
    static let roseCentre = CGPoint(x: 0.061, y: 0.310)
    static let roseFaceHalfLong: CGFloat = 0.089
    static let roseFaceHalfShort: CGFloat = 0.046
    static let roseSideHalf: CGFloat = 0.065
    /// The trapezoid's share of the run from the rose back to the body.
    static let roseSideRun: CGFloat = 0.138

    static let outline: CGFloat = 0.011

    /// Where the spout crosses the body's silhouette.
    static var spoutRoot: CGPoint {
        let up = (baseY - spoutRootY) / (baseY - topY)
        return CGPoint(x: axis - (baseRadius + (topRadius - baseRadius) * up), y: spoutRootY)
    }

    /// How far past that crossing the spout is carried *into* the body, as a
    /// fraction of the figure's width.
    ///
    /// Ending it on the silhouette leaves it disconnected: the spout's end is
    /// cut square across the pipe, the body's edge runs at a slant, so the two
    /// meet at one corner with a wedge of background between them and each
    /// keeps its own outline. Buried, the body's fill closes over the joint —
    /// the same reason the plant's petioles root inside the stem.
    static let spoutBurial: CGFloat = 0.14

    /// A point on the base's ellipse. Shared so the body's lower edge and the
    /// base are the *same* curve — a quadratic approximation of the ellipse
    /// crosses it either side of the tangent points, and the two contours draw
    /// as a pair of lines that don't quite meet.
    static func basePoint(at angle: Double, in rect: CGRect) -> CGPoint {
        CGPoint(
            x: rect.width * axis + CGFloat(cos(angle)) * rect.width * baseRadius,
            y: rect.height * baseY + CGFloat(sin(angle)) * rect.height * baseLift
        )
    }

    // MARK: Metal
    //
    // The can is a cylinder, and a flat fill says so no more than a flat fill
    // says the mound is a heap. These values are measured off the reference: a
    // scanline across its body, perpendicular to the body's axis, normalised
    // 0…1. The shape of that curve is the whole point — a long climb out of the
    // core shadow through the midtones, a *narrow* specular band about three
    // quarters of the way across, then a quick fall as the metal rolls away.
    // A symmetrical light-to-dark ramp reads as a shaded rectangle instead.

    /// A tone on that ramp, ink at 0 and parchment at 1.
    static func metal(_ value: Double) -> Color {
        let ink = (r: 0.102, g: 0.102, b: 0.094)
        let parchment = (r: 0.953, g: 0.937, b: 0.914)
        return Color(
            red: ink.r + (parchment.r - ink.r) * value,
            green: ink.g + (parchment.g - ink.g) * value,
            blue: ink.b + (parchment.b - ink.b) * value
        )
    }

    /// The measured ladder, as gradient stops running from the shadow side of
    /// the body to the lit one — the reference's own scanline, sample for
    /// sample.
    ///
    /// Sampled this finely on purpose. SwiftUI interpolates gradients in linear
    /// light, so widely spaced stops come out *lighter* between them than the
    /// numbers say: an earlier pass used nine stops and measured back 0.34 on
    /// the shadow side where the reference reads 0.15 — the can lost its core
    /// shadow and went pewter. Stops every few percent leave no room for that
    /// drift.
    static let metalStops: [Gradient.Stop] = [
        // The shadow half is carried a little under the measured figures: it
        // renders against parchment, and the antialiased edge lifts the last
        // few pixels toward the background.
        .init(color: metal(0.110), location: 0.000),   // core shadow, at the edge
        .init(color: metal(0.115), location: 0.067),
        .init(color: metal(0.175), location: 0.133),
        .init(color: metal(0.180), location: 0.200),
        .init(color: metal(0.205), location: 0.267),
        .init(color: metal(0.245), location: 0.333),
        .init(color: metal(0.294), location: 0.400),
        .init(color: metal(0.369), location: 0.467),   // midtones climbing
        .init(color: metal(0.443), location: 0.533),
        .init(color: metal(0.510), location: 0.600),
        .init(color: metal(0.518), location: 0.667),
        .init(color: metal(0.694), location: 0.700),
        .init(color: metal(0.894), location: 0.733),   // specular band, narrow
        .init(color: metal(0.894), location: 0.767),
        .init(color: metal(0.718), location: 0.800),
        .init(color: metal(0.502), location: 0.867),
        .init(color: metal(0.412), location: 0.933),
        .init(color: metal(0.290), location: 1.000)    // rolled edge turning away
    ]

    /// A thin tube — a handle, or the spout — tells the same story in far less
    /// room, and it is not the same ladder scaled down: in the reference these
    /// sit almost entirely in core shadow with one bright edge where the light
    /// catches the top of the pipe. Given the body's ramp they come out as pale
    /// grey tubes, which is what a handle never looks like.
    static let tubeStops: [Gradient.Stop] = [
        .init(color: metal(0.11), location: 0.00),
        .init(color: metal(0.12), location: 0.20),
        .init(color: metal(0.14), location: 0.36),
        .init(color: metal(0.17), location: 0.48),
        .init(color: metal(0.21), location: 0.60),
        .init(color: metal(0.28), location: 0.70),
        .init(color: metal(0.42), location: 0.76),
        .init(color: metal(0.58), location: 0.82),   // the catch of light
        .init(color: metal(0.34), location: 0.88),
        .init(color: metal(0.22), location: 0.93),
        .init(color: metal(0.13), location: 1.00)
    ]

    /// The body's extent across the figure, so the ramp spans the cone itself
    /// and not the whole box.
    static var shadowEdge: UnitPoint { UnitPoint(x: axis - baseRadius, y: 0.5) }
    static var litEdge: UnitPoint { UnitPoint(x: axis + baseRadius, y: 0.5) }

    /// The spout's ramp runs across the pipe: from its underside up to the edge
    /// the light lands on.
    static var spoutShadowEdge: UnitPoint { UnitPoint(x: 0.16, y: 0.62) }
    static var spoutLitEdge: UnitPoint { UnitPoint(x: 0.30, y: 0.36) }
}

/// The cone, closed at the bottom by the near half of the base's ellipse and at
/// the top by the shallow curve of a rim seen almost edge-on.
private struct CanBody: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let cx = w * Can.axis
        let top = h * Can.topY, base = h * Can.baseY
        let topR = w * Can.topRadius
        let baseR = w * Can.baseRadius

        var path = Path()
        path.move(to: CGPoint(x: cx - topR, y: top))
        // The far side of the top rim, barely open.
        path.addQuadCurve(
            to: CGPoint(x: cx + topR, y: top),
            control: CGPoint(x: cx, y: top - h * Can.topLift * 2)
        )
        path.addLine(to: CGPoint(x: cx + baseR, y: base))
        // The near side of the base: the ellipse itself, so the body's edge and
        // the base's edge are one line rather than two that cross.
        for step in 1...24 {
            path.addLine(to: Can.basePoint(at: Double.pi * Double(step) / 24, in: rect))
        }
        path.closeSubpath()
        _ = baseR
        return path
    }
}

/// The base's face. We are looking at the underside of the can, so this is a
/// full ellipse, not a curve closing the silhouette.
private struct CanBase: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        return Path(ellipseIn: CGRect(
            x: w * Can.axis - w * Can.baseRadius,
            y: h * Can.baseY - h * Can.baseLift,
            width: w * Can.baseRadius * 2,
            height: h * Can.baseLift * 2
        ))
    }
}

/// The lit part of the rolled edge around that base: the *upper* arc, where the
/// base meets the body. Run along the outer edge instead — as an earlier pass
/// did — and it reads as a white pipe lying across the base rather than as a
/// rolled lip catching the light.
private struct CanBaseRim: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        var first = true
        for step in stride(from: 1.10, through: 1.95, by: 0.03) {
            let point = Can.basePoint(at: Double.pi * step, in: rect)
            if first { path.move(to: point); first = false } else { path.addLine(to: point) }
        }
        return path
    }
}

/// Straight, and converging slightly: the reference's spout is two lines, and
/// drawing it as a curve — which is what the plant's petioles wanted — is what
/// made it read as a tail hanging off the can.
private struct CanSpout: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let crossing = CGPoint(x: w * Can.spoutRoot.x, y: h * Can.spoutRoot.y)
        let rose = CGPoint(x: w * Can.roseCentre.x, y: h * Can.roseCentre.y)
        // Stops where the rose's trapezoid takes over.
        let tip = CGPoint(
            x: rose.x + (crossing.x - rose.x) * Can.roseSideRun,
            y: rose.y + (crossing.y - rose.y) * Can.roseSideRun
        )

        // Carried on past the silhouette into the body, where the body's own
        // fill closes over the end.
        let back = CGPoint(x: crossing.x - tip.x, y: crossing.y - tip.y)
        let reach = max(0.0001, hypot(back.x, back.y))
        let root = CGPoint(
            x: crossing.x + back.x / reach * w * Can.spoutBurial,
            y: crossing.y + back.y / reach * w * Can.spoutBurial
        )

        let along = CGPoint(x: tip.x - root.x, y: tip.y - root.y)
        let length = max(0.0001, hypot(along.x, along.y))
        let normal = CGPoint(x: -along.y / length, y: along.x / length)
        let atBody = w * Can.spoutHalfAtBody, atRose = w * Can.spoutHalfAtRose

        var path = Path()
        path.move(to: CGPoint(x: root.x + normal.x * atBody, y: root.y + normal.y * atBody))
        path.addLine(to: CGPoint(x: tip.x + normal.x * atRose, y: tip.y + normal.y * atRose))
        path.addLine(to: CGPoint(x: tip.x - normal.x * atRose, y: tip.y - normal.y * atRose))
        path.addLine(to: CGPoint(x: root.x - normal.x * atBody, y: root.y - normal.y * atBody))
        path.closeSubpath()
        return path
    }
}

/// The rose's side: a trapezoid from the spout out to the plane of the face.
private struct CanRoseSide: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let root = CGPoint(x: w * Can.spoutRoot.x, y: h * Can.spoutRoot.y)
        let rose = CGPoint(x: w * Can.roseCentre.x, y: h * Can.roseCentre.y)
        let tip = CGPoint(
            x: rose.x + (root.x - rose.x) * Can.roseSideRun,
            y: rose.y + (root.y - rose.y) * Can.roseSideRun
        )

        let along = CGPoint(x: tip.x - rose.x, y: tip.y - rose.y)
        let length = max(0.0001, hypot(along.x, along.y))
        let normal = CGPoint(x: -along.y / length, y: along.x / length)
        let atFace = w * Can.roseSideHalf, atSpout = w * Can.spoutHalfAtRose

        var path = Path()
        path.move(to: CGPoint(x: rose.x + normal.x * atFace, y: rose.y + normal.y * atFace))
        path.addLine(to: CGPoint(x: tip.x + normal.x * atSpout, y: tip.y + normal.y * atSpout))
        path.addLine(to: CGPoint(x: tip.x - normal.x * atSpout, y: tip.y - normal.y * atSpout))
        path.addLine(to: CGPoint(x: rose.x - normal.x * atFace, y: rose.y - normal.y * atFace))
        path.closeSubpath()
        return path
    }
}

/// The angle the rose's face is turned to, square across the spout's line.
private func roseAngle(in rect: CGRect) -> CGFloat {
    let root = CGPoint(x: rect.width * Can.spoutRoot.x, y: rect.height * Can.spoutRoot.y)
    let rose = CGPoint(x: rect.width * Can.roseCentre.x, y: rect.height * Can.roseCentre.y)
    return atan2(root.y - rose.y, root.x - rose.x)
}

/// The pale oval we are looking straight at.
private struct CanRoseFace: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let centre = CGPoint(x: w * Can.roseCentre.x, y: h * Can.roseCentre.y)
        let face = CGRect(
            x: -w * Can.roseFaceHalfShort,
            y: -w * Can.roseFaceHalfLong,
            width: w * Can.roseFaceHalfShort * 2,
            height: w * Can.roseFaceHalfLong * 2
        )
        return Path(ellipseIn: face)
            .applying(CGAffineTransform(rotationAngle: roseAngle(in: rect)))
            .applying(CGAffineTransform(translationX: centre.x, y: centre.y))
    }
}

private struct CanHandles: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let cx = w * Can.axis
        let topR = w * Can.topRadius

        var path = Path()
        // Carry handle: up off the top rim's near edge, over, and down to the
        // back of the body.
        path.move(to: CGPoint(x: cx - topR * 0.98, y: h * (Can.topY + 0.010)))
        path.addQuadCurve(
            to: CGPoint(x: cx + topR * 1.02, y: h * 0.470),
            control: CGPoint(x: cx - w * 0.010, y: -h * 0.055)
        )

        // Back handle: the smaller loop for the other hand.
        path.move(to: CGPoint(x: cx + topR * 0.90, y: h * 0.300))
        path.addQuadCurve(
            to: CGPoint(x: cx + topR * 0.92, y: h * 0.560),
            control: CGPoint(x: cx + topR * 2.20, y: h * 0.410)
        )

        return path.strokedPath(StrokeStyle(lineWidth: w * 0.036, lineCap: .round, lineJoin: .round))
    }
}

/// Fine vertical striping down the body. Few and heavy, they read as grey bars
/// painted on; several hairlines read as light on rolled metal.
private struct CanSeams: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let cx = w * Can.axis

        var path = Path()
        for offset in [-0.130, -0.075, 0.020, 0.075, 0.130] as [CGFloat] {
            let top = CGPoint(x: cx + w * offset * (Can.topRadius / Can.baseRadius), y: h * (Can.topY + 0.075))
            let base = CGPoint(x: cx + w * offset, y: h * (Can.baseY - 0.075))
            path.move(to: top)
            path.addLine(to: base)
        }
        return path
    }
}

#Preview {
    ZStack {
        GardenPalette.parchment
        WateringCanFigure()
            .frame(width: 200, height: 200 * WateringCanFigure.aspectRatio)
            .rotationEffect(.degrees(-34))
    }
    .frame(width: 340, height: 340)
}
