import SwiftUI

/// Warm parchment and ink, from the reference illustration. Separate from
/// `SignInPalette` on purpose: the sign-up flow is cool off-white, the garden is
/// warm. Whether the whole app moves warm is a later decision.
enum GardenPalette {
    static let parchment = Color(red: 0.953, green: 0.937, blue: 0.914)
    static let ink = Color(red: 0.102, green: 0.102, blue: 0.094)
    static let softInk = Color(red: 0.35, green: 0.34, blue: 0.32)
    static let muted = Color(red: 0.431, green: 0.416, blue: 0.388)
    static let gold = Color(red: 0.549, green: 0.478, blue: 0.333)
    static let card = Color(red: 0.988, green: 0.980, blue: 0.965)

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
