import SwiftUI

/// The illustrated plant: soil, stem, leaves, drawn as vectors so it stays crisp
/// at any size — see `SeedlingArt`.
///
/// `stage` picks how far along it has grown, and changing it *grows* the plant
/// already on screen: the stem lengthens, carrying its petioles and blades up
/// with it, and the side shoot then unfolds from the stem. Nothing is dissolved
/// and redrawn, because the whole point of the screen is that this is the user's
/// own plant getting bigger.
///
/// Each part carries its own animation and delay rather than reading slices of
/// one shared progress value. SwiftUI evaluates a body once with the *final*
/// state and interpolates every modifier over the same window, so phases derived
/// from a single animated number all run at once — which showed up here as
/// leaves hanging in the air above a half-grown stem.
struct SeedlingView: View {
    static let aspectRatio = SeedlingArt.aspectRatio

    /// The stem's climb from one stage to the next. Shared, because anything
    /// pinned to the leaves — the modality badge sits beside one — has to rise
    /// on exactly this curve or it drifts off them on the way up.
    static let extensionAnimation: Animation = .easeInOut(duration: 1.1)

    /// When the first pair of leaves has finished opening, measured from this
    /// view appearing: the stem reaches the fork at 1.35s and the spring that
    /// opens the blades settles about 0.75s after it starts. Anything that
    /// belongs to the grown plant rather than to the seed — the badge — waits
    /// this out, so the plant is what the eye finds first.
    static let leavesOpenAt: Double = 1.95

    private static let stemDelay: Double = 0.2
    private static let leafDelay: Double = 1.2
    private static let shootDelay: Double = 0.75
    private static let shootDuration: Double = 1.3
    private static let leafletSettle: Double = 0.6

    /// When the last of a shoot's leaflets has finished opening, measured from
    /// the stage changing — the terminal one is the last the stalk reaches.
    /// Derived from the timings below rather than written out, so a change to
    /// the sequence carries to whatever waits on it.
    static func shootOpenAt(_ shoot: SeedlingArt.Shoot) -> Double {
        let last = shoot.leaflets.map(\.along).max() ?? 1
        return shootDelay + shootDuration * (0.55 * Double(last) + 0.22) + leafletSettle
    }

    var stage: SeedlingStage = .sprout

    @State private var stemProgress: Double = 0
    /// 0 = the sprout's fork, 1 = the shoot's, higher up the canvas.
    @State private var extended: CGFloat = 0
    @State private var leafScale: Double = 0.05
    @State private var leafOpacity: Double = 0
    /// One entry per leaflet of every shoot, keyed by `[shoot, leaflet]`: they
    /// open in the order their stalk reaches them, and a shared value would
    /// open the whole cluster at once.
    @State private var leafletScale: [[Double]] = SeedlingArt.shoots.map { $0.leaflets.map { _ in 0.05 } }
    @State private var leafletOpacity: [[Double]] = SeedlingArt.shoots.map { $0.leaflets.map { _ in 0 } }
    @State private var shootProgress: Double = 0

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size

            ZStack {
                // Stem first, mound second: the stem's base is below the pile's
                // crest, so the stones drawn over it are what make it emerge
                // from the top of the pile rather than from the ground.
                VectorStemShape(
                    progress: stemProgress,
                    extended: extended,
                    shootProgress: shootProgress,
                    growing: stage.rawValue
                )
                .fill(GardenPalette.ink)

                StemHighlightShape(progress: stemProgress, extended: extended)
                    .stroke(
                        GardenPalette.parchment.opacity(0.55),
                        style: StrokeStyle(lineWidth: max(0.5, size.width * 0.0024), lineCap: .round)
                    )

                // No fade: the ground is already there when the shoot arrives.
                VectorMound()

                cotyledon(mirrored: false, in: size)
                cotyledon(mirrored: true, in: size)

                // The set for this point in the climb, not the raw array: the
                // canopy draws its own copy of the branches, eased in over the
                // last stage. Ids and leaflet counts match either way, so the
                // animation state indexed below stays aligned.
                ForEach(SeedlingArt.shoots(by: extended)) { shoot in
                    ForEach(Array(shoot.leaflets.enumerated()), id: \.offset) { index, leaflet in
                        // Indices stay aligned with the animation state arrays,
                        // which are sized to the full list — so a leaflet that
                        // has not opened yet is skipped here rather than removed.
                        if SeedlingArt.isOpen(leaflet, extended: extended) {
                            self.leaflet(leaflet, of: shoot, index: index, in: size)
                        }
                    }
                }
            }
        }
        .aspectRatio(Self.aspectRatio, contentMode: .fit)
        .onAppear(perform: play)
        // The two-parameter overload is iOS 17; this project ships to 16.
        .onChange(of: stage) { new in
            grow(into: new)
        }
    }

    // MARK: - Leaves

    /// One of the pair at the top of the stem. Its anchor is read off the
    /// *current* fork, so animating `extended` carries the whole leaf up the
    /// canvas with the stem rather than leaving it behind.
    private func cotyledon(mirrored: Bool, in size: CGSize) -> some View {
        // The petiole ends here, so the blade starts from its tip rather than
        // from the fork itself. Both this point and the tilt are shared with
        // `VectorStemShape`, which aims the petiole at them.
        let attachment = SeedlingArt.stalkPoint(mirrored: mirrored, extended: extended)
        let stalk = CGPoint(x: size.width * attachment.x, y: size.height * attachment.y)

        return blade(
            mirrored: mirrored,
            box: SeedlingArt.leafSize(mirrored: mirrored),
            tilt: SeedlingArt.leafTilt(mirrored: mirrored, extended: extended),
            at: stalk,
            scale: leafScale,
            opacity: leafOpacity,
            in: size
        )
    }

    /// One leaflet on a side shoot. Sized as a fraction of a cotyledon so the
    /// whole plant stays one drawing at one weight.
    private func leaflet(
        _ leaflet: SeedlingArt.Leaflet,
        of shoot: SeedlingArt.Shoot,
        index: Int,
        in size: CGSize
    ) -> some View {
        let anchor = SeedlingArt.leafletBase(leaflet, of: shoot, extended: extended)
        let box = SeedlingArt.leafSize(mirrored: false)
        // Not the leaflet's declared size: a shoot goes on growing for a stage
        // after the one that put it out.
        let scale = SeedlingArt.leafletScale(leaflet, of: shoot, extended: extended)

        return blade(
            mirrored: leaflet.mirrored,
            box: CGSize(width: box.width * scale, height: box.height * scale),
            tilt: SeedlingArt.leafletTilt(leaflet, of: shoot, extended: extended),
            at: CGPoint(x: size.width * anchor.x, y: size.height * anchor.y),
            scale: leafletScale[shoot.id][index],
            opacity: leafletOpacity[shoot.id][index],
            in: size
        )
    }

    /// A blade and its veins, hung off a point and pivoting from it as it opens.
    /// The outline is drawn firmly and the veins at a fraction of the weight —
    /// that contrast is what reads as pencil rather than as a chart.
    private func blade(
        mirrored: Bool,
        box: CGSize,
        tilt: Double,
        at anchor: CGPoint,
        scale: Double,
        opacity: Double,
        in size: CGSize
    ) -> some View {
        let straighten = SeedlingArt.spineStraightness(extended: extended)
        let leafWidth = size.width * box.width
        let leafHeight = size.height * box.height
        // Scaled off the blade rather than the canvas, or a leaflet a quarter
        // the size would be drawn with a cotyledon's pen.
        let outline = max(0.7, leafWidth * 0.0235)

        return ZStack {
            // The blade itself is transparent — parchment shows through, as in
            // the template; only the edge and the veins are drawn.
            LeafBlade(mirrored: mirrored, straighten: straighten)
                .stroke(
                    GardenPalette.ink.opacity(0.94),
                    style: StrokeStyle(lineWidth: outline, lineCap: .round, lineJoin: .round)
                )
            // Weighted like the blade edge rather than like the veins: the
            // midrib is the petiole continuing, and a tonal step at the joint
            // reads as two strokes meeting even when the geometry is flush.
            LeafMidrib(mirrored: mirrored, straighten: straighten)
                .fill(GardenPalette.ink.opacity(0.94))
            LeafVeins(mirrored: mirrored, straighten: straighten)
                .fill(GardenPalette.ink.opacity(0.40))
        }
        .frame(width: leafWidth, height: leafHeight)
        // Anchored at the bottom — the blade box's bottom centre is the spine's
        // base, so turning and opening the leaf pivots on the stalk's tip and
        // never drags the midrib off it.
        .rotationEffect(.degrees(tilt), anchor: .bottom)
        .scaleEffect(scale, anchor: .bottom)
        .opacity(opacity)
        .position(x: anchor.x, y: anchor.y - leafHeight / 2)
    }

    // MARK: - Growing

    /// First appearance: out of the soil, then the pair of cotyledons opens.
    private func play() {
        withAnimation(.easeOut(duration: 1.15).delay(Self.stemDelay)) {
            stemProgress = 1
        }
        // Held until the stem has reached the fork; the spring gives the slight
        // overshoot of a leaf opening.
        withAnimation(.spring(response: 0.75, dampingFraction: 0.62).delay(Self.leafDelay)) {
            leafScale = 1
        }
        withAnimation(.easeOut(duration: 0.45).delay(Self.leafDelay)) {
            leafOpacity = 1
        }

        // Arriving already grown — a relaunch with apps connected — the shoots
        // are drawn in behind the cotyledons rather than replayed from nothing.
        if stage != .sprout {
            grow(into: stage, after: 1.5)
        }
    }

    /// One stage to the next, without either being redrawn: the stem lengthens
    /// and takes its leaves with it, then the shoot for this stage unfolds out
    /// of its side. Shoots grown in earlier stages simply ride up with it.
    private func grow(into stage: SeedlingStage, after delay: Double = 0) {
        // Going *back* — the preview stepper wraps to bare soil, and a real
        // reset would too. Without this the view keeps the state of the stage
        // it was in and the shoots stay on screen over a plant that has none.
        guard stage != .sprout else {
            withAnimation(Self.extensionAnimation) {
                extended = 0
            }
            withAnimation(.easeOut(duration: 0.35)) {
                shootProgress = 0
                for shoot in SeedlingArt.shoots {
                    for index in shoot.leaflets.indices {
                        leafletScale[shoot.id][index] = 0.05
                        leafletOpacity[shoot.id][index] = 0
                    }
                }
            }
            return
        }

        withAnimation(Self.extensionAnimation.delay(delay)) {
            extended = stage.extended
        }
        // Overlapping the tail of the stem's climb rather than waiting it out,
        // so the plant never looks like it has stopped.
        shootProgress = 0
        withAnimation(.easeOut(duration: Self.shootDuration).delay(delay + Self.shootDelay)) {
            shootProgress = 1
        }

        // Only this stage's shoot unfolds; anything older is already open and
        // must not spring a second time.
        for shoot in SeedlingArt.shoots where shoot.stage == stage {
            // Each leaflet opens as the shoot's stalk reaches it, so the
            // cluster unfolds from the stem outward.
            for (index, leaflet) in shoot.leaflets.enumerated() {
                let reached = delay + Self.shootDelay
                    + Self.shootDuration * (0.55 * Double(leaflet.along) + 0.22)
                withAnimation(.spring(response: Self.leafletSettle, dampingFraction: 0.66).delay(reached)) {
                    leafletScale[shoot.id][index] = 1
                }
                withAnimation(.easeOut(duration: 0.35).delay(reached)) {
                    leafletOpacity[shoot.id][index] = 1
                }
            }
        }

        // A stage skipped — arriving already grown — leaves its shoots open
        // without animating them.
        for shoot in SeedlingArt.shoots where shoot.stage.rawValue < stage.rawValue {
            for index in shoot.leaflets.indices {
                leafletScale[shoot.id][index] = 1
                leafletOpacity[shoot.id][index] = 1
            }
        }
        // And anything newer than this stage is not on the plant yet: stepping
        // back has to put those away, not just stop animating them.
        for shoot in SeedlingArt.shoots where shoot.stage.rawValue > stage.rawValue {
            for index in shoot.leaflets.indices {
                leafletScale[shoot.id][index] = 0.05
                leafletOpacity[shoot.id][index] = 0
            }
        }
    }
}

#Preview("Sprout") {
    SeedlingView()
        .frame(width: 320)
        .background(GardenPalette.parchment)
}

#Preview("Shoot") {
    SeedlingView(stage: .shoot)
        .frame(width: 320)
        .background(GardenPalette.parchment)
}
