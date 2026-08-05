import SwiftUI

/// Warm parchment and ink, from the reference illustration. Separate from
/// `SignInPalette` on purpose: the sign-up flow is cool off-white, the garden is
/// warm. Whether the whole app moves warm is a later decision.
enum GardenPalette {
    static let parchment = Color(red: 0.953, green: 0.937, blue: 0.914)
    static let ink = Color(red: 0.102, green: 0.102, blue: 0.094)
    static let softInk = Color(red: 0.35, green: 0.34, blue: 0.32)
    /// The band that separates read messages from unread ones in a thread.
    ///
    /// Paler than any bubble on purpose: it is a rule drawn across the list
    /// rather than something in it, and anything with weight would read as a
    /// message. Against parchment it is barely a shade — which is the point,
    /// since the words carry it.
    static let unreadBand = Color(red: 0.902, green: 0.890, blue: 0.871)

    static let muted = Color(red: 0.431, green: 0.416, blue: 0.388)
    static let gold = Color(red: 0.549, green: 0.478, blue: 0.333)
    static let card = Color(red: 0.988, green: 0.980, blue: 0.965)

    /// The two sides of a conversation. Both carry white text.
    ///
    /// **Chosen against the chat photograph, measured rather than picked.** The
    /// background is a bright Santorini sunset, and a bubble whose fill matches
    /// what is behind it stops being a bubble. Sampling the photo: sky blue never
    /// collides anywhere — there is no saturated blue of that value in it — but
    /// grey sits right in its mid-tones, matching **6.8%** of the raw image.
    ///
    /// That is what sets the wash in `ConversationView`, and the direction is the
    /// opposite of the obvious one: *darkening* the photo makes grey worse, up to
    /// 43% of the screen at half strength, because it drags the whole image down
    /// through grey on the way. Lightening lifts it clear instead.
    ///
    /// White text is the reason both are this dark. A true sky blue is far
    /// paler, and white on it is unreadable — these are the darkest values that
    /// still read as "sky" and "grey": 3.6:1 and 4.4:1 against white. The blue is
    /// short of WCAG's 4.5 for body text, which is a deliberate and well-trodden
    /// trade — every platform's chat bubble makes it — and the alternative is a
    /// navy nobody would call sky.
    /// The badge gold, shared rather than copied.
    ///
    /// `ModalityBadge` drew this and kept it private; the chat bubble is meant to
    /// be *the same gold as the tree's domain icons*, so it reads the same
    /// constant. Two literals with the same three numbers drift the first time
    /// one of them is nudged.
    ///
    /// Brighter and more saturated than `gold`, which is a muted khaki — right
    /// for text on parchment, dull as a ring or a bubble.
    static let badgeGold = Color(red: 0.831, green: 0.667, blue: 0.212)

    static let bubbleMine = badgeGold

    /// A faint warm grey, not a neutral one.
    ///
    /// It sits on parchment, and a neutral grey next to a warm off-white reads
    /// as slightly blue. This keeps parchment's warmth and steps a little darker
    /// — far enough to be plainly a bubble rather than a shadow, close enough to
    /// stay quiet beside the gold.
    static let bubbleTheirs = Color(red: 0.851, green: 0.843, blue: 0.827)

    /// What each bubble's text is written in.
    ///
    /// Both sides are ink now that both fills are light.
    ///
    /// It was white on grey while that grey was a mid-tone. On the faint grey it
    /// would be about **1.2:1** — invisible. Ink gives **14.8:1** there and
    /// **7.97:1** on the gold, so the two sides are told apart by fill alone,
    /// which is what the reference does.
    ///
    /// Kept as two names rather than collapsed into one, because the gold is
    /// only just light enough to carry ink: if either fill is ever darkened,
    /// this is where that shows up as a decision rather than a surprise.
    static let bubbleMineText = ink
    static let bubbleTheirsText = ink

    /// A filled heart, and the only saturated colour in the app.
    ///
    /// Deliberately not `.red`: the system red is a cool 255,59,48 that reads as
    /// an alert against parchment. This is warmer and slightly darker, so a liked
    /// card looks marked rather than errored.
    static let heart = Color(red: 0.839, green: 0.235, blue: 0.239)
}

/// The garden page: square but for its bottom corners, which are rounded so it
/// reads as a sheet with an edge rather than as the screen itself.
struct PageShape: Shape {
    var radius: CGFloat = 22

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = min(radius, min(rect.width, rect.height) / 2)
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - r, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - r),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.closeSubpath()
        return path
    }
}

/// Skeletons are built in unit space (0…1 on both axes, y downward). Everything
/// that draws one projects through here, so branches, leaves and soil agree on
/// where the ground is even when the frame isn't square.
enum TreeGeometry {
    /// The tree keeps its proportions and sits on the bottom edge of the frame.
    static func scale(in rect: CGRect) -> CGFloat { min(rect.width, rect.height) }

    static func projected(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        let side = scale(in: rect)
        return CGPoint(
            x: rect.midX - side / 2 + point.x * side,
            y: rect.maxY - side + point.y * side
        )
    }

    /// Maps a point in the *illustration's* canvas — `SeedlingArt`, which is
    /// wider than it is tall — into the container. Anything that has to sit on
    /// the drawn plant rather than at a fixed spot on screen goes through here,
    /// and it has to match how `TreeView` places `SeedlingView` or whatever is
    /// pinned will sit off the plant.
    static func illustration(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        let side = scale(in: rect)
        let height = side / SeedlingArt.aspectRatio
        return CGPoint(
            x: rect.midX - side / 2 + point.x * side,
            y: rect.maxY - height + point.y * height
        )
    }
}

/// One limb, revealed along its own length so growth reads as drawing rather
/// than fading. `animatableData` is what lets SwiftUI interpolate that.
struct BranchShape: Shape {
    var points: [CGPoint]
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard points.count > 1, progress > 0 else { return path }

        let scaled = points.map { TreeGeometry.projected($0, in: rect) }
        let lengths = zip(scaled, scaled.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        let total = lengths.reduce(0, +)
        guard total > 0 else { return path }

        let target = total * min(1, progress)
        var travelled = 0.0
        path.move(to: scaled[0])

        for (index, segment) in lengths.enumerated() {
            if travelled + segment <= target {
                path.addLine(to: scaled[index + 1])
                travelled += segment
            } else {
                let t = segment > 0 ? (target - travelled) / segment : 0
                let a = scaled[index], b = scaled[index + 1]
                path.addLine(to: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
                break
            }
        }
        return path
    }
}

/// A pointed leaf: two mirrored curves plus a midrib, stroked as line art.
struct LeafShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let base = CGPoint(x: rect.midX, y: rect.maxY)
        let tip = CGPoint(x: rect.midX, y: rect.minY)
        let bulge = rect.width * 0.62
        let shoulder = rect.minY + rect.height * 0.40

        path.move(to: base)
        path.addQuadCurve(to: tip, control: CGPoint(x: rect.midX - bulge, y: shoulder))
        path.addQuadCurve(to: base, control: CGPoint(x: rect.midX + bulge, y: shoulder))
        path.move(to: base)
        path.addLine(to: tip)
        return path
    }
}

/// Placed by its stalk rather than its centre, so it pivots off the branch tip
/// it is attached to.
struct LeafMark: View {
    let leaf: Leaf
    let containerRect: CGRect
    var progress: Double

    var body: some View {
        let side = TreeGeometry.scale(in: containerRect)
        let height = leaf.size * side * 1.7
        let width = leaf.size * side * 0.8
        let anchorPoint = TreeGeometry.projected(leaf.position, in: containerRect)

        LeafShape()
            .stroke(GardenPalette.ink, style: StrokeStyle(lineWidth: max(0.7, side * 0.0030), lineJoin: .round))
            .frame(width: width, height: height)
            .rotationEffect(.radians(leaf.angle), anchor: .bottom)
            .scaleEffect(progress, anchor: .bottom)
            .opacity(progress)
            .position(x: anchorPoint.x, y: anchorPoint.y - height / 2)
    }
}
