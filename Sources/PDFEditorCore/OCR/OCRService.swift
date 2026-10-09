import AppKit
import CoreText
import PDFKit
import Vision

public struct OCROptions: Equatable, Sendable {
    /// BCP-47 language codes, in priority order. Empty means automatic.
    public var languages: [String] = []
    public var accurate = true
    public var usesLanguageCorrection = true
    public var dpi: CGFloat = 300
    /// Skip pages that already contain extractable text.
    public var skipPagesWithText = true

    public init() {}
}

/// One recognized line of text in display space of the rendered page.
public struct RecognizedLine: Equatable, Sendable {
    public let text: String
    /// Normalized (0...1) bounding box with origin at the bottom-left.
    public let normalizedBox: CGRect
    public let confidence: Float
}

/// Text recognition with Vision and searchable-PDF generation.
public enum OCRService {
    public static func supportedLanguages(accurate: Bool = true) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = accurate ? .accurate : .fast
        return (try? request.supportedRecognitionLanguages()) ?? ["en-US"]
    }

    public static func recognize(image: CGImage, options: OCROptions) throws -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = options.accurate ? .accurate : .fast
        request.usesLanguageCorrection = options.usesLanguageCorrection
        if options.languages.isEmpty {
            request.automaticallyDetectsLanguage = true
        } else {
            request.recognitionLanguages = options.languages
        }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        let observations = request.results ?? []
        return observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return RecognizedLine(text: candidate.string, normalizedBox: observation.boundingBox, confidence: candidate.confidence)
        }
    }

    /// Recognizes the text of one page.
    public static func recognize(page: PDFPage, options: OCROptions) throws -> [RecognizedLine] {
        guard let image = PageRenderer.cgImage(for: page, dpi: options.dpi, includeAnnotations: false) else { return [] }
        return try recognize(image: image, options: options)
    }

    /// Returns a copy of `page` with an invisible, selectable text layer for
    /// `lines`. `imageSize` is the display size the boxes are relative to.
    public static func searchablePage(from page: PDFPage, lines: [RecognizedLine], imageSize: CGSize) -> PDFPage? {
        guard !lines.isEmpty else { return page.copy() as? PDFPage }
        return PageCompositor.compose(page, overlay: { context, page in
            _ = PageCompositor.enterDisplaySpace(context, page: page)
            drawInvisibleText(lines, in: context, size: imageSize)
        })
    }

    /// Draws text with the invisible text rendering mode, stretched to fill
    /// each recognized box, so it can be searched and selected.
    static func drawInvisibleText(_ lines: [RecognizedLine], in context: CGContext, size: CGSize) {
        context.saveGState()
        context.setTextDrawingMode(.invisible)
        for line in lines where !line.text.isEmpty {
            let box = CGRect(x: line.normalizedBox.minX * size.width,
                             y: line.normalizedBox.minY * size.height,
                             width: line.normalizedBox.width * size.width,
                             height: line.normalizedBox.height * size.height)
            guard box.width > 1, box.height > 1 else { continue }
            let fontSize = box.height * 0.9
            let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
            let attributed = NSAttributedString(string: line.text, attributes: [.font: font])
            let ctLine = CTLineCreateWithAttributedString(attributed)
            let width = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
            guard width > 0 else { continue }
            context.saveGState()
            context.textMatrix = .identity
            context.translateBy(x: box.minX, y: box.minY + box.height * 0.18)
            context.scaleBy(x: box.width / CGFloat(width), y: 1)
            context.textPosition = .zero
            CTLineDraw(ctLine, context)
            context.restoreGState()
        }
        context.restoreGState()
    }

    /// Runs OCR on `pages`, replacing each with a searchable version.
    /// Returns the original pages for undo.
    public static func makeSearchable(_ document: PDFDocument,
                                      pages: IndexSet,
                                      options: OCROptions,
                                      progress: ((Int, Int) -> Bool)? = nil) throws -> [Int: PDFPage] {
        var replaced: [Int: PDFPage] = [:]
        let total = pages.count
        for (ordinal, index) in pages.enumerated() {
            if let progress, !progress(ordinal, total) { break }
            guard let page = document.page(at: index) else { continue }
            if options.skipPagesWithText,
               let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines), text.count > 20 {
                continue
            }
            let lines = try recognize(page: page, options: options)
            guard !lines.isEmpty,
                  let newPage = searchablePage(from: page, lines: lines, imageSize: PageGeometry.displaySize(of: page)),
                  let old = document.replacePage(at: index, with: newPage) else { continue }
            replaced[index] = old
        }
        _ = progress?(total, total)
        return replaced
    }

    /// Plain text recognized on a page, top to bottom.
    public static func text(of lines: [RecognizedLine]) -> String {
        lines.sorted { a, b in
            if abs(a.normalizedBox.midY - b.normalizedBox.midY) > 0.01 { return a.normalizedBox.midY > b.normalizedBox.midY }
            return a.normalizedBox.minX < b.normalizedBox.minX
        }
        .map(\.text)
        .joined(separator: "\n")
    }
}
