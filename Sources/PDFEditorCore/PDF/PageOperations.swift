import AppKit
import PDFKit

/// Redaction, flattening, cropping and compression.
public enum PageOperations {
    // MARK: Redaction

    /// Permanently removes everything under `marks` (page space rects per page
    /// index). Affected pages are rasterized so no text, vector or image data
    /// survives underneath; pass `ocr` to restore a searchable text layer for
    /// the rest of the page. Returns the original pages for undo.
    @discardableResult
    public static func redact(_ document: PDFDocument,
                              marks: [Int: [CGRect]],
                              fillColor: NSColor = .black,
                              dpi: CGFloat = 200,
                              ocr: OCROptions? = nil) -> [Int: PDFPage] {
        var replaced: [Int: PDFPage] = [:]
        for (index, rects) in marks.sorted(by: { $0.key < $1.key }) where !rects.isEmpty {
            guard let page = document.page(at: index) else { continue }

            // Drop annotations inside redacted areas and the marks themselves.
            for annotation in page.annotations where annotation.isRedactionMark || rects.contains(where: { $0.intersects(annotation.bounds) }) {
                page.removeAnnotation(annotation)
            }

            guard let image = PageRenderer.cgImage(for: page, dpi: dpi, includeAnnotations: false, decorate: { context in
                context.setFillColor(fillColor.cgColor)
                for rect in rects { context.fill(rect) }
            }) else { continue }

            var newPage = PageCompositor.imagePage(image, like: page)
            if let ocr, let rasterPage = newPage,
               let lines = try? OCRService.recognize(image: image, options: ocr) {
                newPage = OCRService.searchablePage(from: rasterPage, lines: lines, imageSize: PageGeometry.displaySize(of: page))
            }
            guard let newPage else { continue }
            if let old = document.replacePage(at: index, with: newPage) {
                replaced[index] = old
            }
        }
        return replaced
    }

    /// Collects redaction mark annotations, grouped by page index.
    public static func redactionMarks(in document: PDFDocument) -> [Int: [CGRect]] {
        var marks: [Int: [CGRect]] = [:]
        for (index, annotation) in document.allAnnotations() where annotation.isRedactionMark {
            marks[index, default: []].append(annotation.bounds)
        }
        return marks
    }

    /// Page-space rectangles of every occurrence of `text`.
    public static func occurrences(of text: String, in document: PDFDocument, caseSensitive: Bool = false) -> [Int: [CGRect]] {
        guard !text.isEmpty else { return [:] }
        var result: [Int: [CGRect]] = [:]
        let options: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        for selection in document.findString(text, withOptions: options) {
            for line in selection.selectionsByLine() {
                for page in line.pages {
                    let index = document.index(for: page)
                    result[index, default: []].append(line.bounds(for: page).insetBy(dx: -1, dy: -1))
                }
            }
        }
        return result
    }

    // MARK: Flattening

    /// Burns annotations (including form fields) into the page content.
    @discardableResult
    public static func flatten(_ document: PDFDocument, pages: IndexSet) -> [Int: PDFPage] {
        var replaced: [Int: PDFPage] = [:]
        for index in pages {
            guard let page = document.page(at: index), !page.annotations.isEmpty else { continue }
            let annotations = page.annotations.filter { !$0.isSubtype(.popup) && !$0.isSubtype(.link) }
            guard let newPage = PageCompositor.compose(page, overlay: { context, page in
                NSGraphicsContext.drawing(in: context) {
                    for annotation in annotations where annotation.shouldDisplay {
                        context.saveGState()
                        if let overlay = annotation as? OverlayAnnotation {
                            overlay.drawOverlay(in: context)
                        } else {
                            annotation.draw(with: .mediaBox, in: context)
                        }
                        context.restoreGState()
                    }
                }
            }) else { continue }
            // Keep links; everything else is now page content.
            let links = page.annotations.filter { $0.isSubtype(.link) }
            for link in links {
                page.removeAnnotation(link)
                newPage.addAnnotation(link)
            }
            if let old = document.replacePage(at: index, with: newPage, transferAnnotations: false) {
                replaced[index] = old
            }
        }
        return replaced
    }

    // MARK: Cropping

    /// Sets the crop box of each page, inset from the media box by `margins`
    /// (top, left, bottom, right in display orientation). Returns the previous crop boxes.
    @discardableResult
    public static func crop(_ document: PDFDocument, pages: IndexSet, margins: NSEdgeInsets) -> [Int: CGRect] {
        var previous: [Int: CGRect] = [:]
        for index in pages {
            guard let page = document.page(at: index) else { continue }
            previous[index] = page.bounds(for: .cropBox)
            let media = page.bounds(for: .mediaBox)
            // Convert display-oriented margins to page-space edges.
            let edges: (left: CGFloat, bottom: CGFloat, right: CGFloat, top: CGFloat)
            switch PageGeometry.rotation(of: page) {
            case 90: edges = (margins.top, margins.left, margins.bottom, margins.right)
            case 180: edges = (margins.right, margins.top, margins.left, margins.bottom)
            case 270: edges = (margins.bottom, margins.right, margins.top, margins.left)
            default: edges = (margins.left, margins.bottom, margins.right, margins.top)
            }
            let rect = CGRect(x: media.minX + edges.left,
                              y: media.minY + edges.bottom,
                              width: media.width - edges.left - edges.right,
                              height: media.height - edges.bottom - edges.top)
            if rect.width > 10, rect.height > 10 {
                page.setBounds(rect, for: .cropBox)
            }
        }
        return previous
    }

    /// Detects the bounding box of visible content (non-white pixels) in display space margins.
    public static func contentMargins(of page: PDFPage, threshold: UInt8 = 245) -> NSEdgeInsets? {
        let dpi: CGFloat = 50
        guard let image = PageRenderer.cgImage(for: page, dpi: dpi, includeAnnotations: false),
              let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return nil }
        let width = image.width
        let height = image.height
        let bytesPerRow = image.bytesPerRow
        let bytesPerPixel = image.bitsPerPixel / 8
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * bytesPerPixel
                if bytes[offset] < threshold || bytes[offset + 1] < threshold || bytes[offset + 2] < threshold {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let scale = 72 / dpi
        let pad: CGFloat = 6
        // Bitmap rows run top to bottom.
        return NSEdgeInsets(top: max(CGFloat(minY) * scale - pad, 0),
                            left: max(CGFloat(minX) * scale - pad, 0),
                            bottom: max(CGFloat(height - 1 - maxY) * scale - pad, 0),
                            right: max(CGFloat(width - 1 - maxX) * scale - pad, 0))
    }

    // MARK: Compression

    public enum CompressionLevel: String, CaseIterable, Identifiable, Sendable {
        /// Keeps text and vectors; re-encodes images as JPEG at screen resolution.
        case optimized
        /// Rasterizes every page at 150 dpi, JPEG quality 0.7.
        case medium
        /// Rasterizes every page at 96 dpi, JPEG quality 0.5.
        case small

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .optimized: return "Optimized (keeps text)"
            case .medium: return "Medium (rasterize 150 dpi)"
            case .small: return "Smallest (rasterize 96 dpi)"
            }
        }

        var raster: (dpi: CGFloat, quality: CGFloat)? {
            switch self {
            case .optimized: return nil
            case .medium: return (150, 0.7)
            case .small: return (96, 0.5)
            }
        }
    }

    /// Returns a compressed copy of `document` as bytes. Rasterizing levels
    /// optionally run OCR so the result stays searchable.
    public static func compressedData(_ document: PDFDocument,
                                      level: CompressionLevel,
                                      security: SecuritySettings = SecuritySettings(),
                                      ocr: OCROptions? = nil,
                                      progress: ((Int, Int) -> Void)? = nil) throws -> Data {
        var options = ExportOptions()
        options.security = security
        guard let raster = level.raster else {
            options.saveImagesAsJPEG = true
            options.optimizeImagesForScreen = true
            return try DocumentExporter.export(document, options: options)
        }

        // Flatten overlays first so they survive rasterization.
        let base = try DocumentExporter.export(document)
        guard let copy = PDFDocument(data: base) else { throw ExportError.serializationFailed }
        for index in 0..<copy.pageCount {
            progress?(index, copy.pageCount)
            guard let page = copy.page(at: index),
                  let image = PageRenderer.cgImage(for: page, dpi: raster.dpi, includeAnnotations: true),
                  var newPage = PageCompositor.imagePage(image, like: page, jpegQuality: raster.quality) else { continue }
            if let ocr, let lines = try? OCRService.recognize(image: image, options: ocr),
               let searchable = OCRService.searchablePage(from: newPage, lines: lines, imageSize: PageGeometry.displaySize(of: page)) {
                newPage = searchable
            }
            copy.replacePage(at: index, with: newPage, transferAnnotations: false)
        }
        progress?(copy.pageCount, copy.pageCount)
        guard let data = copy.data(withOptions: options.writeOptions()) else { throw ExportError.serializationFailed }
        return data
    }
}

/// Document information dictionary fields.
public struct DocumentMetadata: Equatable {
    public var title = ""
    public var author = ""
    public var subject = ""
    public var keywords = ""
    public var creator = ""
    public var producer = ""
    public var creationDate: Date?
    public var modificationDate: Date?

    public init() {}

    public init(document: PDFDocument) {
        let attributes = document.documentAttributes ?? [:]
        func string(_ key: PDFDocumentAttribute) -> String {
            if let value = attributes[key] as? String { return value }
            if let values = attributes[key] as? [String] { return values.joined(separator: ", ") }
            return ""
        }
        title = string(.titleAttribute)
        author = string(.authorAttribute)
        subject = string(.subjectAttribute)
        keywords = string(.keywordsAttribute)
        creator = string(.creatorAttribute)
        producer = string(.producerAttribute)
        creationDate = attributes[PDFDocumentAttribute.creationDateAttribute] as? Date
        modificationDate = attributes[PDFDocumentAttribute.modificationDateAttribute] as? Date
    }

    public func apply(to document: PDFDocument) {
        var attributes = document.documentAttributes ?? [:]
        attributes[PDFDocumentAttribute.titleAttribute] = title
        attributes[PDFDocumentAttribute.authorAttribute] = author
        attributes[PDFDocumentAttribute.subjectAttribute] = subject
        attributes[PDFDocumentAttribute.keywordsAttribute] = keywords
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        attributes[PDFDocumentAttribute.creatorAttribute] = creator
        attributes[PDFDocumentAttribute.modificationDateAttribute] = Date()
        document.documentAttributes = attributes
    }
}
