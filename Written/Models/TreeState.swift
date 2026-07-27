import Foundation

/// What one connected modality contributes to the tree's shape.
struct ModalityMetrics: Equatable {
    /// How many records the modality yielded. Drives branch length and thickness.
    let volume: Int

    /// 0…1. How varied that footprint is — one artist on repeat is near 0, a
    /// wide spread of artists and genres approaches 1. Drives how much the
    /// branch sub-divides and fans out.
    let diversity: Double

    /// 0…1. The largest single cluster's share of the footprint. Drives how far
    /// the branch leans, so a narrow taste literally bends the tree.
    let dominantShare: Double

    static let none = ModalityMetrics(volume: 0, diversity: 0, dominantShare: 1)
}

/// Everything the tree's geometry is derived from. Pure data: no SwiftUI, no
/// records, nothing to mock when previewing shapes.
struct TreeState: Equatable {
    /// Only modalities the user has actually connected appear here.
    var branches: [Modality: ModalityMetrics]

    init(branches: [Modality: ModalityMetrics] = [:]) {
        self.branches = branches
    }

    static let empty = TreeState()

    /// Nothing connected yet — renders as the two-leaf shoot.
    var isSeedling: Bool { branches.isEmpty }

    /// Connected modalities in unlock order, which is also the order they were
    /// offered to the user.
    var connectedModalities: [Modality] {
        branches.keys.sorted { $0.rawValue < $1.rawValue }
    }

    /// The next branch to offer. Every declared modality takes its turn, even
    /// one with no distiller behind it yet — its bar appears with the button
    /// disabled. `nil` only once they have all been offered.
    var nextModality: Modality? {
        Modality.allCases.first { branches[$0] == nil }
    }

    /// Average diversity across connected branches, for the trunk's own vigour.
    var overallDiversity: Double {
        guard !branches.isEmpty else { return 0 }
        return branches.values.map(\.diversity).reduce(0, +) / Double(branches.count)
    }
}
