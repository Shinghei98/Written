import SwiftUI

/// Vector redraw of the seedling.
///
/// The supplied art is a 358×330 raster that has to fill ~345pt of screen, so at
/// 3× it goes soft. These are paths instead: crisp at any size, and each part can
/// animate on its own.
///
/// Everything is laid out in the same unit canvas as the original art
/// (358×330, y downward), so the anchors carry over: the leaves fork off the stem
/// at `junction`, and the stem enters the soil at `soilLine`.
/// How far along the illustrated plant has grown. Both stages are the same
/// drawing — same mound, same stem, same pair of cotyledons — so connecting the
/// first app reads as *this plant* growing rather than as a different picture.
enum SeedlingStage: Int, CaseIterable {
    /// Nothing connected: stem and two cotyledons.
    case sprout = 0
    /// One modality connected: the stem runs taller and puts out a side shoot
    /// of three small leaflets on the right.
    case shoot = 1
    /// Two connected: taller again, with a second shoot lower down on the left
    /// carrying a pair.
    case branch = 2
    /// Three connected: taller still, and a third shoot high on the left with
    /// one open leaf and a bud at its tip — the newest growth, not yet out.
    case bough = 3
    /// Four connected — every modality. Taller again, and a fourth shoot on the
    /// right above the bough, so the sides keep alternating up the stem.
    case canopy = 4

    /// How far along the stem's extension this stage sits. The geometry is
    /// driven by this number rather than by the case, so the plant can be
    /// caught halfway: connecting an app *extends* the plant already on screen
    /// instead of replacing it with a taller drawing.
    var extended: CGFloat { CGFloat(rawValue) }
}

enum SeedlingArt {
    static let aspectRatio: CGFloat = 358.0 / 330.0
    static let soilLine = CGPoint(x: 0.500, y: 0.760)

    /// Where the stem forks into the two cotyledons, one height per stage. It
    /// rises each time — the phase-2 reference puts its fork at 0.379 of the
    /// canvas against the first template's 0.400, and phase 3 higher again.
    /// Phase 4's is a long step: measured against its own stem, the reference
    /// plant is 0.71 stem to 0.29 leaves, where ours had been nearer half and
    /// half. The plant has to get *taller*, not just wider, and that means the
    /// fork keeps climbing.
    /// Phase 5 from the skeletonised reference, not from a density map: its stem
    /// traces from a foot at 0.7727 to a fork at 0.1994, a rise of 0.7419 of the
    /// height above its own foot. Against ours at 0.705 that is 0.182, where the
    /// previous step landed at 0.667 of the same measure. The plant grows by
    /// getting taller before it gets wider, and this is the largest step yet.
    ///
    /// Raised again from 0.182, by eye against the reference rather than by
    /// arithmetic: the bifurcation sat too low and the bare stem under it was
    /// too short. Raising it does both at once — the fork lifts, and because
    /// shoots are anchored to a height rather than a share of the stem, they all
    /// drop away from it as the stem lengthens past them.
    static let forkHeights: [CGFloat] = [0.433, 0.380, 0.335, 0.235, 0.155]

    /// The fork partway through that climb. Everything above it — petioles,
    /// blades, every shoot's attachment point — is placed off this, so they all
    /// ride up together as the stem grows. `extended` is the stage as a
    /// continuous number, so a transition can be caught mid-way.
    static func junction(extended: CGFloat) -> CGPoint {
        let last = CGFloat(forkHeights.count - 1)
        let along = min(max(extended, 0), last)
        let index = Int(along)
        let into = along - CGFloat(index)
        let from = forkHeights[index]
        let to = forkHeights[min(index + 1, forkHeights.count - 1)]
        let upright = CGPoint(x: forkX(extended: extended), y: from + (to - from) * into)

        // Turning the fork turns the whole stem, because `stemPoint` builds the
        // centreline along the chord from the foot to here and every shoot hangs
        // off that. Nothing else has to move.
        let canopy = min(max(extended - 3, 0), 1)
        guard canopy > 0 else { return upright }
        return turnedAboutFoot(upright, degrees: canopyTilt * Double(canopy))
    }

    /// How far the canopy's stem is turned about its foot, in degrees, positive
    /// being counterclockwise on screen — the top going left.
    static let canopyTilt: Double = 2

    /// Turns a point about the stem's foot.
    ///
    /// In pixels rather than canvas fractions. The canvas is wider than it is
    /// tall, so mixing an x fraction with a y fraction in a rotation shears the
    /// result instead of turning it — the same trap as measuring an angle off a
    /// non-square image.
    private static func turnedAboutFoot(_ point: CGPoint, degrees: Double) -> CGPoint {
        let radians = degrees * .pi / 180
        let cosine = CGFloat(cos(radians)), sine = CGFloat(sin(radians))

        // Both in units of the canvas's *height*, which is what makes them
        // comparable.
        let dx = (point.x - stemBase.x) * aspectRatio
        let dy = point.y - stemBase.y

        // Screen coordinates put y downward, so counterclockwise as the eye sees
        // it is clockwise in the arithmetic.
        let rx = dx * cosine + dy * sine
        let ry = -dx * sine + dy * cosine
        return CGPoint(x: stemBase.x + rx / aspectRatio, y: stemBase.y + ry)
    }

    /// Where the fork sits across the canvas.
    ///
    /// Straight above the foot for every stage but the last. The reference's
    /// canopy finishes its stem *right* of where it started — foot at 0.4825 of
    /// the viewBox, fork at 0.5016 — where ours has always finished left, at
    /// 0.500 against a foot at 0.515.
    ///
    /// That difference cannot be left to the lean profile. `stemOffset` adds the
    /// profile to the chord between foot and fork, so the profile has to reach
    /// zero at the top or the stem arrives somewhere the cotyledons are not
    /// hanging from. Ask it to carry the chord's error as well and it has to
    /// snap back at t=1 — which is the third curve, the one just under the
    /// bifurcation, that should not be there.
    static func forkX(extended: CGFloat) -> CGFloat {
        let canopy = min(max(extended - 3, 0), 1)
        return 0.500 + (0.528 - 0.500) * canopy
    }

    // MARK: Leaf attachment
    //
    // Stem, petiole and midrib are one vessel drawn by three different types —
    // `VectorStemShape` runs the petiole in canvas coordinates, `SeedlingView`
    // hangs the blade box off its tip, and `LeafMidrib` draws inside that box.
    // The hand-off only reads as a single stroke if all three agree on *where*
    // the joint is, *which way* the blade leaves it, and *how wide* the line is
    // there, so those three facts live here rather than being restated in each.

    /// Where a blade attaches, as a fraction of the canvas out from `junction`.
    ///
    /// Measured off the template, whose petioles run 0.067 of the canvas width
    /// at ~32° off vertical. Steeper than it is wide, and close to the angle
    /// the blades themselves are tilted at, so the petiole runs nearly along
    /// the blade's axis and hands over to the midrib with a gentle bend. An
    /// early pass used 0.030 × 0.030 — 47° out — and the petiole had to swing
    /// back through 30° in its last few points to meet the midrib; that hook is
    /// what read as two strokes butted together.
    static let stalkOffset = CGSize(width: 0.032, height: 0.055)

    /// Where a blade attaches. Shared by the three types that need it — the
    /// shape that runs the petiole to it, the view that hangs the blade off it,
    /// and the tip calculation — rather than each rebuilding it from the fork.
    static func stalkPoint(mirrored: Bool, extended: CGFloat) -> CGPoint {
        let side: CGFloat = mirrored ? 1 : -1
        let fork = junction(extended: extended)
        return CGPoint(x: fork.x + stalkOffset.width * side, y: fork.y - stalkOffset.height)
    }

    /// Turns a vector given in canvas fractions. Rotated in square units: the
    /// canvas is wider than it is tall, so turning fractions of each axis
    /// directly would shear the angle.
    static func turned(_ vector: CGSize, by degrees: Double) -> CGSize {
        guard degrees != 0 else { return vector }
        let tall = 1 / aspectRatio
        let x = vector.width, y = vector.height * tall
        let angle = Angle(degrees: degrees).radians
        return CGSize(
            width: x * CGFloat(cos(angle)) - y * CGFloat(sin(angle)),
            height: (x * CGFloat(sin(angle)) + y * CGFloat(cos(angle))) / tall
        )
    }

    /// Blade box as a fraction of the canvas. The pair is deliberately uneven:
    /// the left blade runs larger and taller, as in the template.
    ///
    /// Sized so the tips land where the template's do once the tilt and the
    /// spine's own sweep are applied — its blades measure 103pt and 89pt on a
    /// 358×330 canvas, which is where these came from rather than from taste.
    static func leafSize(mirrored: Bool) -> CGSize {
        mirrored ? CGSize(width: 0.194, height: 0.257) : CGSize(width: 0.230, height: 0.312)
    }

    /// Degrees the blade is turned about its base — and so the direction the
    /// midrib leaves that base, which is the direction the petiole has to
    /// arrive along.
    ///
    /// The template's blades run 44° (left) and 55° (right) from vertical
    /// measured base-to-tip. The spine contributes ~23° of that on its own, by
    /// sweeping outward as it rises, so the box only has to be turned by the
    /// remainder. Chasing the full angle here instead would splay the blades
    /// without bending them, and they would read as two straight darts.
    static func leafTilt(mirrored: Bool, extended: CGFloat = 0) -> Double {
        let side: Double = mirrored ? 1 : -1
        // Straightening the spine takes sweep away from the chord; the box is
        // turned by what it loses so the blade still points where it did.
        return (mirrored ? 31 : -21) + side * spineSweep * Double(spineStraightness(extended: extended))
    }

    /// How much of the spine's sweep is taken back out, 0 keeping the full
    /// droop and 1 drawing a straight rib.
    ///
    /// The early references draw a seedling's leaves curving over — the tip
    /// carried well past the line of the base, which is what the cubic spine
    /// was built for. By phase 4 the same plant's leaves are nearly
    /// straight-ribbed lenses, the midrib running base to tip with the blade
    /// even either side of it.
    ///
    /// Only the rib straightens. The blade keeps its width: measured on the
    /// phase-4 reference its cotyledon is 0.515 across against its own length,
    /// where ours is 0.485 — the same leaf, near enough. An earlier pass read
    /// 0.33 off a scaled-down side-by-side and narrowed every blade to match a
    /// figure that was never there.
    static func spineStraightness(extended: CGFloat) -> CGFloat {
        let into = min(max(extended - 2, 0), 1)
        return 0.60 * into
    }

    /// Half-width of the midrib where it meets the petiole, as a fraction of
    /// the blade box.
    static let midribBaseHalfFactor: CGFloat = 0.011

    /// That same half-width in canvas units, for the petiole to taper into.
    static func midribBaseHalf(mirrored: Bool, canvasWidth: CGFloat) -> CGFloat {
        canvasWidth * leafSize(mirrored: mirrored).width * midribBaseHalfFactor
    }

    /// The far tip of one cotyledon, in canvas fractions, at a given point in
    /// the stem's climb — so anything placed beside the plant can be placed
    /// against the leaf itself and rise with it.
    static func cotyledonTip(mirrored: Bool, extended: CGFloat) -> CGPoint {
        let side: CGFloat = mirrored ? 1 : -1
        let box = leafSize(mirrored: mirrored)

        // Where the petiole hands over to the blade.
        let base = stalkPoint(mirrored: mirrored, extended: extended)
        // The spine's own tip inside that box, from its bottom centre — the
        // same numbers `LeafSpine` draws to.
        let reach = CGPoint(x: 0.50 * box.width * side, y: -0.94 * box.height)

        // Turned in square units. The canvas is wider than it is tall, so
        // rotating fractions of each axis directly would shear the angle.
        let tall = 1 / aspectRatio
        let angle = Angle(degrees: leafTilt(mirrored: mirrored, extended: extended)).radians
        let x = reach.x, y = reach.y * tall
        return CGPoint(
            x: base.x + x * CGFloat(cos(angle)) - y * CGFloat(sin(angle)),
            y: base.y + (x * CGFloat(sin(angle)) + y * CGFloat(cos(angle))) / tall
        )
    }

    // MARK: Stem

    /// The stem's foot, below the pile's crest so the mound covers it and the
    /// plant reads as coming out of the top of the stones.
    static let stemBase = CGPoint(x: 0.515, y: 0.705)

    /// How far the stem's middle bulges right, as a fraction of the canvas
    /// width. The template's stem leans left overall while bowing right.
    static let stemBow: CGFloat = 0.026

    /// How far the stem's centreline sits off the straight line from its foot
    /// to the fork, sampled every tenth of the way up from the foot, as a
    /// fraction of the stem's own length. Negative is to the left.
    ///
    /// Traced off the phase-3 reference, where the stem stops being a stalk and
    /// starts being a trunk. The shape is the point: the lean is concentrated
    /// low — out of the mound, peaking about a third of the way up — and the
    /// stem is straight above halfway. A quadratic bow can't say that; its
    /// deviation always peaks at the middle and falls off symmetrically, which
    /// is why this is a traced profile rather than another control point.
    static let stemLean: [CGFloat] = [
        0.000, -0.031, -0.051, -0.060, -0.042,
        -0.020, -0.002, 0.003, 0.004, 0.000, 0.000
    ]

    /// The stem's length at a point in the climb, in canvas *width* units — the
    /// lean is a fraction of it, and the canvas is wider than it is tall.
    static func stemLength(extended: CGFloat) -> CGFloat {
        (stemBase.y - junction(extended: extended).y) / aspectRatio
    }

    /// The centreline's sideways offset at `t`, measured from the foot, in
    /// canvas width fractions.
    ///
    /// Two curves blended by the stage: the early stem's gentle bulge to the
    /// right, and phase 3's lean to the left. The user sees one stem that
    /// starts to bend as the plant puts on height.
    /// The canopy's own profile, read off the reference's centreline rather than
    /// skeletonised out of a screenshot.
    ///
    /// **One left lobe, then one right lobe, and nothing after.** The reference
    /// turns left out of the soil to about a quarter of the way up, sweeps right
    /// in a single unbroken arc to roughly four fifths, and turns back left once
    /// into the fork. Two inflections. Its centreline, sampled every tenth:
    ///
    ///     .4825 .4643 .4518 .4529 .4717 .4908 .5034 .5113 .5133 .5086 .5016
    ///
    /// The first attempt at this had every value negative — the stem never
    /// crossed to the right of its chord at all, drifted further left over the
    /// last third, and was then pulled back to zero at the top to meet the fork.
    /// That pull is a third curve, sitting just under the bifurcation where the
    /// reference has none, and it is what made the two stems read as different
    /// plants. It came from skeletonising a PNG, which found the bends and lost
    /// which way they went.
    ///
    /// Scaled by the reference's 940×1120 viewBox against our own units, and
    /// paired with `forkX`, which carries the rightward finish this profile
    /// cannot.
    static let canopyLean: [CGFloat] = [
        0.000, -0.028, -0.048, -0.049, -0.026,
        -0.002, 0.013, 0.022, 0.022, 0.013, 0.000
    ]

    private static func lean(_ profile: [CGFloat], at t: CGFloat) -> CGFloat {
        let steps = CGFloat(profile.count - 1)
        let along = min(max(t, 0), 1) * steps
        let index = min(Int(along), profile.count - 2)
        let into = along - CGFloat(index)
        return profile[index] + (profile[index + 1] - profile[index]) * into
    }

    static func stemOffset(at t: CGFloat, extended: CGFloat) -> CGFloat {
        // The old quadratic's deviation from its chord, in closed form.
        let early = 2 * (1 - t) * t * stemBow

        let length = stemLength(extended: extended)
        let late = lean(stemLean, at: t) * length
        let canopy = lean(canopyLean, at: t) * length

        let into3 = min(max(extended - 1, 0), 1)
        let bowed = early * (1 - into3) + late * into3

        // Blended in over the last stage only, so stages 0-3 keep exactly the
        // stem they were drawn with.
        let into4 = min(max(extended - 3, 0), 1)
        return bowed * (1 - into4) + canopy * into4
    }

    /// The stem's centreline at `t`, in canvas fractions, measured from its
    /// foot. `VectorStemShape` draws the tube around this line and the shoots
    /// hang off it, so both have to be reading the same curve.
    static func stemPoint(at t: CGFloat, extended: CGFloat) -> CGPoint {
        let base = stemBase
        let head = junction(extended: extended)
        return CGPoint(
            x: base.x + (head.x - base.x) * t + stemOffset(at: t, extended: extended),
            y: base.y + (head.y - base.y) * t
        )
    }

    // MARK: Side shoots

    /// One leaflet on a side shoot.
    ///
    /// A shoot is built the way the reference draws it: one long petiole — the
    /// rachis — off the stem, which runs on into the terminal leaflet, with
    /// sub-petioles branching off it for the others. Hanging them all straight
    /// on the rachis instead is what had them bunched around one point.
    struct Leaflet {
        let mirrored: Bool
        /// Degrees off vertical the blade should run, measured off the
        /// reference before the spine's own sweep is taken out.
        let axis: Double
        /// Size as a fraction of the left cotyledon's blade box.
        let scale: CGFloat
        /// Where this leaflet's sub-petiole leaves the rachis. 1 is the rachis'
        /// own tip, where the terminal leaflet sits.
        let along: CGFloat
        /// How far that sub-petiole runs, as canvas fractions — negative height
        /// is upward. Zero for the terminal leaflet, which the rachis reaches
        /// by itself.
        let stalkRun: CGSize
        /// The stage this leaflet first opens at. `nil` means it is there from
        /// the moment its shoot is, which is true of every leaflet drawn before
        /// a fifth stage existed.
        var opensAt: SeedlingStage? = nil
        /// The stage it stops being drawn at, for a leaflet that a later stage
        /// replaces — the bough's bud gives way to the frond it becomes.
        var closesAt: SeedlingStage? = nil

        var hasSubPetiole: Bool { stalkRun != .zero }
    }

    /// A shoot off the side of the stem, and the stage it first appears at.
    struct Shoot: Identifiable {
        let id: Int
        /// The stage this shoot grows at; before it, the shoot isn't drawn.
        let stage: SeedlingStage
        /// Fraction of the way up the stem it leaves — so it rides up with the
        /// stem as later stages lengthen it, rather than staying put.
        let attachment: CGFloat
        /// How far the rachis runs, as canvas fractions. Width is signed: the
        /// left-hand shoot runs out negative.
        let reach: CGSize
        /// Degrees the whole shoot is turned clockwise about where it leaves
        /// the stem — rachis, sub-petioles and blades together, so the cluster
        /// swings as one piece rather than the blades twisting on fixed stalks.
        let turn: Double
        let leaflets: [Leaflet]

        /// The leaflet the rachis runs into, so that stem, stalk and midrib are
        /// one line — the rachis' end tangent is aimed along this one's axis.
        var carrier: Leaflet { leaflets.first { !$0.hasSubPetiole } ?? leaflets[0] }
    }

    /// Degrees the spine sweeps toward its own side over the blade's length. A
    /// leaflet asked to run at `axis` only needs the box turned by the rest —
    /// tilting it the full amount would splay the leaflets without bending them.
    static let spineSweep: Double = 23

    /// Both shoots, measured off their references.
    ///
    /// The right one is phase 2's: the up-left leaflet branches at 0.62 of the
    /// rachis on a stalk that runs almost straight up, the terminal one carries
    /// on from the tip, and the drooping one branches at 0.34 on a longer stalk
    /// that runs out level and dipping.
    ///
    /// The left one is phase 3's, and is the same shape with the middle leaflet
    /// left off — a pair rather than a trio — mirrored and set lower down the
    /// stem. In the phase-3 reference the shoots sit at 0.61 and 0.36 of the
    /// stem's length; ours keep that gap a little lower down, where our stem
    /// carries its cotyledons.
    static let shoots: [Shoot] = [
        Shoot(
            id: 0,
            stage: .shoot,
            attachment: 0.52,
            // Longer than the reference's own rachis, because the up-left
            // leaflet has two constraints that pull against each other on a
            // short one: branch late and its blade clears the stem but grows
            // into the terminal leaflet; branch early and the reverse. The
            // rachis carries the branch point out at 0.77 per unit of length,
            // so lengthening it is what buys room for both at once.
            reach: CGSize(width: 0.068, height: 0.088),
            // Swung down off the stem: its up-left leaflet was crossing the
            // stem once the plant grew tall enough to sit behind it, and then
            // reaching into the cotyledon above once its stalk was long enough
            // to stand clear of the terminal leaflet. Turning the shoot moves
            // the whole cluster out of that wedge at once — the leaflets keep
            // the spacing they were given, since they rotate with it.
            turn: 18,
            leaflets: [
                // Branches back from the tip, not just under it. At 0.78 on a
                // stalk this short its blade base sat ~6 canvas units from the
                // terminal leaflet's while both blades are ~25 wide, so the two
                // grew into each other — plainly once `shootGrowth` scaled the
                // pair up at stage 2. Same defect, same fix as the bough shoot's
                // bud below. The stalk is what carries it clear: branching
                // earlier still would walk the blade back into the stem, since
                // the rachis is what holds it out, and the two blades together
                // are ~20 units wide at the base. Running the stalk near-straight
                // up for 0.074 stands the bases ~18 apart without moving the
                // blade any closer to the stem.
                Leaflet(mirrored: false, axis: -25, scale: 0.23, along: 0.66, stalkRun: CGSize(width: 0.004, height: -0.074)),
                Leaflet(mirrored: true, axis: 50, scale: 0.26, along: 1, stalkRun: .zero),
                Leaflet(mirrored: true, axis: 88, scale: 0.23, along: 0.34, stalkRun: CGSize(width: 0.040, height: 0.008))
            ]
        ),
        Shoot(
            id: 1,
            stage: .branch,
            attachment: 0.34,
            reach: CGSize(width: -0.052, height: 0.068),
            turn: 0,
            leaflets: [
                Leaflet(mirrored: false, axis: -50, scale: 0.24, along: 1, stalkRun: .zero),
                Leaflet(mirrored: false, axis: -88, scale: 0.22, along: 0.34, stalkRun: CGSize(width: -0.038, height: 0.008))
            ]
        ),
        Shoot(
            id: 2,
            stage: .bough,
            // High on the stem, just under the cotyledons, where the phase-4
            // reference puts it — 0.70 of the way up against the right shoot's
            // 0.52 and the left's 0.34.
            attachment: 0.70,
            // Traced off the phase-4 reference row by row: its rachis runs
            // 0.199 of the stem's length at 39° off vertical, and its leaf
            // carries on from the tip for the same distance again at 46°.
            //
            // Ours runs half as long again as that. Drawn to the reference's
            // own figure it measured correct and still read short: our blades
            // are 0.485 wide against the drawing's 0.38, so the fuller base
            // sweeps back over the last of the stalk and swallows it. The extra
            // length is what the blade covers.
            reach: CGSize(width: -0.079, height: 0.104),
            turn: 0,
            leaflets: [
                // The leaf is *terminal* — the rachis runs its whole length into
                // it. Hung off the side instead, as an earlier pass had it, only
                // the stretch before the branch point shows and the petiole
                // reads half its length.
                //
                // At 0.29 of a cotyledon it is as long as the stalk that carries
                // it. Drawn shorter, it and the bud sat on top of each other.
                Leaflet(mirrored: false, axis: -46, scale: 0.29, along: 1, stalkRun: .zero),
                // The middle leaf, hanging below the rachis and pointing back
                // down-left. The reference draws this shoot with *three*
                // leaflets — a big terminal one, this, and the small one
                // opposite — but only at the canopy. Opening it earlier would
                // redraw the bough at stage 3, which is not this stage's to
                // change.
                Leaflet(mirrored: false, axis: -92, scale: 0.19, along: 0.54,
                        stalkRun: CGSize(width: -0.030, height: 0.013), opensAt: .canopy),
                // The bud: this shoot is the newest growth and its second leaf
                // has not opened. It forks from the rachis' own tip on a short
                // upright stalk — a third of the way back down it, as an earlier
                // pass had it, put it inside the leaf.
                //
                // It branches well before the tip, not at it. The reference can
                // put both at the same point because its leaf is narrow where
                // it starts; ours is not, and a bud leaving the rachis at the
                // tip comes out *inside* the leaf's base and crosses it.
                // The bud, exactly as it was drawn for the bough: this shoot is
                // the newest growth at *that* stage and its second leaf has not
                // opened. It gives way at the canopy, by which point it has.
                Leaflet(mirrored: false, axis: 4, scale: 0.065, along: 0.58,
                        stalkRun: CGSize(width: 0.005, height: -0.040), closesAt: .canopy),
                // What the bud becomes: an open leaf on the other side of the
                // rachis, low down it and pointing up-right, which is what makes
                // the cluster read as a frond with a leaf either side rather
                // than a stalk with a lump.
                Leaflet(mirrored: true, axis: 26, scale: 0.115, along: 0.31,
                        stalkRun: CGSize(width: 0.026, height: -0.024), opensAt: .canopy)
            ]
        ),
        Shoot(
            id: 3,
            stage: .canopy,
            // Measured, after a first pass put it at 0.80 by reasoning about
            // which side the stem "should" alternate to. Skeletonising the
            // reference put it at 0.541 — 0.259 out, by far the largest error in
            // the drawing, and the reason the stage read as a different plant.
            // Its neighbours were already within 0.04 of the reference; this one
            // shoot was the whole discrepancy.
            attachment: 0.541,
            // The smallest cluster on the plant: the reference traces 0.130 from
            // stem to leaf tip against 0.21 and 0.32 for the two beside it. And
            // near-upright — +25.8° off vertical, where the others splay past
            // 50° — so the rachis is mostly rise and only a little reach.
            reach: CGSize(width: 0.034, height: 0.072),
            turn: 0,
            leaflets: [
                // Two tiny leaves, not one. This is the newest growth and the
                // reference gives it a pair — the smallest on the plant, but a
                // pair, which is what says "just opened" rather than "stunted".
                //
                // The reference's blades here measure 2.62 long to wide against
                // the cotyledon's 2.08: side leaflets run narrower than the
                // leaves that opened first, not merely smaller.
                // Scaled to the reference rather than to the word "tiny": its
                // blade here measures 0.55 of a cotyledon, which is small
                // against the leaves above it but not a speck. At 0.145 this
                // pair was a third of that and read as debris.
                Leaflet(mirrored: true, axis: 30, scale: 0.30, along: 1, stalkRun: .zero),
                Leaflet(mirrored: false, axis: -34, scale: 0.23, along: 0.46, stalkRun: CGSize(width: -0.026, height: -0.008))
            ]
        )
    ]

    /// The shoots grown by a given point in the climb — a shoot appears with
    /// the stage that grows it and stays for every stage after.
    static func shoots(by extended: CGFloat) -> [Shoot] {
        shoots.filter { CGFloat($0.stage.rawValue) <= extended + 0.001 }
    }

    /// Degrees to turn a leaflet's blade box by, including the turn on the
    /// shoot that carries it.
    static func leafletTilt(_ leaflet: Leaflet, of shoot: Shoot, extended: CGFloat = 0) -> Double {
        let side: Double = leaflet.mirrored ? 1 : -1
        let kept = 1 - Double(spineStraightness(extended: extended))
        // Minus: `axis` is the chord the blade should end up on, and the spine
        // sweeps *toward* its own side over the blade's length, so the box is
        // turned back by whatever sweep is still in play. Adding it instead
        // swings the leaflet twice the sweep the wrong way — and does so at
        // every stage, not just the straightened ones.
        return leaflet.axis - side * spineSweep * kept + shoot.turn
    }

    /// How much bigger a shoot is drawn than when it first appeared.
    ///
    /// A shoot is *not* fixed at the size it arrived. Measured across the two
    /// references, the right-hand shoot stands at 0.270 of a cotyledon in phase
    /// 2 and 0.373 in phase 3 — it goes on growing for a stage after the one
    /// that put it out, and its rachis lengthens with it. Left frozen, it reads
    /// as a sprig the plant grew past. Each shoot is declared at its own birth
    /// size, so this is measured from *its* stage, not from the start.
    /// A shoot keeps growing for as long as the plant does, rather than for one
    /// stage and then stopping.
    ///
    /// Measured against the reference: normalise every blade by that drawing's
    /// own cotyledon and its side leaves run 0.48 to 0.71 of one. Ours ran 0.26
    /// to 0.40 — about half — which is most of why the plant read as a different
    /// species even with the stem weight and the attachments right.
    ///
    /// Capping at one stage was what held them there: the oldest shoot stopped
    /// growing three stages before the plant did. Letting it run to three puts
    /// the first shoot at 2.14x by the canopy, which lands it near the top of
    /// the reference's range while the newest sits at the bottom — the spread
    /// the drawing actually has.
    static func shootGrowth(_ shoot: Shoot, extended: CGFloat) -> CGFloat {
        let stagesOn = min(max(extended - CGFloat(shoot.stage.rawValue), 0), 1)
        // Applied only over the last stage, so every earlier one is left exactly
        // as it was drawn. Raising the cap to three stages did the same job and
        // changed stages 2 and 3 on the way past, which is not a trade worth
        // making for a stage nobody had complained about.
        // Side leaves do not keep pace with the stem. Normalise both drawings
        // to the same height and the reference's run 13.1%, 9.3%, 8.3% of it
        // against cotyledons at 26.4% and 21.5% — two dominant leaves and then a
        // steep drop. Ours ran 29.2, 24.1, 23.1 against 30.1: nearly flat, five
        // big leaves instead of two.
        //
        // An earlier pass read the opposite and *grew* them, off eroded blade
        // cores that under-measured the reference's cotyledon. The plant gets
        // taller at this stage; the leaves stay the size they were, so their
        // share of it falls.
        let canopy = min(max(extended - 3, 0), 1)
        return (1 + 0.38 * stagesOn) * (1 - 0.20 * canopy)
    }

    /// A leaflet's blade size at a point in the climb, as a fraction of a
    /// cotyledon's box.
    static func leafletScale(_ leaflet: Leaflet, of shoot: Shoot, extended: CGFloat) -> CGFloat {
        leaflet.scale * shootGrowth(shoot, extended: extended)
    }

    /// A petiole as a curve: where it starts, its control point, where it ends.
    typealias Stalk = (root: CGPoint, control: CGPoint, tip: CGPoint)

    /// A curve from `root` to `tip` arriving along `axis` degrees off vertical,
    /// which is how every petiole in this drawing is built — the blade's midrib
    /// carries on in exactly that direction, so the two read as one stroke.
    private static func stalk(from root: CGPoint, to tip: CGPoint, arrivingAt axis: Double) -> Stalk {
        let tilt = Angle(degrees: axis).radians
        let heading = CGPoint(x: CGFloat(sin(tilt)), y: -CGFloat(cos(tilt)))
        let reach = hypot(tip.x - root.x, tip.y - root.y) * 0.45
        return (root, CGPoint(x: tip.x - heading.x * reach, y: tip.y - heading.y * reach), tip)
    }

    /// Where a shoot leaves the stem at a given point in the climb.
    ///
    /// A shoot stays where it grew. The stem lengthens *above* it, so its height
    /// above the ground is fixed and its share of the stem falls as the plant
    /// gets taller — which is why `Shoot.attachment` is read as a fraction of
    /// the stem *at that shoot's own stage*, not of the stem today.
    ///
    /// Held as a fixed fraction, as it was, every shoot slides up with each
    /// stage and they bunch under the crown. The phase-4 reference puts its
    /// three at 0.70, 0.36 and 0.22 of the stem; ours sat at 0.70, 0.52 and
    /// 0.34. Carrying the height instead lands the right-hand shoot on 0.36 to
    /// the decimal, and leaves each shoot exactly where it was at the stage that
    /// grew it.
    static func attachment(of shoot: Shoot, extended: CGFloat) -> CGFloat {
        let born = stemLength(extended: CGFloat(shoot.stage.rawValue))
        let now = max(stemLength(extended: extended), 0.0001)
        return min(0.95, shoot.attachment * born / now)
    }

    /// A shoot's rachis, in canvas fractions. `VectorStemShape` strokes it and
    /// `SeedlingView` reads points off it to seat the sub-petioles — placing
    /// those on the straight line between its ends instead leaves them hanging
    /// beside it, since it bows away from that line by most of its own width.
    static func rachis(of shoot: Shoot, extended: CGFloat) -> Stalk {
        let origin = stemPoint(at: attachment(of: shoot, extended: extended), extended: extended)
        // Rooted a little inside the stem, so the end cap is buried in the tube
        // rather than meeting its edge at an angle.
        let root = CGPoint(x: origin.x, y: origin.y + 0.012)
        let grown = shootGrowth(shoot, extended: extended)
        let run = turned(CGSize(width: shoot.reach.width, height: -shoot.reach.height), by: shoot.turn)
        let tip = CGPoint(x: origin.x + run.width * grown, y: origin.y + run.height * grown)
        return stalk(from: root, to: tip, arrivingAt: leafletTilt(shoot.carrier, of: shoot, extended: extended))
    }

    /// One leaflet's sub-petiole: from its branch point on the rachis to the
    /// blade's base. The terminal leaflet has none — the rachis is its petiole.
    static func subPetiole(_ leaflet: Leaflet, of shoot: Shoot, extended: CGFloat) -> Stalk? {
        guard leaflet.hasSubPetiole else { return nil }
        let branch = point(at: leaflet.along, on: rachis(of: shoot, extended: extended))
        let grown = shootGrowth(shoot, extended: extended)
        let run = turned(leaflet.stalkRun, by: shoot.turn)
        let tip = CGPoint(x: branch.x + run.width * grown, y: branch.y + run.height * grown)
        return stalk(from: branch, to: tip, arrivingAt: leafletTilt(leaflet, of: shoot, extended: extended))
    }

    /// Where a leaflet's blade starts: the end of its sub-petiole, or the
    /// rachis' tip for the terminal one.
    static func leafletBase(_ leaflet: Leaflet, of shoot: Shoot, extended: CGFloat) -> CGPoint {
        subPetiole(leaflet, of: shoot, extended: extended)?.tip ?? rachis(of: shoot, extended: extended).tip
    }

    /// The far tip of a leaflet, in canvas fractions — the counterpart of
    /// `cotyledonTip`, for placing things against a shoot.
    static func leafletTip(_ leaflet: Leaflet, of shoot: Shoot, extended: CGFloat) -> CGPoint {
        let base = leafletBase(leaflet, of: shoot, extended: extended)
        let box = leafSize(mirrored: false)
        let side: CGFloat = leaflet.mirrored ? 1 : -1
        let scale = leafletScale(leaflet, of: shoot, extended: extended)
        let reach = CGPoint(
            x: 0.50 * box.width * scale * side,
            y: -0.94 * box.height * scale
        )

        let tall = 1 / aspectRatio
        let angle = Angle(degrees: leafletTilt(leaflet, of: shoot, extended: extended)).radians
        let x = reach.x, y = reach.y * tall
        return CGPoint(
            x: base.x + x * CGFloat(cos(angle)) - y * CGFloat(sin(angle)),
            y: base.y + (x * CGFloat(sin(angle)) + y * CGFloat(cos(angle))) / tall
        )
    }

    /// The point a shoot's cluster reaches furthest out to, on its own side, so
    /// anything set beside it clears every leaflet rather than the one that
    /// happens to be listed last.
    /// Whether a leaflet is drawn at this point in the climb.
    ///
    /// Leaflets had no stage of their own, so adding one to a shoot added it to
    /// *every* stage that shoot appears in — which is how giving the bough its
    /// third leaf silently changed stage 3. A leaflet now says when it opens and
    /// when, if ever, it gives way.
    static func isOpen(_ leaflet: Leaflet, extended: CGFloat) -> Bool {
        if let opens = leaflet.opensAt, extended < CGFloat(opens.rawValue) - 0.001 { return false }
        if let closes = leaflet.closesAt, extended >= CGFloat(closes.rawValue) - 0.001 { return false }
        return true
    }

    static func openLeaflets(of shoot: Shoot, extended: CGFloat) -> [Leaflet] {
        shoot.leaflets.filter { isOpen($0, extended: extended) }
    }

    static func shootExtent(of shoot: Shoot, extended: CGFloat) -> CGPoint {
        let visible = openLeaflets(of: shoot, extended: extended)
        let tips = (visible.isEmpty ? shoot.leaflets : visible)
            .map { leafletTip($0, of: shoot, extended: extended) }
        let outward = shoot.reach.width < 0
            ? tips.min { $0.x < $1.x }
            : tips.max { $0.x < $1.x }
        let middle = tips.map(\.y).reduce(0, +) / CGFloat(max(1, tips.count))
        return CGPoint(x: outward?.x ?? 0, y: middle)
    }

    /// Point at `t` along a stalk.
    static func point(at t: CGFloat, on stalk: Stalk) -> CGPoint {
        let mt = 1 - t
        return CGPoint(
            x: mt * mt * stalk.root.x + 2 * mt * t * stalk.control.x + t * t * stalk.tip.x,
            y: mt * mt * stalk.root.y + 2 * mt * t * stalk.control.y + t * t * stalk.tip.y
        )
    }
}

// MARK: - Drawing primitives

/// A pen stroke as geometry: a filled sliver whose width tapers along its
/// length. Constant-width strokes are what made the veins look ruled — a drawn
/// line thins as the pen lifts.
enum InkStroke {
    static func quadPoints(from a: CGPoint, control c: CGPoint, to b: CGPoint, steps: Int = 12) -> [CGPoint] {
        (0...steps).map { index in
            let t = CGFloat(index) / CGFloat(steps)
            let mt = 1 - t
            return CGPoint(
                x: mt * mt * a.x + 2 * mt * t * c.x + t * t * b.x,
                y: mt * mt * a.y + 2 * mt * t * c.y + t * t * b.y
            )
        }
    }

    static func sliver(along points: [CGPoint], startHalf: CGFloat, endHalf: CGFloat) -> Path {
        var path = Path()
        guard points.count > 1 else { return path }

        // Wound the same way round as the stem tube in `VectorStemShape`
        // (hence `dy, -dx` rather than the usual `-dy, dx`). A sliver that
        // winds the other way cancels the tube wherever the two overlap under
        // non-zero fill, and both live in one path — which is what put a white
        // nick across the stem exactly where the petioles leave it. Winding is
        // invisible for a sliver filled on its own, so nothing else changes.
        func normal(at index: Int) -> CGPoint {
            let a = points[max(0, index - 1)]
            let b = points[min(points.count - 1, index + 1)]
            let dx = b.x - a.x, dy = b.y - a.y
            let length = max(0.0001, sqrt(dx * dx + dy * dy))
            return CGPoint(x: dy / length, y: -dx / length)
        }

        var left: [CGPoint] = []
        var right: [CGPoint] = []
        for index in points.indices {
            let t = CGFloat(index) / CGFloat(points.count - 1)
            let half = startHalf + (endHalf - startHalf) * t
            let n = normal(at: index)
            left.append(CGPoint(x: points[index].x + n.x * half, y: points[index].y + n.y * half))
            right.append(CGPoint(x: points[index].x - n.x * half, y: points[index].y - n.y * half))
        }
        path.move(to: left[0])
        for point in left.dropFirst() { path.addLine(to: point) }
        for point in right.reversed() { path.addLine(to: point) }
        path.closeSubpath()
        return path
    }
}

// MARK: - Leaf

/// A leaf built around a curved spine.
///
/// The blade is the spine offset sideways by a width that swells to a maximum
/// below halfway and closes to nothing at both ends. Constructing it this way —
/// rather than as two curves between fixed corners — is what gives the blade its
/// arc: a straight-axis shape reads as an oval no matter how the controls are
/// tuned, which is what the earlier passes kept producing.
///
/// The spine is a cubic because the template's leaf does two different things
/// along its length: it leaves the petiole travelling straight up the blade
/// box, then flattens steadily until the tip is running ~45° further over than
/// the base — a blade succumbing to its own weight. A quadratic can set the
/// direction at one end or the other, not both, and the version that only had
/// a tip control came out as a straight dart pointing up and away.
///
/// `mirrored` flips the curve, so a pair of leaves aren't the same stamp twice.
struct LeafSpine {
    let rect: CGRect
    let mirrored: Bool
    /// 0 keeps the full drooping sweep, 1 draws a straight rib. See
    /// `SeedlingArt.spineStraightness`.
    var straighten: CGFloat = 1 - 1

    /// Negative bends the leaf to the left. The left blade is the unmirrored
    /// one, so it takes the negative side.
    var side: CGFloat { mirrored ? 1 : -1 }

    /// Point at `t` (0 = stalk, 1 = tip) along the spine.
    func point(at t: CGFloat) -> CGPoint {
        // Base sits exactly at the box's bottom centre, which is the point the
        // view positions on the petiole tip — offset it and the leaf floats.
        let base = CGPoint(x: rect.midX, y: rect.maxY)
        // Straight above the base, so the midrib leaves at exactly the box's
        // tilt and the petiole aimed at that tilt meets it without a corner.
        // Likewise the first control: the chord is 0.224 across at its height.
        let lift = CGPoint(x: rect.midX + rect.width * 0.224 * straighten * side, y: rect.maxY - rect.height * 0.42)
        // Where the blade is already leaning over…
        // Pulled toward the straight line from base to tip as `straighten`
        // rises: that line passes 0.383 of the way across at this height.
        let shoulderX = 0.30 + (0.383 - 0.30) * straighten
        let shoulder = CGPoint(x: rect.midX + rect.width * shoulderX * side, y: rect.minY + rect.height * 0.28)
        // …and the tip, held down off the top of the box so the last stretch
        // runs out almost sideways rather than climbing to a peak.
        let tip = CGPoint(x: rect.midX + rect.width * 0.50 * side, y: rect.minY + rect.height * 0.06)

        let mt = 1 - t
        let (a, b, c, d) = (mt * mt * mt, 3 * mt * mt * t, 3 * mt * t * t, t * t * t)
        return CGPoint(
            x: a * base.x + b * lift.x + c * shoulder.x + d * tip.x,
            y: a * base.y + b * lift.y + c * shoulder.y + d * tip.y
        )
    }

    /// Half-width of the blade at `t`, traced off the template: measured
    /// perpendicular to the left blade's axis it peaks at 0.243 of the blade's
    /// length, four tenths of the way up, and falls away over the whole
    /// remaining stretch — most of a leaf that size is taper.
    ///
    /// The exponent places that peak — and it has to place it earlier than the
    /// number suggests, because the spine bows away from the line the template
    /// was measured against, so a given `t` sits slightly further along that
    /// line than along the spine. 0.66 puts the peak at 0.35 of the spine,
    /// which measures back as 0.40. The `1 - t⁵` term does the tip: a sine
    /// alone falls away too slowly past the peak — it was carrying ~8% too much
    /// width from t = 0.7 out, and still had 15% left at t = 0.95, so the blade
    /// stayed full and rounded where the template's is already mostly point.
    ///
    /// Note the blade is symmetrical about the spine. The template *looks*
    /// bellied — measured from base-to-tip it runs 31px on one side against 19
    /// on the other — but that is the spine bowing away from that line, not an
    /// uneven blade, and reproducing it as an uneven blade on top of an already
    /// bowed spine doubles it.
    func halfWidth(at t: CGFloat) -> CGFloat {
        rect.width * 0.30 * sin(.pi * pow(t, 0.66)) * (1 - pow(t, 5))
    }

    /// Unit normal to the spine at `t`, for offsetting the outline.
    func normal(at t: CGFloat) -> CGPoint {
        let delta: CGFloat = 0.02
        let a = point(at: max(0, t - delta))
        let b = point(at: min(1, t + delta))
        let dx = b.x - a.x, dy = b.y - a.y
        let length = max(0.0001, sqrt(dx * dx + dy * dy))
        return CGPoint(x: -dy / length, y: dx / length)
    }
}

struct LeafBlade: Shape {
    var mirrored = false
    var straighten: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let spine = LeafSpine(rect: rect, mirrored: mirrored, straighten: straighten)
        let steps = 26
        var path = Path()

        var edge: [CGPoint] = []
        for index in 0...steps {
            let t = CGFloat(index) / CGFloat(steps)
            let centre = spine.point(at: t)
            let normal = spine.normal(at: t)
            let half = spine.halfWidth(at: t)
            edge.append(CGPoint(x: centre.x + normal.x * half, y: centre.y + normal.y * half))
        }
        for index in stride(from: steps, through: 0, by: -1) {
            let t = CGFloat(index) / CGFloat(steps)
            let centre = spine.point(at: t)
            let normal = spine.normal(at: t)
            let half = spine.halfWidth(at: t)
            edge.append(CGPoint(x: centre.x - normal.x * half, y: centre.y - normal.y * half))
        }

        path.move(to: edge[0])
        for point in edge.dropFirst() { path.addLine(to: point) }
        path.closeSubpath()
        return path
    }
}

/// The midrib alone: a dark tapered sliver continuing the petiole's line up the
/// blade, thinning to nothing at the tip.
struct LeafMidrib: Shape {
    var mirrored = false
    var straighten: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let spine = LeafSpine(rect: rect, mirrored: mirrored, straighten: straighten)
        // From t = 0, the blade base, which is the point the petiole runs to —
        // start it any higher and the vessel breaks in the middle of the leaf.
        let points = (0...16).map { spine.point(at: CGFloat($0) / 16 * 0.99) }
        return InkStroke.sliver(
            along: points,
            startHalf: rect.width * SeedlingArt.midribBaseHalfFactor,
            endHalf: rect.width * 0.0012
        )
    }
}

/// Secondary veins and their venules, matching the template's pinnate pattern:
/// each vein leaves the midrib at ~40 degrees, sweeping toward the tip, and
/// because every one is the *midrib tangent* rotated by that same angle, they
/// come out mutually parallel — which is what the template's venation is.
struct LeafVeins: Shape {
    var mirrored = false
    var straighten: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let spine = LeafSpine(rect: rect, mirrored: mirrored, straighten: straighten)
        var path = Path()

        /// Unit tangent along the midrib at `t`, pointing toward the tip.
        func tangent(at t: CGFloat) -> CGPoint {
            let a = spine.point(at: max(0, t - 0.02))
            let b = spine.point(at: min(1, t + 0.02))
            let dx = b.x - a.x, dy = b.y - a.y
            let length = max(0.0001, sqrt(dx * dx + dy * dy))
            return CGPoint(x: dx / length, y: dy / length)
        }

        let branchAngle: CGFloat = 0.70   // ~40 degrees off the midrib
        let origins: [CGFloat] = [0.10, 0.24, 0.38, 0.53]
        let venuleCounts = [3, 2, 1, 0]   // densest at the petiole end

        for (index, start) in origins.enumerated() {
            let origin = spine.point(at: start)
            let along = tangent(at: start)
            // Slight alternation in length; the angle never changes.
            let lengthScale: CGFloat = index % 2 == 0 ? 1.0 : 0.78
            let width = rect.width * (index % 2 == 0 ? 0.0058 : 0.0046)

            for direction in [CGFloat(-1), 1] {
                let angle = direction * branchAngle
                let veinDirection = CGPoint(
                    x: along.x * cos(angle) - along.y * sin(angle),
                    y: along.x * sin(angle) + along.y * cos(angle)
                )
                // Long enough to approach the edge, never to cross it: the
                // perpendicular reach is length * sin(40°).
                let length = spine.halfWidth(at: min(0.9, start + 0.14)) * 1.15 * lengthScale
                let end = CGPoint(x: origin.x + veinDirection.x * length, y: origin.y + veinDirection.y * length)
                // A whisper of forward bow so they aren't ruled lines.
                let control = CGPoint(
                    x: origin.x + veinDirection.x * length * 0.5 + along.x * length * 0.10,
                    y: origin.y + veinDirection.y * length * 0.5 + along.y * length * 0.10
                )
                let veinPoints = InkStroke.quadPoints(from: origin, control: control, to: end)
                path.addPath(InkStroke.sliver(along: veinPoints, startHalf: width, endHalf: width * 0.08))

                // Venules: shorter, thinner branches splitting off the vein and
                // swinging a further ~20 degrees forward, so they stay parallel
                // to each other too.
                for venule in 0..<venuleCounts[index] {
                    let at = 3 + venule * 3
                    guard at < veinPoints.count - 2 else { continue }
                    let from = veinPoints[at]
                    let extra = direction * -0.35   // back toward the midrib line = tip-ward
                    let venuleDirection = CGPoint(
                        x: veinDirection.x * cos(extra) - veinDirection.y * sin(extra),
                        y: veinDirection.x * sin(extra) + veinDirection.y * cos(extra)
                    )
                    let venuleLength = length * 0.34 * (1 - CGFloat(venule) * 0.18)
                    let venuleEnd = CGPoint(
                        x: from.x + venuleDirection.x * venuleLength,
                        y: from.y + venuleDirection.y * venuleLength
                    )
                    let venuleControl = CGPoint(
                        x: from.x + venuleDirection.x * venuleLength * 0.5,
                        y: from.y + venuleDirection.y * venuleLength * 0.5
                    )
                    let venulePoints = InkStroke.quadPoints(from: from, control: venuleControl, to: venuleEnd, steps: 6)
                    path.addPath(InkStroke.sliver(along: venulePoints, startHalf: width * 0.40, endHalf: width * 0.05))
                }
            }
        }
        return path
    }
}

// MARK: - Stem

/// The stem as a tube — two offset curves closed at the ends. It rises out of
/// the *top* of the stone pile (the base is below the crest, and the mound is
/// drawn over it), and forks at the top into the two petioles.
struct VectorStemShape: Shape {
    /// 0…1, how much of the stem has grown out of the soil.
    var progress: Double
    /// 0…1 between the two stages' forks. A `Shape`'s `animatableData` is
    /// interpolated every frame, which is what lets the stem lengthen visibly
    /// rather than jump to its new height.
    var extended: CGFloat = 0
    /// 0…1, how much of *this stage's* shoot has grown: the rachis extends
    /// first and each sub-petiole follows as it passes their branch points.
    var shootProgress: Double = 0

    /// The stage being grown into. Shoots from earlier stages are drawn whole
    /// and this one unfolds — deriving that from `extended` instead looks right
    /// until a later stage animates, at which point the earlier shoot blanks
    /// and grows a second time.
    var growing: Int = 0

    var animatableData: AnimatablePair<Double, AnimatablePair<CGFloat, Double>> {
        get { AnimatablePair(progress, AnimatablePair(extended, shootProgress)) }
        set {
            progress = newValue.first
            extended = newValue.second.first
            shootProgress = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard progress > 0.001 else { return path }

        let w = rect.width, h = rect.height
        // The stem's foot sits below the pile's crest, so the mound drawn over
        // it is what makes the stem emerge from the top of the stones.
        let junction = SeedlingArt.junction(extended: extended)
        let fork = CGPoint(
            x: rect.minX + w * junction.x,
            y: rect.minY + h * junction.y
        )

        let baseHalf = w * 0.0082
        // The canopy's stem barely tapers, because the reference's barely does:
        // measured across its own span it runs 0.0157 of the canvas at the foot
        // and 0.0140 at the fork, a ratio of 1.12 — a stroke of near-constant
        // weight rather than a wedge. At 0.40 it reached the fork at 1.67 and
        // read as a spike with leaves stuck on it.
        //
        // Eased in over the last stage rather than applied throughout. Changed
        // outright it thickened the stem at *every* stage, which is shared
        // geometry being altered to fix one drawing — the exact trap `CLAUDE.md`
        // warns about, and it went unnoticed until the stages were diffed
        // against a build from before any of this.
        let taper = 0.40 - 0.28 * min(max(extended - 3, 0), 1)
        let headHalf = baseHalf * (1 - taper * progress)

        // Built along the shared centreline rather than as its own curve: the
        // stem's shape changes with the stage, and a tube drawn to a private
        // quadratic would part company with the shoots hanging off it.
        let spine = stride(from: 0.0, through: 1.0, by: 1.0 / 24).map { step -> CGPoint in
            let point = SeedlingArt.stemPoint(at: CGFloat(step) * CGFloat(progress), extended: extended)
            return CGPoint(x: rect.minX + w * point.x, y: rect.minY + h * point.y)
        }
        path.addPath(InkStroke.sliver(along: spine, startHalf: baseHalf, endHalf: headHalf))

        // Petioles: filled tapered tubes, not hairline strokes — they pick up
        // the stem's width at the fork and thin toward each blade, so stem,
        // petiole and midrib read as one continuous vessel.
        //
        // Two things have to line up at the blade end for that to hold, and the
        // first is what was making the petiole and the midrib look like
        // separate parts:
        //
        // - It arrives at the blade base travelling along the blade's own axis.
        //   The old curve's end tangent was `end - control` ≈ (0.021w, -0.004h)
        //   — very nearly horizontal — while the midrib leaves that same point
        //   at the blade's tilt, 17° or 27° off vertical. That ~50° turn *at*
        //   the joint is a kink no amount of width-matching hides.
        // - It ends at exactly the midrib's starting width.
        if progress > 0.9 {
            for mirrored in [false, true] {
                let side: CGFloat = mirrored ? 1 : -1
                let stalk = SeedlingArt.stalkPoint(mirrored: mirrored, extended: extended)
                let tip = CGPoint(x: rect.minX + w * stalk.x, y: rect.minY + h * stalk.y)
                // Rooted on the fork itself, where the tube's flat top is: root
                // it lower and that top is left standing between the two arms
                // as a square stub.
                let root = fork

                // Unit vector the midrib leaves the blade base along.
                let tilt = Angle(degrees: SeedlingArt.leafTilt(mirrored: mirrored, extended: extended)).radians
                let axis = CGPoint(x: CGFloat(sin(tilt)), y: -CGFloat(cos(tilt)))
                // Pulling the control point back down that axis is what sets
                // the end tangent; 0.45 of the span leaves the petiole leaving
                // the stem at ~38°/30° and straightening into the blade.
                let reach = hypot(tip.x - root.x, tip.y - root.y) * 0.45
                let control = CGPoint(x: tip.x - axis.x * reach, y: tip.y - axis.y * reach)

                path.addPath(InkStroke.sliver(
                    along: InkStroke.quadPoints(from: root, control: control, to: tip, steps: 12),
                    startHalf: headHalf,
                    endHalf: SeedlingArt.midribBaseHalf(mirrored: mirrored, canvasWidth: w)
                ))
            }
        }

        // The side shoots, by the same rules as a petiole: rooted inside the
        // tube, arriving at the tip along the axis of the leaflet that carries
        // on from it, so stem, stalk and that leaflet's midrib are one line.
        if progress > 0.9 {
            /// A stalk in canvas fractions, sampled into view coordinates and
            /// cut off at `grown` — a half-grown stalk is the same curve, drawn
            /// only as far as it has reached.
            func points(_ stalk: SeedlingArt.Stalk, grown: Double) -> [CGPoint] {
                stride(from: 0.0, through: 1.0, by: 1.0 / 12).map { t in
                    let point = SeedlingArt.point(at: CGFloat(t) * CGFloat(grown), on: stalk)
                    return CGPoint(x: rect.minX + w * point.x, y: rect.minY + h * point.y)
                }
            }
            func midribHalf(_ leaflet: SeedlingArt.Leaflet, _ shoot: SeedlingArt.Shoot) -> CGFloat {
                SeedlingArt.midribBaseHalf(mirrored: leaflet.mirrored, canvasWidth: w)
                    * SeedlingArt.leafletScale(leaflet, of: shoot, extended: extended)
            }

            for shoot in SeedlingArt.shoots(by: extended) {
                // Each shoot has its own progress: the one belonging to the
                // stage being grown unfolds, and earlier ones are simply there.
                let grownness: Double
                if shoot.stage.rawValue < growing {
                    grownness = 1
                } else if shoot.stage.rawValue == growing {
                    grownness = shootProgress
                } else {
                    continue
                }
                guard grownness > 0.001 else { continue }

                // Slimmer than the stem it leaves: a side shoot carries one
                // cluster of leaflets, and at the stem's own weight it reads as
                // a second trunk growing sideways.
                let rachisRoot = baseHalf * 0.40
                let rachisTip = midribHalf(shoot.carrier, shoot)

                // The rachis takes the first part of the window and each
                // sub-petiole starts as the rachis reaches its branch point, so
                // the shoot unfolds outward the way it would grow rather than
                // arriving whole.
                let rachisWindow = 0.55
                let rachisGrown = min(1, grownness / rachisWindow)
                path.addPath(InkStroke.sliver(
                    along: points(SeedlingArt.rachis(of: shoot, extended: extended), grown: rachisGrown),
                    startHalf: rachisRoot,
                    // Tapered to where it has got to, or a stub of the rachis is
                    // drawn at the width of the finished thing.
                    endHalf: rachisRoot + (rachisTip - rachisRoot) * rachisGrown
                ))

                for leaflet in shoot.leaflets {
                    guard SeedlingArt.isOpen(leaflet, extended: extended) else { continue }
                    guard let sub = SeedlingArt.subPetiole(leaflet, of: shoot, extended: extended) else { continue }
                    let opens = rachisWindow * Double(leaflet.along)
                    let grown = min(1, max(0, (grownness - opens) / 0.30))
                    guard grown > 0.001 else { continue }

                    // Starts a shade narrower than the rachis is where it
                    // branches, so the join reads as a smaller stalk leaving a
                    // larger one rather than as a bulge.
                    let onRachis = rachisRoot + (rachisTip - rachisRoot) * leaflet.along
                    path.addPath(InkStroke.sliver(
                        along: points(sub, grown: grown),
                        startHalf: onRachis * 0.85,
                        endHalf: onRachis * 0.85 + (midribHalf(leaflet, shoot) - onRachis * 0.85) * grown
                    ))
                }
            }
        }
        return path
    }
}

/// A light line up the right side of the stem — the side facing the light.
/// Geometry constants must match `VectorStemShape`.
struct StemHighlightShape: Shape {
    var progress: Double
    var extended: CGFloat = 0

    var animatableData: AnimatablePair<Double, CGFloat> {
        get { AnimatablePair(progress, extended) }
        set {
            progress = newValue.first
            extended = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard progress > 0.08 else { return path }

        let w = rect.width, h = rect.height
        // Inside the tube, offset toward the light — and along the same
        // centreline the tube is built on, or the highlight slides off the stem
        // as its lean changes with the stage.
        let inset = w * 0.0030

        var first = true
        for step in stride(from: 0.12, through: 0.94, by: 0.041) {
            let centre = SeedlingArt.stemPoint(at: CGFloat(step) * CGFloat(progress), extended: extended)
            let point = CGPoint(x: rect.minX + w * centre.x + inset, y: rect.minY + h * centre.y)
            if first { path.move(to: point); first = false } else { path.addLine(to: point) }
        }
        return path
    }
}

// MARK: - Ground

/// The heap the seedling stands in.
///
/// Built the way the reference is drawn, which is the opposite of the obvious
/// way: the pile is a solid dark mass and the stones are *light* shapes carved
/// out of it, each stippled for volume, with the mass showing through as the
/// gaps between them. Drawing dark stones onto the parchment instead — the first
/// attempt — reads as scattered beans, because the shadows between stones are
/// what holds a heap together.
///
/// Nothing here animates: the ground is the same at every stage of the tree and
/// is on screen before the shoot appears. It is a `Canvas` because it is several
/// hundred marks, and seeded because it must not reshuffle between redraws.
struct VectorMound: View {
    var seed: UInt64 = 0x50112E

    var body: some View {
        Canvas { context, size in
            var rng = SeededGenerator(seed: seed)
            let ground = CGPoint(x: size.width * 0.500, y: size.height * 0.800)
            let width = size.width * 0.50
            let height = size.height * 0.135
            let hairline = max(0.45, size.width * 0.0016)

            // Height of the pile at a given position across it, -0.5…0.5.
            func crest(at across: CGFloat) -> CGFloat {
                let falloff = 1 - pow(min(1, abs(across) * 2), 1.12)
                return height * max(0, falloff)
            }

            // How far the pile's base dips *below* the ground line: deepest at
            // the centre, zero at the edges. The front row of rocks is nearest
            // the eye, so the base is a curve, not a flat line — that dip is
            // most of the pile's 3D.
            let maxBelly = height * 0.30
            func belly(at across: CGFloat) -> CGFloat {
                let t = min(1, abs(across) * 2)
                return maxBelly * (1 - t * t)
            }

            // 1. The mass. Smooth and low-shouldered: the pebbly outline comes
            //    from stones overlapping this edge, not from jitter in the edge
            //    itself, which just reads as a torn paper triangle.
            var mass = Path()
            mass.move(to: CGPoint(x: ground.x - width / 2, y: ground.y))
            let shoulders = 9
            var previous = CGPoint(x: ground.x - width / 2, y: ground.y)
            for index in 1...shoulders {
                let across = CGFloat(-0.5) + CGFloat(index) / CGFloat(shoulders)
                let point = CGPoint(x: ground.x + across * width, y: ground.y - crest(at: across))
                mass.addQuadCurve(
                    to: point,
                    control: CGPoint(
                        x: (previous.x + point.x) / 2,
                        y: min(previous.y, point.y) - height * CGFloat(rng.next(in: 0.02...0.14))
                    )
                )
                previous = point
            }
            mass.addLine(to: CGPoint(x: ground.x + width / 2, y: ground.y))
            // Bottom edge sags through the belly rather than closing flat.
            mass.addQuadCurve(
                to: CGPoint(x: ground.x - width / 2, y: ground.y),
                control: CGPoint(x: ground.x, y: ground.y + maxBelly * 1.9)
            )
            mass.closeSubpath()
            context.fill(mass, with: .color(GardenPalette.ink.opacity(0.97)))

            // 2. The stones, lit faces up. Placed inside the mass and drawn from
            //    the back of the pile forward so the near ones overlap.
            struct Stone {
                let centre: CGPoint
                let radius: CGFloat
                let tilt: Double  // radians; keeps the pile from looking like a grid
                let tone: Double
                /// Vertical flattening of this stone; the lit face's shift must
                /// scale with it, or squat stones end up with sliver highlights.
                let squash: CGFloat
            }

            var stones: [Stone] = []
            var attempts = 0
            while stones.count < 120 && attempts < 2200 {
                attempts += 1

                // Bell-shaped across the pile rather than uniform: the middle is
                // several times deeper than the shoulders, so uniform sampling
                // leaves a bare dark wedge up the centre.
                let across = CGFloat((rng.next(in: -0.5...0.5) + rng.next(in: -0.5...0.5)) * 0.99)
                let ceiling = crest(at: across)
                guard ceiling > 0 else { continue }

                // Stones range from the sagging bottom edge (the front row,
                // below the ground line) up to the crest — never past it. The
                // pebbly outline is the *top half* of a crest stone breaking
                // the silhouette; lift the centre above the crest as well and
                // the body clears the mass, and since stones this high are also
                // the smallest and flattest, it reads as a rock floating over
                // the pile. Capping at 1 keeps `lift` in [-sag, ceiling].
                let sag = belly(at: across)
                let lift = CGFloat(rng.next(in: 0...1)) * (ceiling + sag) - sag
                // Nearer the front reads as nearer the eye, so those run larger.
                let depth = 1 - min(1, lift / max(ceiling, 0.0001))
                let radius = size.width * CGFloat(rng.next(in: 0.0080...0.0190)) * (0.70 + 0.60 * depth)
                guard ceiling > radius * 0.35 else { continue }

                stones.append(
                    Stone(
                        centre: CGPoint(x: ground.x + across * width, y: ground.y - lift),
                        radius: radius,
                        tilt: rng.next(in: -1.2...1.2),
                        tone: rng.next(in: 0...1),
                        squash: CGFloat(rng.next(in: 0.48...0.80))
                    )
                )
            }

            // A few loose rocks lying on the ground beside the pile.
            for _ in 0..<7 {
                let sideSign: CGFloat = rng.next(in: 0...1) < 0.5 ? -1 : 1
                let across = sideSign * CGFloat(rng.next(in: 0.55...0.88))
                let radius = size.width * CGFloat(rng.next(in: 0.005...0.013))
                stones.append(
                    Stone(
                        centre: CGPoint(x: ground.x + across * width, y: ground.y - radius * 0.3),
                        radius: radius,
                        tilt: rng.next(in: -1.2...1.2),
                        tone: rng.next(in: 0...1),
                        squash: CGFloat(rng.next(in: 0.48...0.75))
                    )
                )
            }

            // One light source, upper right. Every stone is a dark body whose
            // top-right face catches that light; the lit patch is the stone's
            // own outline shifted toward the light and clipped to the body, so
            // the shadowed crescent always sits lower-left. Stones higher in the
            // pile and toward the light side catch more of it.
            let lightDirection = CGVector(dx: 0.30, dy: -0.42)

            for stone in stones.sorted(by: { $0.centre.y < $1.centre.y }) {
                let body = stoneOutline(at: stone.centre, radius: stone.radius, tilt: stone.tilt, squash: stone.squash, rng: &rng)

                context.fill(body, with: .color(GardenPalette.ink))

                let acrossPile = (stone.centre.x - ground.x) / max(width, 1)   // -0.5…0.5
                let heightInPile = (ground.y - stone.centre.y) / max(height, 1) // 0…1+
                let exposure = min(1, max(0, 0.26 + 0.58 * acrossPile + 0.60 * heightInPile))
                let litOpacity = (0.10 + 0.88 * exposure) * (0.85 + 0.15 * stone.tone)

                var lit = context
                lit.clip(to: body)
                let litFace = body.applying(CGAffineTransform(
                    translationX: stone.radius * lightDirection.dx,
                    y: stone.radius * stone.squash * lightDirection.dy
                ))
                lit.fill(litFace, with: .color(GardenPalette.parchment.opacity(litOpacity * 0.72)))

                // A brighter rim tight against the top-right edge, so the face
                // grades from white at the light down into the stipple.
                let rim = body.applying(CGAffineTransform(
                    translationX: stone.radius * lightDirection.dx * 1.9,
                    y: stone.radius * stone.squash * lightDirection.dy * 1.9
                ))
                lit.fill(rim, with: .color(GardenPalette.parchment.opacity(litOpacity)))

                // Stipple along the terminator — the band where light falls into
                // shadow, which in the reference carries the texture.
                let dots = 10 + Int(rng.next(in: 0...14))
                for _ in 0..<dots {
                    // Angles biased to the shadow side (down-left).
                    let angle = 2.36 + rng.next(in: -1.1...1.1)
                    let spread = CGFloat(rng.next(in: 0.30...0.95))
                    let point = CGPoint(
                        x: stone.centre.x + CGFloat(cos(angle)) * stone.radius * spread,
                        y: stone.centre.y + CGFloat(sin(angle)) * stone.radius * 0.62 * spread
                    )
                    let dot = size.width * CGFloat(rng.next(in: 0.0009...0.0022))
                    lit.fill(
                        Path(ellipseIn: CGRect(x: point.x, y: point.y, width: dot, height: dot)),
                        with: .color(GardenPalette.ink.opacity(rng.next(in: 0.45...0.85)))
                    )
                }
            }

            // 3. Spray at the foot of the pile: fine stipple thinning outward,
            //    which is what seats the heap on the ground.
            for _ in 0..<1500 {
                let spread = CGFloat(rng.next(in: -1.0...1.0))
                let density = exp(-abs(spread) * 2.2)
                guard rng.next(in: 0...1) < Double(density) + 0.03 else { continue }

                let x = ground.x + spread * size.width * 0.52
                // The skirt follows the sagging base and reaches further down
                // beneath the pile's centre.
                let localAcross = min(0.5, abs(spread) * 0.52 * size.width / width)
                let drop = CGFloat(rng.next(in: 0...1))
                let y = ground.y + belly(at: localAcross) * 0.8 + drop * drop * size.height * 0.055
                let dot = size.width * CGFloat(rng.next(in: 0.0010...0.0030))

                context.fill(
                    Path(ellipseIn: CGRect(x: x, y: y, width: dot, height: dot * 0.85)),
                    with: .color(GardenPalette.ink.opacity(Double(density) * 0.80 + 0.18))
                )
            }

            // 4. Shadow streaks radiating from the base along the ground —
            //    thin horizontal strokes running outward on both sides, which is
            //    what seats the pile in space.
            for sideIndex in 0..<20 {
                let sideSign: CGFloat = sideIndex % 2 == 0 ? -1 : 1
                let start = width * CGFloat(rng.next(in: 0.36...0.58))
                let length = size.width * CGFloat(rng.next(in: 0.030...0.110))
                let x = ground.x + sideSign * start
                let y = ground.y + CGFloat(rng.next(in: 0.000...0.022)) * size.height
                let fade = max(0.22, 0.80 - Double(start / width))

                var streak = Path()
                streak.move(to: CGPoint(x: x, y: y))
                streak.addLine(to: CGPoint(
                    x: x + sideSign * length,
                    y: y + CGFloat(rng.next(in: -0.002...0.004)) * size.height
                ))
                context.stroke(
                    streak,
                    with: .color(GardenPalette.ink.opacity(fade)),
                    lineWidth: hairline * CGFloat(rng.next(in: 0.9...1.5))
                )
            }

            // …streaks fanning *forward* — down and outward from beneath the
            //    pile, the perspective lines that project the heap toward the
            //    viewer.
            for index in 0..<14 {
                let sideSign: CGFloat = index % 2 == 0 ? -1 : 1
                let startAcross = CGFloat(rng.next(in: 0.04...0.34))
                let x = ground.x + sideSign * startAcross * width
                let y = ground.y + belly(at: sideSign * startAcross) * 0.85
                    + CGFloat(rng.next(in: 0.002...0.012)) * size.height
                let run = size.width * CGFloat(rng.next(in: 0.025...0.085))
                let fall = size.height * CGFloat(rng.next(in: 0.010...0.030))

                var streak = Path()
                streak.move(to: CGPoint(x: x, y: y))
                streak.addLine(to: CGPoint(x: x + sideSign * run, y: y + fall))
                context.stroke(
                    streak,
                    with: .color(GardenPalette.ink.opacity(rng.next(in: 0.25...0.55))),
                    lineWidth: hairline * CGFloat(rng.next(in: 0.8...1.4))
                )
            }

            // …and a few short heavy dashes tight against the base.
            for _ in 0..<10 {
                let spread = CGFloat(rng.next(in: -0.45...0.45))
                let x = ground.x + spread * width
                let y = ground.y + belly(at: spread) * 0.9 + CGFloat(rng.next(in: 0.002...0.014)) * size.height
                let length = size.width * CGFloat(rng.next(in: 0.006...0.016))
                var dash = Path()
                dash.move(to: CGPoint(x: x, y: y))
                dash.addLine(to: CGPoint(x: x + length, y: y))
                context.stroke(dash, with: .color(GardenPalette.ink.opacity(0.7)), lineWidth: hairline * 1.5)
            }
        }
        .allowsHitTesting(false)
    }
    /// A pebble: an ellipse pushed out of round at every step, tilted so the pile
    /// isn't a grid of identical lozenges.
    private func stoneOutline(at centre: CGPoint, radius: CGFloat, tilt: Double, squash: CGFloat, rng: inout SeededGenerator) -> Path {
        var path = Path()
        let steps = 9
        let points = (0..<steps).map { index -> CGPoint in
            let angle = (Double(index) / Double(steps)) * 2 * .pi + tilt
            let wobble = radius * CGFloat(rng.next(in: 0.80...1.10))
            return CGPoint(
                x: centre.x + CGFloat(cos(angle)) * wobble,
                y: centre.y + CGFloat(sin(angle)) * wobble * squash
            )
        }

        path.move(to: points[0])
        for index in 0..<steps {
            let current = points[index]
            let next = points[(index + 1) % steps]
            path.addQuadCurve(
                to: next,
                control: CGPoint(
                    x: (current.x + next.x) / 2 + (next.y - current.y) * 0.18,
                    y: (current.y + next.y) / 2 - (next.x - current.x) * 0.18
                )
            )
        }
        path.closeSubpath()
        return path
    }
}
