import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = DistillViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    header

                    SourceCardView(
                        title: "YouTube",
                        subtitle: "Subscriptions · Liked videos · Playlists",
                        systemImage: "play.rectangle.fill",
                        tint: .red,
                        status: viewModel.youtubeStatus,
                        action: viewModel.distillYouTube
                    )

                    SourceCardView(
                        title: "Apple Music",
                        subtitle: "Library · Playlists · Listening history · Recommendations",
                        systemImage: "music.note",
                        tint: .pink,
                        status: viewModel.appleMusicStatus,
                        action: viewModel.distillAppleMusic
                    )

                    exportSection
                }
                .padding()
            }
            .navigationTitle("Written")
            .fileExporter(
                isPresented: $viewModel.isExporterPresented,
                document: viewModel.exportDocument,
                contentType: .commaSeparatedText,
                defaultFilename: CSVExporter.suggestedFilename()
            ) { result in
                viewModel.handleExportResult(result)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Distill your apps")
                .font(.title2.bold())
            Text("One tap per app. Written extracts your digital footprint locally and turns it into the signals behind your dynamic profile.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var exportSection: some View {
        VStack(spacing: 12) {
            if viewModel.hasRecords {
                ForEach(viewModel.recordCountBySource, id: \.source) { entry in
                    HStack {
                        Text(entry.source == "youtube" ? "YouTube" : "Apple Music")
                        Spacer()
                        Text("\(entry.count) records")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
                .padding(.horizontal, 4)
            }

            Button(action: viewModel.prepareExport) {
                Label("Download CSV", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!viewModel.hasRecords)

            if let message = viewModel.exportResultMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

/// One distillable app: icon, what gets extracted, live status, and the single
/// "Distill" button that triggers the whole consent + extraction flow.
struct SourceCardView: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    let status: SourceStatus
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(tint, in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            statusView

            Button(action: action) {
                Group {
                    if status.isRunning {
                        ProgressView()
                    } else {
                        Text(buttonTitle)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(tint)
            .disabled(status.isRunning)
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var buttonTitle: String {
        switch status {
        case .done: return "Distill again"
        case .failed: return "Retry distill"
        default: return "Distill"
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .idle:
            EmptyView()
        case .running:
            Label("Distilling…", systemImage: "hourglass")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .done(let count):
            Label("\(count) records distilled", systemImage: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
