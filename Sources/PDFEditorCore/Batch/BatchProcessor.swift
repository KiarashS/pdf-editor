import AppKit
import PDFKit

/// An operation applied to many files at once.
public enum BatchOperation: Equatable, Sendable {
    case convert(ConversionFormat)
    case compress(PageOperations.CompressionLevel)
    case encrypt(password: String)
    case removePassword(password: String)
    case watermark(text: String)
    case ocr
    case flatten
    case pageNumbers
    /// Merge every input into one PDF, in order.
    case merge
    /// Print each file using the default printer settings.
    case print

    public var title: String {
        switch self {
        case .convert(let format): return "Convert to \(format.title)"
        case .compress: return "Compress"
        case .encrypt: return "Add Password"
        case .removePassword: return "Remove Password"
        case .watermark: return "Add Watermark"
        case .ocr: return "OCR (make searchable)"
        case .flatten: return "Flatten"
        case .pageNumbers: return "Add Page Numbers"
        case .merge: return "Combine into one PDF"
        case .print: return "Print"
        }
    }
}

public struct BatchResult: Identifiable, Sendable {
    public let id = UUID()
    public let input: URL
    public let outputs: [URL]
    public let error: String?
}

/// Runs a `BatchOperation` over files, writing results into `outputFolder`.
public struct BatchProcessor {
    public var operation: BatchOperation
    public var outputFolder: URL
    public var suffix: String = ""

    public init(operation: BatchOperation, outputFolder: URL) {
        self.operation = operation
        self.outputFolder = outputFolder
    }

    func outputURL(for input: URL, extension ext: String) -> URL {
        let name = input.deletingPathExtension().lastPathComponent + suffix
        var url = outputFolder.appendingPathComponent(name).appendingPathExtension(ext)
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = outputFolder.appendingPathComponent("\(name) \(counter)").appendingPathExtension(ext)
            counter += 1
        }
        return url
    }

    /// Processes `inputs`, calling `progress` after each file. Not thread-safe
    /// with respect to the same documents being open elsewhere.
    public func run(_ inputs: [URL], progress: ((Int, Int) -> Void)? = nil) -> [BatchResult] {
        if operation == .merge {
            return [merge(inputs)]
        }
        var results: [BatchResult] = []
        for (index, input) in inputs.enumerated() {
            progress?(index, inputs.count)
            do {
                let outputs = try process(input)
                results.append(BatchResult(input: input, outputs: outputs, error: nil))
            } catch {
                results.append(BatchResult(input: input, outputs: [], error: error.localizedDescription))
            }
        }
        progress?(inputs.count, inputs.count)
        return results
    }

    func open(_ url: URL, password: String? = nil) throws -> PDFDocument {
        if ["png", "jpg", "jpeg", "heic", "tiff", "tif", "gif", "bmp"].contains(url.pathExtension.lowercased()) {
            return PDFConverter.pdf(fromImages: [url], paperSize: nil)
        }
        if ["txt", "rtf", "docx", "doc", "html", "odt", "md"].contains(url.pathExtension.lowercased()) {
            return try PDFConverter.pdf(fromTextFile: url)
        }
        guard let document = PDFDocument(url: url) else { throw ExportError.serializationFailed }
        if document.isLocked {
            guard let password, document.unlock(withPassword: password) else { throw ExportError.locked }
        }
        return document
    }

    func process(_ input: URL) throws -> [URL] {
        switch operation {
        case .convert(let format):
            let document = try open(input)
            return try PDFConverter.convert(document, to: format, destination: outputURL(for: input, extension: format.fileExtension))
        case .compress(let level):
            let document = try open(input)
            let data = try PageOperations.compressedData(document, level: level)
            let url = outputURL(for: input, extension: "pdf")
            try data.write(to: url)
            return [url]
        case .encrypt(let password):
            let document = try open(input)
            var options = ExportOptions()
            options.security.openPassword = password
            return [try write(DocumentExporter.export(document, options: options), for: input)]
        case .removePassword(let password):
            let document = try open(input, password: password)
            return [try write(DocumentExporter.export(document), for: input)]
        case .watermark(let text):
            let document = try open(input)
            var options = WatermarkOptions()
            options.content = .text(text)
            PageDecorator.applyWatermark(options, to: document, pages: PageRange.all(document.pageCount))
            return [try write(DocumentExporter.export(document), for: input)]
        case .ocr:
            let document = try open(input)
            _ = try OCRService.makeSearchable(document, pages: PageRange.all(document.pageCount), options: OCROptions())
            return [try write(DocumentExporter.export(document), for: input)]
        case .flatten:
            let document = try open(input)
            PageOperations.flatten(document, pages: PageRange.all(document.pageCount))
            return [try write(DocumentExporter.export(document), for: input)]
        case .pageNumbers:
            let document = try open(input)
            var options = HeaderFooterOptions()
            options.fileName = input.lastPathComponent
            PageDecorator.applyHeaderFooter(options, to: document, pages: PageRange.all(document.pageCount))
            return [try write(DocumentExporter.export(document), for: input)]
        case .print:
            let document = try open(input)
            guard let operation = document.printOperation(for: NSPrintInfo.shared, scalingMode: .pageScaleToFit, autoRotate: true) else {
                throw ExportError.serializationFailed
            }
            operation.showsPrintPanel = false
            operation.showsProgressPanel = false
            operation.run()
            return []
        case .merge:
            return merge([input]).outputs
        }
    }

    func write(_ data: Data, for input: URL) throws -> URL {
        let url = outputURL(for: input, extension: "pdf")
        try data.write(to: url)
        return url
    }

    func merge(_ inputs: [URL]) -> BatchResult {
        let merged = PDFDocument()
        var errors: [String] = []
        for input in inputs {
            do {
                let document = try open(input)
                _ = merged.insertPages(from: document, at: merged.pageCount)
            } catch {
                errors.append("\(input.lastPathComponent): \(error.localizedDescription)")
            }
        }
        let url = outputFolder.appendingPathComponent("Combined.pdf")
        var target = url
        var counter = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = outputFolder.appendingPathComponent("Combined \(counter).pdf")
            counter += 1
        }
        guard merged.pageCount > 0, merged.write(to: target) else {
            return BatchResult(input: url, outputs: [], error: errors.isEmpty ? "Nothing to combine." : errors.joined(separator: "\n"))
        }
        return BatchResult(input: url, outputs: [target], error: errors.isEmpty ? nil : errors.joined(separator: "\n"))
    }
}
