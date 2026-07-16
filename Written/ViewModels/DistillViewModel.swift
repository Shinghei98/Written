import Foundation
import SwiftUI

@MainActor
final class DistillViewModel: ObservableObject {

    @Published var youtubeStatus: SourceStatus = .idle
    @Published var appleMusicStatus: SourceStatus = .idle
    @Published private(set) var records: [DistilledRecord] = []

    @Published var isExporterPresented = false
    @Published var exportDocument: CSVDocument?
    @Published var exportResultMessage: String?

    private let googleOAuth = GoogleOAuthService()

    var hasRecords: Bool { !records.isEmpty }

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

    private func replaceRecords(from source: String, with newRecords: [DistilledRecord]) {
        records.removeAll { $0.source == source }
        records += newRecords
    }

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
