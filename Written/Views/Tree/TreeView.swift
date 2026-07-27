import SwiftUI

/// The tree itself: soil, limbs, leaves.
///
/// `growth` runs 0…1 across the whole tree, and each limb takes the slice of
/// that range matching its depth — so the trunk draws first, then its branches,
/// then the leaves open. Animate `growth` and the tree draws itself outward.
struct TreeView: View {
    let skeleton: TreeSkeleton
    var growth: Double = 1

    var body: some View {
        GeometryReader { geometry in
            let rect = CGRect(origin: .zero, size: geometry.size)
            let side = TreeGeometry.scale(in: rect)

            ZStack {
                if let stage = skeleton.illustrated {
                    // Deliberately *not* keyed on the stage: one instance has to
                    // survive the change so it can grow into it. Give it an
                    // `.id(stage)` and SwiftUI tears the plant down and builds a
                    // new one, which is the jump this is meant to avoid.
                    SeedlingView(stage: stage)
                        .frame(width: side)
                        .position(x: rect.midX, y: rect.maxY - side / SeedlingView.aspectRatio / 2)
                }

                ForEach(skeleton.isSeedling ? [] : skeleton.branches) { branch in
                    BranchShape(points: branch.points, progress: growth)
                        .stroke(
                            GardenPalette.ink,
                            style: StrokeStyle(
                                lineWidth: max(0.8, branch.width * side),
                                lineCap: .round,
                                lineJoin: .round
                            )
                        )
                        .animation(drawing(atDepth: branch.depth, extraDelay: branch.drawDelay), value: growth)
                }

                // The mound draws over the trunk's foot — same reason as the
                // shoot: the tree comes out of the top of the pile.
                if !skeleton.isSeedling {
                    VectorMound()
                        .aspectRatio(SeedlingArt.aspectRatio, contentMode: .fit)
                        .frame(width: side)
                        .position(x: rect.midX, y: rect.maxY - side / SeedlingView.aspectRatio / 2)
                }

                ForEach(skeleton.isSeedling ? [] : skeleton.leaves) { leaf in
                    LeafMark(leaf: leaf, containerRect: rect, progress: growth)
                        .animation(drawing(atDepth: leaf.depth), value: growth)
                }
            }
        }
    }

    /// Staging has to live in each limb's own animation, not in slices of a
    /// shared progress value: SwiftUI evaluates this body once with the final
    /// `growth` and interpolates every modifier over the same window, so derived
    /// phases would all draw at once. A per-depth delay makes the tree grow
    /// outward from the trunk.
    private func drawing(atDepth depth: Int, extraDelay: Double = 0) -> Animation {
        // The trunk's segments draw one after another — each delay matches the
        // one before it's duration, so the line never appears as dashes — and
        // the limbs follow once it has finished.
        guard depth > 0 else { return .easeOut(duration: 0.32).delay(extraDelay) }
        return .easeOut(duration: 0.7).delay(0.85 + Double(depth - 1) * 0.32)
    }
}

#Preview("Seedling") {
    TreeView(skeleton: TreeSkeleton.make(from: .empty, seed: 7))
        .frame(height: 380)
        .background(GardenPalette.parchment)
}

#Preview("Music only — narrow taste") {
    let state = TreeState(branches: [
        .music: ModalityMetrics(volume: 40, diversity: 0.12, dominantShare: 0.8)
    ])
    return TreeView(skeleton: TreeSkeleton.make(from: state, seed: 7))
        .frame(height: 380)
        .background(GardenPalette.parchment)
}

#Preview("Music only — wide taste") {
    let state = TreeState(branches: [
        .music: ModalityMetrics(volume: 220, diversity: 0.9, dominantShare: 0.15)
    ])
    return TreeView(skeleton: TreeSkeleton.make(from: state, seed: 7))
        .frame(height: 380)
        .background(GardenPalette.parchment)
}

#Preview("Everything connected") {
    let full = ModalityMetrics(volume: 200, diversity: 0.8, dominantShare: 0.2)
    let state = TreeState(branches: [
        .music: full, .media: full, .lifestyle: full
    ])
    return TreeView(skeleton: TreeSkeleton.make(from: state, seed: 7))
        .frame(height: 380)
        .background(GardenPalette.parchment)
}
