import Foundation
import SwiftUI

@MainActor
final class DistillViewModel: ObservableObject {

    @Published var youtubeStatus: SourceStatus = .idle
    @Published var appleMusicStatus: SourceStatus = .idle
    @Published var spotifyStatus: SourceStatus = .idle
    @Published private(set) var records: [DistilledRecord] = []

    @Published var isExporterPresented = false
    @Published var exportDocument: CSVDocument?
    @Published var exportResultMessage: String?

    /// What the tree is grown from. Recomputed whenever records change, never
    /// per frame.
    @Published private(set) var treeState: TreeState = .empty
    @Published private(set) var skeleton = TreeSkeleton.make(from: .empty, seed: DistillViewModel.treeSeed)

    private let googleOAuth = OAuthPKCEService(provider: .google)
    private let spotifyOAuth = OAuthPKCEService(provider: .spotify)

    init() {
#if DEBUG
        // `-stage 3` on the launch line seeds the plant, so a stage can be
        // looked at without patching the source and rebuilding. See `DebugLaunch`.
        if let stage = DebugLaunch.forcedStage { applyPreview(connected: stage) }
#endif
    }

    var hasRecords: Bool { !records.isEmpty }

    var isDistilling: Bool {
        youtubeStatus.isRunning || appleMusicStatus.isRunning || spotifyStatus.isRunning
    }

    func status(for source: String) -> SourceStatus {
        switch source {
        case "youtube": return youtubeStatus
        case "apple_music": return appleMusicStatus
        case "spotify": return spotifyStatus
        default: return .idle
        }
    }

    /// Entry point for the tree UI, which thinks in sources rather than methods.
    func distill(source: String) {
        switch source {
        case "youtube": distillYouTube()
        case "apple_music": distillAppleMusic()
        case "spotify": distillSpotify()
        default: break
        }
    }

    /// Fixed per install, so a given person's tree keeps the same character
    /// across launches instead of reshuffling every time it is drawn.
    static let treeSeed: UInt64 = {
        let key = "written.tree.seed"
        if let stored = UserDefaults.standard.object(forKey: key) as? NSNumber {
            return stored.uint64Value
        }
        let seed = UInt64.random(in: 1...UInt64.max)
        UserDefaults.standard.set(NSNumber(value: seed), forKey: key)
        return seed
    }()

    /// The apps of a modality that actually returned records — what its
    /// "Connected to …" bar shows marks for. Read off the records rather than
    /// the statuses, so it survives a relaunch the same way the tree does.
    func connectedSources(for modality: Modality) -> [String] {
        let returned = Set(records.map(\.source))
        return modality.sources.filter(returned.contains)
    }

    var recordCountBySource: [(source: String, count: Int)] {
        Dictionary(grouping: records, by: \.source)
            .map { (source: $0.key, count: $0.value.count) }
            .sorted { $0.source < $1.source }
    }

    // MARK: - Distillation

    func distillYouTube() {
        guard !youtubeStatus.isRunning else { return }
        youtubeStatus = .running
        Task {
            do {
                let distiller = YouTubeDistiller(oauth: googleOAuth)
                let newRecords = try await distiller.distill()
                replaceRecords(from: "youtube", with: newRecords)
                youtubeStatus = .done(count: newRecords.count)
            } catch {
                youtubeStatus = .failed(message: error.localizedDescription)
            }
        }
    }

    func distillAppleMusic() {
        guard !appleMusicStatus.isRunning else { return }
        appleMusicStatus = .running
        Task {
            do {
                let distiller = AppleMusicDistiller()
                let newRecords = try await distiller.distill()
                replaceRecords(from: "apple_music", with: newRecords)
                appleMusicStatus = .done(count: newRecords.count)
            } catch {
                appleMusicStatus = .failed(message: error.localizedDescription)
            }
        }
    }

    func distillSpotify() {
        guard !spotifyStatus.isRunning else { return }
        spotifyStatus = .running
        Task {
            do {
                let distiller = SpotifyDistiller(oauth: spotifyOAuth)
                let newRecords = try await distiller.distill()
                replaceRecords(from: "spotify", with: newRecords)
                spotifyStatus = .done(count: newRecords.count)
            } catch {
                spotifyStatus = .failed(message: error.localizedDescription)
            }
        }
    }

    private func replaceRecords(from source: String, with newRecords: [DistilledRecord]) {
        records.removeAll { $0.source == source }
        records += newRecords

        // Re-distilling the same source with the same library produces an equal
        // `TreeState`, so the tree won't re-animate for no reason.
        treeState = TreeMetrics.state(from: records)
        skeleton = TreeSkeleton.make(from: treeState, seed: Self.treeSeed)
    }

#if DEBUG
    /// TEMPORARY — debug only. Steps the tree through its stages without
    /// connecting anything, so the growing animation can be watched end to end.
    /// It drives the same published state a real distillation does, so the
    /// watering, the dissolve and the redraw all run exactly as they would.
    ///
    /// Walks every `Modality`, not just the connectable ones, and wraps back to
    /// bare soil after the last.
    /// How far the preview stepper walks: the illustrated stages only. Past
    /// them the plant is generated geometry, which is not what the stepper is
    /// for — and connecting a fourth or fifth source is not a thing the app can
    /// do yet either.
    static let previewStages = SeedlingStage.allCases.count - 1

    func advancePreviewStage() {
        guard !isDistilling else { return }

        // Runs through a pretend distillation rather than snapping the state,
        // so the watering can appears and pours the way it does for a real
        // connection — the can is tied to `isDistilling`, so a straight state
        // change would skip it.
        youtubeStatus = .running
        let next = treeState.branches.count >= Self.previewStages ? 0 : treeState.branches.count + 1
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            applyPreview(connected: next)
            youtubeStatus = .idle
        }
    }

    /// Seeds the state as though the first `connected` modalities had been
    /// distilled. Snaps — no faked delay, no watering — because the launch
    /// argument exists to be screenshotted, not watched; the stepper above adds
    /// the pretend distillation when the animation is the thing being looked at.
    func applyPreview(connected: Int) {
        var branches: [Modality: ModalityMetrics] = [:]
        var seeded: [DistilledRecord] = []

        for (step, modality) in Modality.allCases.prefix(max(0, connected)).enumerated() {
            // A record per source, so the "Connected to …" bar has app marks to
            // show. Without them the preview walks the stages but never
            // exercises the thing the bar is for.
            for source in modality.sources {
                seeded.append(
                    DistilledRecord(
                        source: source,
                        dataType: "preview",
                        itemID: "preview",
                        name: "Preview",
                        creator: "",
                        detail: "",
                        extra: "",
                        collectedAt: Date()
                    )
                )
            }
            branches[modality] = ModalityMetrics(
                volume: 60 + 45 * step,
                diversity: min(0.9, 0.35 + 0.13 * Double(step)),
                dominantShare: max(0.15, 0.55 - 0.08 * Double(step))
            )
        }

        records = seeded
        treeState = TreeState(branches: branches)
        skeleton = TreeSkeleton.make(from: treeState, seed: Self.treeSeed)
    }
#endif

    // MARK: - Export

    func prepareExport() {
        exportDocument = CSVDocument(text: CSVExporter.makeCSV(from: records))
        isExporterPresented = true
    }

    func handleExportResult(_ result: Result<URL, Error>) {
        switch result {
        case .success:
            exportResultMessage = "CSV saved. \(records.count) distilled records exported."
        case .failure(let error):
            exportResultMessage = "Export failed: \(error.localizedDescription)"
        }
    }
}
