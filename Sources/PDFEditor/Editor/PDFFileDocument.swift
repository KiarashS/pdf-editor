import PDFEditorCore
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// The SwiftUI document. Holds the PDFKit document and write settings;
/// all editing goes through `EditorController`.
final class PDFFileDocument: ReferenceFileDocument {
    typealias Snapshot = Data

    static var readableContentTypes: [UTType] { [.pdf] }
    static var writableContentTypes: [UTType] { [.pdf] }

    let pdf: PDFDocument
    /// Bytes as read from disk, written back unchanged while the file is locked.
    private let originalData: Data?
    var exportOptions = ExportOptions()

    init() {
        pdf = PDFDocument()
        if let page = PageCompositor.blankPage(size: PaperSize.letter.size) {
            pdf.insert(page, at: 0)
        }
        originalData = nil
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let document = PDFDocument(data: data) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        pdf = document
        originalData = data
    }

    func snapshot(contentType: UTType) throws -> Data {
        if pdf.isLocked, let originalData { return originalData }
        return try DocumentExporter.export(pdf, options: exportOptions)
    }

    func fileWrapper(snapshot: Data, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: snapshot)
    }
}
