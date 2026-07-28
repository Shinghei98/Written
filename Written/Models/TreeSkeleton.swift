import CoreGraphics
import Foundation

/// A deterministic random source. The tree must be identical every time it is
/// drawn — SwiftUI rebuilds view bodies constantly, and `Double.random` in a
/// body would make the branches twitch on every frame.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        // SplitMix64. Any non-zero seed works; zero would stick at zero.
        state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func next(in range: ClosedRange<Double>) -> Double {
        Double.random(in: range, using: &self)
    }
}

/// One limb: a polyline in unit space (0…1 on both axes, y increasing downward
/// to match SwiftUI), stroked at `width` relative to the view's width.
struct Branch: Identifiable, Equatable {
    let id: Int
    let points: [CGPoint]
    let width: Double
    let depth: Int
    let modality: Modality?
    /// Extra delay before this limb draws, on top of its depth's. Used to stagger
    /// the trunk's own segments, which share a depth but must not draw at once —
    /// three simultaneous strokes read as a dashed line, not a trunk.
    var drawDelay: Double = 0
}

struct Leaf: Identifiable, Equatable {
    let id: Int
    let position: CGPoint
    /// Radians, 0 pointing up.
    let angle: Double
    let size: Double
    let depth: Int
}

/// The tree's geometry, derived purely from `TreeState`. No SwiftUI here, so a
/// shape can be checked by reading numbers rather than by squinting at a screen.
struct TreeSkeleton: Equatable {
    let branches: [Branch]
    let leaves: [Leaf]
    let maxDepth: Int
    /// The early stages are drawn from the illustration, not from these
    /// branches — `nil` once the plant is generated geometry.
    var illustrated: SeedlingStage?

    var isSeedling: Bool { illustrated != nil }

    /// Just below the stone pile's crest, in unit space — the mound is drawn
    /// over the trunk's foot, so the tree emerges from the top of the pile the
    /// same way the shoot does.
    static let seedlingBase = CGPoint(x: 0.500, y: 0.705)

    /// Hard ceiling so a huge library can't produce thousands of shapes.
    private static let branchLimit = 60

    static func make(from state: TreeState, seed: UInt64) -> TreeSkeleton {
        var rng = SeededGenerator(seed: seed)

        // The first two stages are the illustration, so that connecting the
        // first app grows the plant the user is already looking at. Generated
        // geometry takes over once there is more than one branch to place,
        // which is more than the drawing has room to say.
        switch state.connectedModalities.count {
        case 0: return illustrated(.sprout, rng: &rng)
        case 1: return illustrated(.shoot, rng: &rng)
        case 2: return illustrated(.branch, rng: &rng)
        // Three *and* four. The illustration stops at the bough, so connecting
        // a fourth doesn't grow the plant again — it lights the badge on the
        // bough, which was always drawn with a bud at its tip and nothing
        // behind it. Falling through to generated geometry here would swap the
        // hand-drawn plant for a procedural one the moment someone connected
        // their calendar, which reads as the drawing breaking.
        case 3, 4: return illustrated(.bough, rng: &rng)
        default: break
        }

        var branches: [Branch] = []
        var leaves: [Leaf] = []
        var nextID = 0

        let connected = state.connectedModalities
        let trunkHeight = min(0.52, 0.24 + 0.07 * Double(connected.count))
        let trunkWidth = 0.013 + 0.003 * min(3, Double(connected.count))
        let trunkPoints = polyline(
            from: seedlingBase,
            angle: rng.next(in: -0.05...0.05),
            length: trunkHeight,
            curvature: rng.next(in: -0.12...0.12),
            rng: &rng
        )

        // The trunk is drawn as a few stacked segments of decreasing width: a
        // single stroke can only have one width, and a trunk that doesn't taper
        // reads as a bar someone dropped behind the branches.
        for (index, segment) in tapered(trunkPoints, segments: 3).enumerated() {
            branches.append(
                Branch(
                    id: nextID,
                    points: segment,
                    width: trunkWidth * (1 - 0.22 * Double(index)),
                    depth: 0,
                    modality: nil,
                    drawDelay: Double(index) * 0.30
                )
            )
            nextID += 1
        }

        // A shoot at the very top, so the trunk ends in something living rather
        // than a cut-off stub.
        if let crown = trunkPoints.last {
            leaves.append(Leaf(id: nextID, position: crown, angle: 0.10, size: 0.030, depth: 1))
            nextID += 1
        }

        var deepest = 0

        for modality in connected {
            guard let metrics = state.branches[modality] else { continue }

            // Each modality owns a fixed direction, so an unconnected one leaves
            // its side of the tree bare — that is where lopsidedness comes from.
            let baseAngle = sectorAngle(for: modality)

            // Attach higher up the trunk the later the modality unlocks.
            let attachment = min(0.95, 0.5 + 0.11 * Double(modality.rawValue))
            let origin = point(along: trunkPoints, at: attachment)

            let volumeScale = min(1, log(1 + Double(metrics.volume)) / log(1 + 250))
            let length = 0.16 * (0.55 + 0.95 * volumeScale)
            // Two levels minimum: one limb with a single leaf reads as broken
            // rather than as sparse.
            let levels = 2 + Int((metrics.diversity * 2).rounded())

            grow(
                origin: origin,
                angle: baseAngle,
                length: length,
                width: trunkWidth * 0.7,
                depth: 1,
                maxDepth: levels,
                metrics: metrics,
                modality: modality,
                branches: &branches,
                leaves: &leaves,
                nextID: &nextID,
                deepest: &deepest,
                rng: &rng
            )
        }

        return fitted(
            TreeSkeleton(branches: branches, leaves: leaves, maxDepth: max(1, deepest))
        )
    }

    /// Shrinks a tree about its base until it sits inside the unit square. A
    /// dense enough footprint will otherwise grow straight off the edge of the
    /// view, and clipped branches read as a bug rather than as abundance.
    private static func fitted(_ skeleton: TreeSkeleton) -> TreeSkeleton {
        let points = skeleton.branches.flatMap(\.points) + skeleton.leaves.map(\.position)
        guard let minX = points.map(\.x).min(),
              let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min()
        else { return skeleton }

        let base = seedlingBase
        // Leaves stick out past their branch tip, so leave a little room.
        let margin = 0.10
        let widest = max(base.x - minX, maxX - base.x)
        let tallest = base.y - minY

        var factor = 1.0
        if widest > 0 { factor = min(factor, (0.5 - margin) / widest) }
        if tallest > 0 { factor = min(factor, (base.y - margin) / tallest) }
        guard factor < 1 else { return skeleton }

        func scaled(_ point: CGPoint) -> CGPoint {
            CGPoint(
                x: base.x + (point.x - base.x) * factor,
                y: base.y + (point.y - base.y) * factor
            )
        }

        return TreeSkeleton(
            branches: skeleton.branches.map {
                Branch(id: $0.id, points: $0.points.map(scaled), width: $0.width * factor, depth: $0.depth, modality: $0.modality, drawDelay: $0.drawDelay)
            },
            leaves: skeleton.leaves.map {
                Leaf(id: $0.id, position: scaled($0.position), angle: $0.angle, size: $0.size * factor, depth: $0.depth)
            },
            maxDepth: skeleton.maxDepth
        )
    }

    // MARK: - Growth

    private static func grow(
        origin: CGPoint,
        angle: Double,
        length: Double,
        width: Double,
        depth: Int,
        maxDepth: Int,
        metrics: ModalityMetrics,
        modality: Modality,
        branches: inout [Branch],
        leaves: inout [Leaf],
        nextID: inout Int,
        deepest: inout Int,
        rng: inout SeededGenerator
    ) {
        guard branches.count < branchLimit else { return }

        let points = polyline(
            from: origin,
            angle: angle,
            length: length,
            curvature: rng.next(in: -0.25...0.25),
            rng: &rng
        )
        branches.append(Branch(id: nextID, points: points, width: width, depth: depth, modality: modality))
        nextID += 1
        deepest = max(deepest, depth)

        guard let tip = points.last else { return }

        if depth >= maxDepth {
            leaves.append(
                Leaf(
                    id: nextID,
                    position: tip,
                    angle: angle,
                    size: 0.030 + 0.022 * metrics.diversity,
                    depth: depth
                )
            )
            nextID += 1
            return
        }

        // A varied footprint fans wide; a narrow one stays pinched and, through
        // `dominantShare`, pulls the whole limb to one side.
        let spread = 0.22 + 0.45 * metrics.diversity
        let lean = (metrics.dominantShare - 0.5) * 0.7

        for direction in [-1.0, 1.0] {
            let childAngle = angle + direction * spread + lean + rng.next(in: -0.10...0.10)
            grow(
                origin: tip,
                angle: childAngle,
                length: length * rng.next(in: 0.62...0.78),
                width: width * 0.62,
                depth: depth + 1,
                maxDepth: maxDepth,
                metrics: metrics,
                modality: modality,
                branches: &branches,
                leaves: &leaves,
                nextID: &nextID,
                deepest: &deepest,
                rng: &rng
            )
        }
    }

    /// An illustrated stage. It carries no branches or leaves of its own —
    /// `SeedlingView` draws it — but keeps a stem polyline so anything reading
    /// the skeleton's extent still gets a plant-shaped answer.
    private static func illustrated(_ stage: SeedlingStage, rng: inout SeededGenerator) -> TreeSkeleton {
        let stem = polyline(
            from: seedlingBase,
            angle: 0.02,
            length: 0.44 + 0.06 * Double(stage.rawValue),
            curvature: -0.10,
            rng: &rng
        )
        let branch = Branch(id: 0, points: stem, width: 0.010, depth: 0, modality: nil)
        return TreeSkeleton(branches: [branch], leaves: [], maxDepth: 1, illustrated: stage)
    }

    /// Splits a polyline into contiguous chunks that share their boundary
    /// points, so the segments join without a visible seam.
    private static func tapered(_ points: [CGPoint], segments: Int) -> [[CGPoint]] {
        guard points.count > segments else { return [points] }
        let per = points.count / segments
        return (0..<segments).map { index in
            let start = index * per
            let end = index == segments - 1 ? points.count - 1 : (index + 1) * per
            return Array(points[start...end])
        }
    }

    // MARK: - Geometry helpers

    /// Fixed direction per modality, in radians from straight up. Music leans
    /// left, interests right, and so on outward — so the tree's silhouette says
    /// at a glance which parts of a life are represented.
    private static func sectorAngle(for modality: Modality) -> Double {
        switch modality {
        case .music: return -0.55
        case .media: return 0.50
        case .lifestyle: return -0.95
        // Furthest right, so the four sectors fan out from music on the left to
        // plans on the right rather than doubling up on a side. Only reachable
        // once the generated tree is — five modalities — since four still draws
        // the illustration.
        case .plans: return 0.95
        }
    }

    /// Walks `segments` steps, turning a little each step so limbs curve instead
    /// of looking like a wire diagram.
    private static func polyline(
        from origin: CGPoint,
        angle: Double,
        length: Double,
        curvature: Double,
        segments: Int = 10,
        rng: inout SeededGenerator
    ) -> [CGPoint] {
        var points = [origin]
        var current = origin
        var heading = angle
        let step = length / Double(segments)

        for _ in 0..<segments {
            heading += curvature / Double(segments) + rng.next(in: -0.02...0.02)
            current = CGPoint(
                x: current.x + sin(heading) * step,
                y: current.y - cos(heading) * step
            )
            points.append(current)
        }
        return points
    }

    /// Point at `fraction` of the way along a polyline, by arc length.
    private static func point(along points: [CGPoint], at fraction: Double) -> CGPoint {
        guard points.count > 1 else { return points.first ?? .zero }

        let lengths = zip(points, points.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        let total = lengths.reduce(0, +)
        guard total > 0 else { return points[0] }

        var travelled = 0.0
        let target = total * fraction
        for (index, segment) in lengths.enumerated() {
            if travelled + segment >= target {
                let t = segment > 0 ? (target - travelled) / segment : 0
                let a = points[index], b = points[index + 1]
                return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            }
            travelled += segment
        }
        return points[points.count - 1]
    }
}
