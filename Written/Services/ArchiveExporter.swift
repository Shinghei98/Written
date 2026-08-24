import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// The whole of somebody's data, in one file they can keep.
///
/// **The CSV was never all of it.** `CSVExporter` writes the eight columns of
/// `DistilledRecord` — which is Written's reading of the sources, not what the
/// sources said. Since `RawArchive` began keeping the bodies, "download a copy
/// of your data" had two possible meanings and was answering the smaller one.
///
/// This exports both: the CSV exactly as before, and every archived response
/// beside it. **The CSV is byte-identical to what the old exporter produced**,
/// which is the property to preserve — somebody with a spreadsheet built on the
/// old file must not find its columns moved because a second file joined it.
///
/// ## Zipped through `NSFileCoordinator`, not by hand
///
/// Foundation has no zip writer, and `.forUploading` is the documented way to
/// get one: it zips a directory and hands back a URL. The alternative — a
/// `FileWrapper` directory, which `.fileExporter` will happily write — produces
/// a *folder* in Files, and a folder of gzipped JSON is not a thing anybody can
/// mail to themselves.
enum ArchiveExporter {

    static func suggestedFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return "written-data-\(formatter.string(from: Date()))"
    }

    /// Assemble the bundle and return its bytes.
    ///
    /// **Returns nil rather than an empty zip.** An export that silently
    /// produced a file with nothing in it is the failure this project has paid
    /// for repeatedly — a successful-looking answer to a question that was
    /// never asked. The caller draws the difference.
    static func bundle(csv: String, archives: [URL]) -> Data? {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("written-export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }

        guard (try? FileManager.default.createDirectory(
            at: staging, withIntermediateDirectories: true
        )) != nil else { return nil }

        // The CSV keeps its own name inside the bundle, so a person who only
        // wants the spreadsheet can find it without reading the rest.
        let csvURL = staging.appendingPathComponent("\(CSVExporter.suggestedFilename()).csv")
        // **`makeCSV` already carries the BOM**, on its first line — every file
        // this project writes is UTF-8 *with* one, because without it Excel
        // falls back to a legacy Western encoding and the bug appears only for
        // the person opening the file. Adding a second here would put a stray
        // character in the first cell, which is the same bug wearing the
        // opposite sign, and it would break the one property this bundle has to
        // keep: the CSV inside it is byte-for-byte what the old export wrote.
        guard (try? Data(csv.utf8).write(to: csvURL)) != nil else {
            return nil
        }

        if !archives.isEmpty {
            let rawDirectory = staging.appendingPathComponent("raw-sources")
            try? FileManager.default.createDirectory(
                at: rawDirectory, withIntermediateDirectories: true
            )
            for archive in archives {
                try? FileManager.default.copyItem(
                    at: archive,
                    to: rawDirectory.appendingPathComponent(archive.lastPathComponent)
                )
            }
            // A note beside them, because a directory of `.json.gz` with no
            // explanation is not an answer to "what is my data".
            let readme = """
            This folder holds what each connected service actually returned,
            before Written made anything of it.

            Each file is gzipped JSON. The name is
            <source>__<endpoint>__<timestamp>.json.gz, and inside, "body_utf8"
            is the response exactly as it arrived for services that speak HTTP,
            or "objects" is what the device framework returned for the ones
            that do not.

            The CSV beside this folder is Written's reading of the same data.
            This folder is the source material it was read from.
            """
            try? Data(readme.utf8).write(
                to: rawDirectory.appendingPathComponent("README.txt")
            )
        }

        var zipped: Data?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(
            readingItemAt: staging, options: [.forUploading],
            error: &coordinationError
        ) { url in
            zipped = try? Data(contentsOf: url)
        }
        guard coordinationError == nil else { return nil }
        return zipped
    }
}

/// The bundle as something `.fileExporter` can write.
///
/// `CSVDocument` stays exactly as it is. Two documents rather than one with a
/// mode flag: the CSV export is a working feature with its own content type,
/// and giving it a branch would be the second place to get the encoding wrong.
struct DataArchiveDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.zip] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        data = contents
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
