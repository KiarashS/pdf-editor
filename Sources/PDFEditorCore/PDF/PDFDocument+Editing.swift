import AppKit
import PDFKit

extension PDFDocument {
    /// Pages in document order.
    public var pages: [PDFPage] {
        (0..<pageCount).compactMap { page(at: $0) }
    }

    /// Replaces the page at `index`, moving its annotations to the new page and
    /// pointing outline items and links at the new page. Returns the old page,
    /// which can be passed back to undo the replacement.
    @discardableResult
    public func replacePage(at index: Int, with newPage: PDFPage, transferAnnotations: Bool = true) -> PDFPage? {
        guard let oldPage = page(at: index), oldPage !== newPage else { return nil }
        if transferAnnotations {
            for annotation in oldPage.annotations {
                oldPage.removeAnnotation(annotation)
                newPage.addAnnotation(annotation)
            }
        }
        removePage(at: index)
        insert(newPage, at: index)
        retargetDestinations(from: oldPage, to: newPage)
        return oldPage
    }

    /// Points every outline item and link annotation that targets `oldPage` at `newPage`.
    public func retargetDestinations(from oldPage: PDFPage, to newPage: PDFPage) {
        func visit(_ item: PDFOutline) {
            if let destination = item.destination, destination.page === oldPage {
                item.destination = PDFDestination(page: newPage, at: destination.point)
            }
            if let action = item.action as? PDFActionGoTo, action.destination.page === oldPage {
                action.destination = PDFDestination(page: newPage, at: action.destination.point)
            }
            for i in 0..<item.numberOfChildren {
                if let child = item.child(at: i) { visit(child) }
            }
        }
        if let root = outlineRoot { visit(root) }

        for page in pages {
            for annotation in page.annotations {
                if let destination = annotation.destination, destination.page === oldPage {
                    annotation.destination = PDFDestination(page: newPage, at: destination.point)
                }
            }
        }
    }

    /// Copies pages from another document. Pages are copied so the source
    /// document stays intact.
    public func insertPages(from source: PDFDocument, indexes: IndexSet? = nil, at index: Int) -> [PDFPage] {
        var inserted: [PDFPage] = []
        var target = min(max(index, 0), pageCount)
        for sourceIndex in indexes ?? PageRange.all(source.pageCount) {
            guard let page = source.page(at: sourceIndex)?.copy() as? PDFPage else { continue }
            insert(page, at: target)
            inserted.append(page)
            target += 1
        }
        return inserted
    }

    /// A new document containing copies of the given pages (with annotations).
    public func extractDocument(pages indexes: IndexSet) -> PDFDocument {
        let result = PDFDocument()
        for index in indexes {
            guard let copy = page(at: index)?.copy() as? PDFPage else { continue }
            result.insert(copy, at: result.pageCount)
        }
        if let attributes = documentAttributes {
            result.documentAttributes = attributes
        }
        return result
    }

    /// Writes the document with options to a temporary file and returns the bytes.
    public func data(withOptions options: [PDFDocumentWriteOption: Any]) -> Data? {
        if options.isEmpty { return dataRepresentation() }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        guard write(to: url, withOptions: options) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Every annotation in the document with its page index.
    public func allAnnotations() -> [(pageIndex: Int, annotation: PDFAnnotation)] {
        var result: [(Int, PDFAnnotation)] = []
        for index in 0..<pageCount {
            guard let page = page(at: index) else { continue }
            for annotation in page.annotations {
                result.append((index, annotation))
            }
        }
        return result
    }
}

extension PDFAnnotation {
    /// The subtype without the leading slash, e.g. "Highlight".
    public var subtypeName: String {
        (type ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    public func isSubtype(_ subtype: PDFAnnotationSubtype) -> Bool {
        subtypeName == subtype.rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// A short label for lists, e.g. "Highlight" or "Text Field".
    public var displayName: String {
        if let overlay = self as? OverlayAnnotation { return overlay.overlayKindName }
        if isSubtype(.widget) {
            switch widgetFieldType {
            case .text: return "Text Field"
            case .choice: return isListChoice ? "List Box" : "Combo Box"
            case .signature: return "Signature Field"
            case .button:
                switch widgetControlType {
                case .checkBoxControl: return "Checkbox"
                case .radioButtonControl: return "Radio Button"
                default: return "Button"
                }
            default: return "Form Field"
            }
        }
        switch subtypeName {
        case "FreeText": return "Text Box"
        case "Text": return "Note"
        case "Square": return "Rectangle"
        case "Circle": return "Oval"
        case "StrikeOut": return "Strikethrough"
        case "Ink": return "Drawing"
        case "":
            return "Annotation"
        default:
            return subtypeName
        }
    }

    public var isRedactionMark: Bool {
        (value(forAnnotationKey: .name) as? String)?.hasPrefix(RedactionMark.namePrefix) == true
    }
}

/// Identifies square annotations that mark an area for redaction.
public enum RedactionMark {
    public static let namePrefix = "pdfeditor.redact."

    public static func make(bounds: CGRect) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: bounds, forType: .square, withProperties: nil)
        annotation.color = NSColor.systemRed
        annotation.interiorColor = NSColor.systemRed.withAlphaComponent(0.18)
        let border = PDFBorder()
        border.lineWidth = 1.5
        border.style = .dashed
        border.dashPattern = [4, 2]
        annotation.border = border
        annotation.contents = "Marked for redaction"
        annotation.setValue(namePrefix + UUID().uuidString, forAnnotationKey: .name)
        return annotation
    }
}
