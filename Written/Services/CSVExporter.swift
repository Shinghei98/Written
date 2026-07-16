import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Builds the unified distillation CSV and wraps it for SwiftUI's file exporter,
/// which lets the user save it to Files / iCloud Drive or share it onward.
enum CSVExporter {

    static let header = "source,data_type,item_id,name,creator,detail,extra,collected_at"

    static func makeCSV(from records: [DistilledRecord]) -> String {
        let formatter = ISO8601DateFormatter()
        // Leading U+FEFF (UTF-8 BOM): without it Excel misreads non-Latin
        // text (Korean, Japanese, ...) as a legacy encoding.
        var lines = ["\u{FEFF}" + header]
        lines.reserveCapacity(records.count + 1)
        for record in records {
            lines.append(
                [
                    record.source,
                    record.dataType,
                    record.itemID,
                    record.name,
                    record.creator,
                    record.detail,
                    record.extra,
                    formatter.string(from: record.collectedAt),
                ]
                .map(escape)
                .joined(separator: ",")
            )
        }
        return lines.joined(separator: "\r\n")
    }

    static func suggestedFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return "written-distillation-\(formatter.string(from: Date()))"
    }

    /// RFC 4180 escaping: wrap in quotes when the field contains
    /// a comma, quote, or newline; double any embedded quotes.
    private static func escape(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") {
            return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return field
    }
}

/// FileDocument wrapper so ContentView can present the system save sheet.
struct CSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        text = String(decoding: data, as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
