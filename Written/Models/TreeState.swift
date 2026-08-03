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

    /// Connected modalities in the order they were offered.
    ///
    /// **Read off `allCases`, never off `rawValue`.** Sorting by the raw value
    /// was the same thing right up until the unlock sequence was given
    /// explicitly — `Modality.allCases` is `[.media, .lifestyle, .music,
    /// .plans]` while `music` is still case zero, because `TreeSkeleton` derives
    /// each branch's attachment height from the raw value and renumbering the
    /// cases would move the drawing. So connecting music sent it to the top of
    /// the stack, above branches that had been there for days.
    ///
    /// This is the offer order rather than a record of when each was actually
    /// connected, and the two agree for anyone following the prompts, which take
    /// one modality at a time. They can disagree now that badges are tappable —
    /// connect music first and media second and media still draws above it.
    /// Fixing *that* means ordering by `source_connections.connected_at`, which
    /// exists and is never overwritten (`SyncService` upserts only
    /// `last_distilled_at` and `record_count`), cached locally so the first
    /// frame needs no network call.
    var connectedModalities: [Modality] {
        Modality.allCases.filter { branches[$0] != nil }
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
