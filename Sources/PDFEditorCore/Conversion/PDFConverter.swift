import AppKit
import PDFKit

/// Formats a PDF can be converted to.
public enum ConversionFormat: String, CaseIterable, Identifiable, Sendable {
    case word, excel, powerpoint, image, text, rtf, html, markdown, csv, openDocument, pdfImageOnly

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .word: return "Word (.docx)"
        case .excel: return "Excel (.xlsx)"
        case .powerpoint: return "PowerPoint (.pptx)"
        case .image: return "Images"
        case .text: return "Plain Text (.txt)"
        case .rtf: return "Rich Text (.rtf)"
        case .html: return "Web Page (.html)"
        case .markdown: return "Markdown (.md)"
        case .csv: return "CSV (.csv)"
        case .openDocument: return "OpenDocument Text (.odt)"
        case .pdfImageOnly: return "Image-only PDF"
        }
    }

    public var fileExtension: String {
        switch self {
        case .word: return "docx"
        case .excel: return "xlsx"
        case .powerpoint: return "pptx"
        case .image: return "png"
        case .text: return "txt"
        case .rtf: return "rtf"
        case .html: return "html"
        case .markdown: return "md"
        case .csv: return "csv"
        case .openDocument: return "odt"
        case .pdfImageOnly: return "pdf"
        }
    }

    public var systemImage: String {
        switch self {
        case .word: return "doc.richtext"
        case .excel: return "tablecells"
        case .powerpoint: return "rectangle.on.rectangle"
        case .image: return "photo"
        case .text: return "doc.plaintext"
        case .rtf: return "doc.text"
        case .html: return "globe"
        case .markdown: return "number"
        case .csv: return "list.bullet.rectangle"
        case .openDocument: return "doc"
        case .pdfImageOnly: return "doc.viewfinder"
        }
    }
}

public struct ConversionOptions: Sendable {
    public var pages: IndexSet?
    public var imageFormat: PageRenderer.ImageFormat = .png
    public var dpi: CGFloat = 150
    public var jpegQuality: CGFloat = 0.85
    /// Run OCR on pages without a text layer before extracting text.
    public var ocrScannedPages = false
    public var ocrOptions = OCROptions()

    public init() {}
}

public enum ConversionError: Error, LocalizedError {
    case encodingFailed(String)
    case noPages

    public var errorDescription: String? {
        switch self {
        case .encodingFailed(let format): return "Could not create the \(format) file."
        case .noPages: return "There are no pages to convert."
        }
    }
}

/// Converts PDFs to other formats.
public enum PDFConverter {
    /// Converts `document` and writes the result next to `destination`.
    /// Image conversion of several pages writes one file per page, named
    /// `<name>-001.png` etc. Returns the written files.
    @discardableResult
    public static func convert(_ document: PDFDocument,
                               to format: ConversionFormat,
                               destination: URL,
                               options: ConversionOptions = ConversionOptions()) throws -> [URL] {
        let pages = options.pages ?? PageRange.all(document.pageCount)
        guard !pages.isEmpty else { throw ConversionError.noPages }
        let source = options.ocrScannedPages ? ocrCopy(of: document, pages: pages, options: options.ocrOptions) : document

        switch format {
        case .image:
            return try writeImages(source, pages: pages, destination: destination, options: options)
        case .text:
            try plainText(source, pages: pages).write(to: destination, atomically: true, encoding: .utf8)
        case .markdown:
            try markdown(source, pages: pages).write(to: destination, atomically: true, encoding: .utf8)
        case .csv:
            let rows = pages.flatMap { TableExtractor.rows(on: source.page(at: $0)) + [[]] }
            try csv(rows).write(to: destination, atomically: true, encoding: .utf8)
        case .excel:
            let sheets = pages.map { index in
                XLSXWriter.Sheet(name: "Page \(index + 1)", rows: TableExtractor.rows(on: source.page(at: index)))
            }
            try XLSXWriter(sheets: sheets).data().write(to: destination)
        case .powerpoint:
            try powerpoint(source, pages: pages, options: options).write(to: destination)
        case .word, .rtf, .html, .openDocument:
            try richText(source, pages: pages, format: format).write(to: destination)
        case .pdfImageOnly:
            try imageOnlyPDF(source, pages: pages, options: options).write(to: destination)
        }
        return [destination]
    }

    // MARK: Text

    public static func plainText(_ document: PDFDocument, pages: IndexSet) -> String {
        pages.compactMap { document.page(at: $0)?.string }.joined(separator: "\n\n\u{0C}")
    }

    /// Concatenated attributed text of the pages, as PDFKit extracts it
    /// (fonts, sizes and line breaks preserved).
    public static func attributedText(_ document: PDFDocument, pages: IndexSet) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (ordinal, index) in pages.enumerated() {
            guard let page = document.page(at: index) else { continue }
            var text = page.attributedString ?? NSAttributedString()
            // Some pages return an empty attributed string although they have text.
            if text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let plain = page.string, !plain.isEmpty {
                text = NSAttributedString(string: plain, attributes: [.font: NSFont.systemFont(ofSize: 12)])
            }
            if ordinal > 0 {
                result.append(NSAttributedString(string: "\n\u{0C}"))
            }
            result.append(text)
        }
        return result
    }

    static func richText(_ document: PDFDocument, pages: IndexSet, format: ConversionFormat) throws -> Data {
        let text = attributedText(document, pages: pages)
        let type: NSAttributedString.DocumentType
        switch format {
        case .word: type = .officeOpenXML
        case .rtf: type = .rtf
        case .html: type = .html
        default: type = .openDocument
        }
        var attributes: [NSAttributedString.DocumentAttributeKey: Any] = [.documentType: type]
        if let title = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, !title.isEmpty {
            attributes[.title] = title
        }
        if let page = document.page(at: pages.first ?? 0) {
            attributes[.paperSize] = NSValue(size: PageGeometry.displaySize(of: page))
        }
        do {
            return try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: attributes)
        } catch {
            throw ConversionError.encodingFailed(format.title)
        }
    }

    /// Markdown using font size to find headings and font traits for emphasis.
    public static func markdown(_ document: PDFDocument, pages: IndexSet) -> String {
        let text = attributedText(document, pages: pages)
        let string = text.string as NSString

        // Most common font size is treated as body text.
        var sizeCounts: [CGFloat: Int] = [:]
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let font = value as? NSFont { sizeCounts[font.pointSize.rounded(), default: 0] += range.length }
        }
        let bodySize = sizeCounts.max { $0.value < $1.value }?.key ?? 12

        var lines: [String] = []
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: .byLines) { substring, range, _, _ in
            guard let substring else { return }
            let trimmed = substring.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed == "\u{0C}" {
                lines.append("")
                return
            }
            let font = range.length > 0 ? text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont : nil
            let size = font?.pointSize ?? bodySize
            let bold = font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? false
            var line = trimmed
            if trimmed.hasPrefix("•") || trimmed.hasPrefix("◦") || trimmed.hasPrefix("▪") {
                line = "- " + trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
            } else if size >= bodySize * 1.6 {
                line = "# " + trimmed
            } else if size >= bodySize * 1.3 {
                line = "## " + trimmed
            } else if size >= bodySize * 1.12 || (bold && trimmed.count < 80) {
                line = "### " + trimmed
            }
            lines.append(line)
        }
        // Collapse runs of blank lines.
        var output: [String] = []
        for line in lines where !(line.isEmpty && output.last?.isEmpty == true) {
            output.append(line)
        }
        return output.joined(separator: "\n")
    }

    static func csv(_ rows: [[String]]) -> String {
        rows.map { row in
            row.map { cell in
                cell.contains(",") || cell.contains("\"") || cell.contains("\n")
                    ? "\"" + cell.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                    : cell
            }
            .joined(separator: ",")
        }
        .joined(separator: "\n")
    }

    // MARK: Images

    static func writeImages(_ document: PDFDocument, pages: IndexSet, destination: URL, options: ConversionOptions) throws -> [URL] {
        let base = destination.deletingPathExtension()
        let ext = options.imageFormat.fileExtension
        var written: [URL] = []
        for index in pages {
            guard let page = document.page(at: index),
                  let image = PageRenderer.cgImage(for: page, dpi: options.dpi, includeAnnotations: true),
                  let data = PageRenderer.encode(image, as: options.imageFormat, quality: options.jpegQuality) else {
                throw ConversionError.encodingFailed(options.imageFormat.rawValue.uppercased())
            }
            let url = pages.count == 1
                ? base.appendingPathExtension(ext)
                : URL(fileURLWithPath: base.path + String(format: "-%03d", index + 1)).appendingPathExtension(ext)
            try data.write(to: url)
            written.append(url)
        }
        return written
    }

    static func powerpoint(_ document: PDFDocument, pages: IndexSet, options: ConversionOptions) throws -> Data {
        var slides: [PPTXWriter.Slide] = []
        var slideSize = CGSize(width: 720, height: 540)
        for (ordinal, index) in pages.enumerated() {
            guard let page = document.page(at: index),
                  let image = PageRenderer.cgImage(for: page, dpi: max(options.dpi, 150), includeAnnotations: true),
                  let data = PageRenderer.encode(image, as: .jpeg, quality: 0.9) else { continue }
            if ordinal == 0 { slideSize = PageGeometry.displaySize(of: page) }
            slides.append(PPTXWriter.Slide(imageData: data, imageExtension: "jpeg", altText: page.string ?? ""))
        }
        guard !slides.isEmpty else { throw ConversionError.encodingFailed("PowerPoint") }
        return PPTXWriter(slides: slides, slideSize: slideSize).data()
    }

    static func imageOnlyPDF(_ document: PDFDocument, pages: IndexSet, options: ConversionOptions) throws -> Data {
        let output = PDFDocument()
        for index in pages {
            guard let page = document.page(at: index),
                  let image = PageRenderer.cgImage(for: page, dpi: options.dpi, includeAnnotations: true),
                  let newPage = PageCompositor.imagePage(image, like: page, jpegQuality: options.jpegQuality) else { continue }
            output.insert(newPage, at: output.pageCount)
        }
        guard output.pageCount > 0, let data = output.dataRepresentation() else { throw ConversionError.encodingFailed("PDF") }
        return data
    }

    static func ocrCopy(of document: PDFDocument, pages: IndexSet, options: OCROptions) -> PDFDocument {
        guard let data = document.dataRepresentation(), let copy = PDFDocument(data: data) else { return document }
        var ocr = options
        ocr.skipPagesWithText = true
        _ = try? OCRService.makeSearchable(copy, pages: pages, options: ocr)
        return copy
    }

    // MARK: Creating PDFs

    /// Builds a PDF with one page per image file.
    public static func pdf(fromImages urls: [URL], paperSize: PaperSize?, margin: CGFloat = 0) -> PDFDocument {
        let document = PDFDocument()
        for url in urls {
            guard let image = NSImage(contentsOf: url),
                  let page = PageCompositor.page(for: image, pageSize: paperSize?.size, margin: margin) else { continue }
            document.insert(page, at: document.pageCount)
        }
        return document
    }

    /// Builds a PDF from plain or rich text files (txt, rtf, docx, html, odt).
    public static func pdf(fromTextFile url: URL, paperSize: PaperSize = .letter) throws -> PDFDocument {
        let attributed = try NSAttributedString(url: url, options: [:], documentAttributes: nil)
        return pdf(fromAttributedString: attributed, paperSize: paperSize)
    }

    /// Lays out text on pages with 72 pt margins.
    public static func pdf(fromAttributedString text: NSAttributedString, paperSize: PaperSize = .letter, margin: CGFloat = 72) -> PDFDocument {
        let size = paperSize.size
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return PDFDocument() }

        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let textSize = CGSize(width: size.width - margin * 2, height: size.height - margin * 2)

        var containers: [NSTextContainer] = []
        repeat {
            let container = NSTextContainer(size: textSize)
            layout.addTextContainer(container)
            containers.append(container)
            _ = layout.glyphRange(for: container)
        } while layout.glyphRange(for: containers.last!).upperBound < layout.numberOfGlyphs && containers.count < 5000

        for container in containers {
            context.beginPDFPage(nil)
            NSGraphicsContext.drawing(in: context, flipped: true) {
                context.saveGState()
                // Flip so text lays out top-down.
                context.translateBy(x: 0, y: size.height)
                context.scaleBy(x: 1, y: -1)
                let range = layout.glyphRange(for: container)
                let origin = CGPoint(x: margin, y: margin)
                layout.drawBackground(forGlyphRange: range, at: origin)
                layout.drawGlyphs(forGlyphRange: range, at: origin)
                context.restoreGState()
            }
            context.endPDFPage()
        }
        context.closePDF()
        return PDFDocument(data: data as Data) ?? PDFDocument()
    }
}

/// Reconstructs table-like rows from character positions on a page.
public enum TableExtractor {
    struct Word {
        var text: String
        var rect: CGRect
    }

    /// Rows of cells, top to bottom. Cells are split at wide horizontal gaps
    /// and aligned to column anchors shared across the page.
    public static func rows(on page: PDFPage?) -> [[String]] {
        guard let page, let string = page.string, !string.isEmpty else { return [] }
        let ns = string as NSString
        let count = min(page.numberOfCharacters, ns.length)

        // Group characters into words.
        var words: [Word] = []
        var current: Word?
        var averageWidth: CGFloat = 0
        var widthSamples: CGFloat = 0
        for i in 0..<count {
            let character = ns.substring(with: NSRange(location: i, length: 1))
            let rect = page.characterBounds(at: i)
            let isSpace = character.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if isSpace || rect.isEmpty {
                if let word = current { words.append(word) }
                current = nil
                continue
            }
            averageWidth += rect.width
            widthSamples += 1
            if var word = current,
               abs(rect.midY - word.rect.midY) < max(rect.height, word.rect.height) * 0.5,
               rect.minX - word.rect.maxX < rect.width * 0.6,
               rect.minX >= word.rect.minX {
                word.text += character
                word.rect = word.rect.union(rect)
                current = word
            } else {
                if let word = current { words.append(word) }
                current = Word(text: character, rect: rect)
            }
        }
        if let word = current { words.append(word) }
        guard !words.isEmpty else { return [] }
        let charWidth = widthSamples > 0 ? averageWidth / widthSamples : 5

        // Group words into lines by vertical position.
        let sorted = words.sorted { a, b in
            if abs(a.rect.midY - b.rect.midY) > min(a.rect.height, b.rect.height) * 0.5 { return a.rect.midY > b.rect.midY }
            return a.rect.minX < b.rect.minX
        }
        var lines: [[Word]] = []
        for word in sorted {
            if let last = lines.last?.last, abs(last.rect.midY - word.rect.midY) <= min(last.rect.height, word.rect.height) * 0.5 {
                lines[lines.count - 1].append(word)
            } else {
                lines.append([word])
            }
        }

        // Split lines into cells at gaps wider than ~2 characters.
        let gap = max(charWidth * 2.2, 8)
        var cellLines: [[Word]] = []
        for line in lines {
            var cells: [Word] = []
            for word in line.sorted(by: { $0.rect.minX < $1.rect.minX }) {
                if var cell = cells.last, word.rect.minX - cell.rect.maxX < gap {
                    cell.text += " " + word.text
                    cell.rect = cell.rect.union(word.rect)
                    cells[cells.count - 1] = cell
                } else {
                    cells.append(word)
                }
            }
            cellLines.append(cells)
        }

        // Shared column anchors from cell left edges.
        var anchors: [CGFloat] = []
        for x in cellLines.flatMap({ $0.map(\.rect.minX) }).sorted() {
            if let last = anchors.last, x - last < gap { continue }
            anchors.append(x)
        }
        guard !anchors.isEmpty else { return cellLines.map { $0.map(\.text) } }

        return cellLines.map { cells in
            var row = [String](repeating: "", count: anchors.count)
            for cell in cells {
                var column = 0
                var best = CGFloat.greatestFiniteMagnitude
                for (i, anchor) in anchors.enumerated() where abs(anchor - cell.rect.minX) < best {
                    best = abs(anchor - cell.rect.minX)
                    column = i
                }
                row[column] = row[column].isEmpty ? cell.text : row[column] + " " + cell.text
            }
            while row.last?.isEmpty == true { row.removeLast() }
            return row
        }
    }
}
