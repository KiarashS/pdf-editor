import AppKit
import PDFEditorCore
import PDFKit
import UniformTypeIdentifiers

/// Annotation properties captured for undo.
struct AnnotationSnapshot {
    var bounds: CGRect
    var color: NSColor
    var interiorColor: NSColor?
    var contents: String?
    var font: NSFont?
    var fontColor: NSColor?
    var lineWidth: CGFloat?
    var alignment: NSTextAlignment
    var url: URL?
    var fieldName: String?
    var widgetStringValue: String?
    var choices: [String]?
    var isReadOnly: Bool
    var backgroundColor: NSColor?
    var imageOpacity: CGFloat?
    var imageRotation: CGFloat?
    var replacementText: String?
    var replacementFont: NSFont?
    var replacementColor: NSColor?
    var coverColor: NSColor?

    init(_ annotation: PDFAnnotation) {
        bounds = annotation.bounds
        color = annotation.color
        interiorColor = annotation.interiorColor
        contents = annotation.contents
        font = annotation.font
        fontColor = annotation.fontColor
        lineWidth = annotation.border?.lineWidth
        alignment = annotation.alignment
        url = annotation.url
        fieldName = annotation.fieldName
        widgetStringValue = annotation.widgetStringValue
        choices = annotation.choices
        isReadOnly = annotation.isReadOnly
        backgroundColor = annotation.backgroundColor
        if let image = annotation as? ImageOverlayAnnotation {
            imageOpacity = image.imageOpacity
            imageRotation = image.imageRotation
        }
        if let text = annotation as? TextReplacementAnnotation {
            replacementText = text.text
            replacementFont = text.textFont
            replacementColor = text.textColor
            coverColor = text.coverColor
        }
    }

    func apply(to annotation: PDFAnnotation) {
        annotation.bounds = bounds
        annotation.color = color
        annotation.interiorColor = interiorColor
        annotation.contents = contents
        if let font { annotation.font = font }
        if let fontColor { annotation.fontColor = fontColor }
        if let lineWidth {
            let border = annotation.border ?? PDFBorder()
            border.lineWidth = lineWidth
            annotation.border = border
        }
        annotation.alignment = alignment
        if annotation.isSubtype(.link) { annotation.url = url }
        if annotation.isSubtype(.widget) {
            annotation.fieldName = fieldName
            annotation.widgetStringValue = widgetStringValue
            annotation.choices = choices
            annotation.isReadOnly = isReadOnly
            annotation.backgroundColor = backgroundColor
        }
        if let image = annotation as? ImageOverlayAnnotation {
            image.imageOpacity = imageOpacity ?? 1
            image.imageRotation = imageRotation ?? 0
        }
        if let text = annotation as? TextReplacementAnnotation {
            text.text = replacementText ?? text.text
            text.textFont = replacementFont ?? text.textFont
            text.textColor = replacementColor ?? text.textColor
            text.coverColor = coverColor ?? text.coverColor
        }
    }
}

extension EditorController {
    // MARK: Adding and removing

    func add(_ annotations: [PDFAnnotation], to page: PDFPage, actionName: String, select: Bool = true) {
        guard !annotations.isEmpty else { return }
        for annotation in annotations { page.addAnnotation(annotation) }
        if select, annotations.count == 1 { selectedAnnotation = annotations[0] }
        pdfView?.annotationsChanged(on: page)
        registerUndo(actionName) { controller in
            controller.remove(annotations, actionName: actionName)
        }
    }

    func remove(_ annotations: [PDFAnnotation], actionName: String = "Delete") {
        var removed: [(PDFPage, PDFAnnotation)] = []
        for annotation in annotations {
            guard let page = annotation.page else { continue }
            if let popup = annotation.popup { page.removeAnnotation(popup) }
            page.removeAnnotation(annotation)
            removed.append((page, annotation))
            pdfView?.annotationsChanged(on: page)
        }
        if let selected = selectedAnnotation, annotations.contains(where: { $0 === selected }) {
            selectedAnnotation = nil
        }
        guard !removed.isEmpty else { return }
        registerUndo(actionName) { controller in
            for (page, annotation) in removed {
                page.addAnnotation(annotation)
                controller.pdfView?.annotationsChanged(on: page)
            }
            controller.registerUndo(actionName) { $0.remove(removed.map(\.1), actionName: actionName) }
        }
    }

    func deleteSelectedAnnotation() {
        guard let annotation = selectedAnnotation else { return }
        remove([annotation])
    }

    /// Changes an annotation with undo support.
    func modify(_ annotation: PDFAnnotation, actionName: String, _ change: (PDFAnnotation) -> Void) {
        let before = AnnotationSnapshot(annotation)
        change(annotation)
        refresh(annotation)
        registerUndo(actionName) { controller in
            controller.restore(annotation, to: before, actionName: actionName)
        }
    }

    private func restore(_ annotation: PDFAnnotation, to snapshot: AnnotationSnapshot, actionName: String) {
        let current = AnnotationSnapshot(annotation)
        snapshot.apply(to: annotation)
        refresh(annotation)
        registerUndo(actionName) { controller in
            controller.restore(annotation, to: current, actionName: actionName)
        }
    }

    /// Records a move or resize that already happened during a drag.
    func didChangeBounds(of annotation: PDFAnnotation, from original: CGRect) {
        guard annotation.bounds != original else { return }
        var before = AnnotationSnapshot(annotation)
        before.bounds = original
        refresh(annotation)
        registerUndo("Move") { controller in
            controller.restore(annotation, to: before, actionName: "Move")
        }
    }

    func nudgeSelectedAnnotation(dx: CGFloat, dy: CGFloat) {
        guard let annotation = selectedAnnotation else { return }
        modify(annotation, actionName: "Move") { $0.bounds = $0.bounds.offsetBy(dx: dx, dy: dy) }
    }

    func duplicateSelectedAnnotation() {
        guard let annotation = selectedAnnotation, let page = annotation.page,
              let copy = annotation.copy() as? PDFAnnotation else { return }
        if let image = annotation as? ImageOverlayAnnotation {
            let duplicate = ImageOverlayAnnotation(image: image.image, bounds: image.bounds.offsetBy(dx: 12, dy: -12))
            duplicate.imageOpacity = image.imageOpacity
            add([duplicate], to: page, actionName: "Duplicate")
            return
        }
        copy.bounds = annotation.bounds.offsetBy(dx: 12, dy: -12)
        add([copy], to: page, actionName: "Duplicate")
    }

    // MARK: Creating from tools

    /// Converts the current text selection into markup or redaction marks.
    func applyMarkupToSelection() {
        guard let selection = pdfView?.currentSelection, let text = selection.string,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        switch tool {
        case .highlight, .underline, .strikeout:
            let kind: AnnotationFactory.MarkupKind = tool == .highlight ? .highlight : (tool == .underline ? .underline : .strikeOut)
            let color = tool == .highlight ? style.highlightColor.withAlphaComponent(0.5) : style.strokeColor
            let created = AnnotationFactory.markup(kind, selection: selection, color: color)
            addGrouped(created, actionName: tool.title)
        case .redactText:
            var created: [(PDFPage, PDFAnnotation)] = []
            for line in selection.selectionsByLine() {
                for page in line.pages {
                    created.append((page, RedactionMark.make(bounds: line.bounds(for: page).insetBy(dx: -1, dy: -1))))
                }
            }
            addGrouped(created, actionName: "Mark for Redaction")
        default:
            return
        }
        pdfView?.clearSelection()
    }

    /// Adds annotations that may span pages as one undoable step.
    func addGrouped(_ items: [(PDFPage, PDFAnnotation)], actionName: String) {
        guard !items.isEmpty else { return }
        for (page, annotation) in items {
            page.addAnnotation(annotation)
            pdfView?.annotationsChanged(on: page)
        }
        registerUndo(actionName) { controller in
            controller.remove(items.map(\.1), actionName: actionName)
        }
    }

    func addInk(strokes: [[CGPoint]], on page: PDFPage) {
        let simplified = strokes.map { AnnotationFactory.simplify($0) }
        let isMarker = tool == .highlighterPen
        let color = isMarker ? style.highlightColor.withAlphaComponent(0.45) : style.strokeColor.withAlphaComponent(style.opacity)
        let width = isMarker ? max(style.lineWidth * 5, 10) : style.lineWidth
        guard let ink = AnnotationFactory.ink(strokes: simplified, color: color, lineWidth: width) else { return }
        add([ink], to: page, actionName: tool.title, select: false)
    }

    func createLine(from start: CGPoint, to end: CGPoint, on page: PDFPage) {
        guard hypot(end.x - start.x, end.y - start.y) > 3 else { return }
        switch tool {
        case .line:
            add([AnnotationFactory.line(from: start, to: end, style: style, arrow: false)], to: page, actionName: "Line")
        case .arrow:
            add([AnnotationFactory.line(from: start, to: end, style: style, arrow: true)], to: page, actionName: "Arrow")
        case .measure:
            add(AnnotationFactory.measurement(from: start, to: end, unit: measureUnit, scale: measureScale, style: style),
                to: page, actionName: "Measure", select: false)
        default:
            break
        }
    }

    /// Handles a drag (or click when `rect` is nil) with a rectangle tool.
    func createFromRect(_ rect: CGRect?, at point: CGPoint, on page: PDFPage) {
        func sized(_ size: CGSize) -> CGRect {
            rect ?? CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height)
        }

        switch tool {
        case .rectangle:
            add([AnnotationFactory.shape(.rectangle, rect: sized(CGSize(width: 120, height: 80)), style: style)], to: page, actionName: "Rectangle")
        case .oval:
            add([AnnotationFactory.shape(.oval, rect: sized(CGSize(width: 120, height: 80)), style: style)], to: page, actionName: "Oval")
        case .textBox, .addText:
            let text = "Text"
            let size = AnnotationFactory.fittingSize(for: "Type here to add text", style: style)
            let frame = rect ?? CGRect(x: point.x, y: point.y - size.height, width: size.width, height: size.height)
            let annotation = AnnotationFactory.textBox(rect: frame, text: text, style: style, bordered: tool == .textBox)
            add([annotation], to: page, actionName: tool.title)
            beginEditing(annotation)
        case .stamp:
            let annotation: PDFAnnotation
            if !customStampText.trimmingCharacters(in: .whitespaces).isEmpty {
                annotation = AnnotationFactory.textStamp(customStampText, center: point, color: style.strokeColor)
            } else {
                annotation = AnnotationFactory.standardStamp(selectedStampName, center: point)
            }
            if let rect { annotation.bounds = rect }
            add([annotation], to: page, actionName: "Stamp")
        case .signature:
            guard let signature = signatureStore.signatures.first(where: { $0.id == selectedSignatureID }) ?? signatureStore.signatures.first else {
                sheet = .newSignature
                return
            }
            let frame = sized(signature.defaultSize)
            add(signature.annotations(in: frame), to: page, actionName: "Signature")
        case .addImage:
            guard let image = pendingImage ?? chooseImage() else { return }
            pendingImage = image
            let natural = image.size
            let scale = min(240 / max(natural.width, 1), 240 / max(natural.height, 1), 1)
            let frame = sized(CGSize(width: natural.width * scale, height: natural.height * scale))
            add([ImageOverlayAnnotation(image: image, bounds: frame)], to: page, actionName: "Add Image")
            pendingImage = nil
        case .link:
            sheet = .link(page: page, rect: sized(CGSize(width: 120, height: 20)))
        case .crop:
            guard let rect, rect.width > 20, rect.height > 20 else { return }
            cropPages(IndexSet(integer: document.index(for: page)), to: rect)
        case .redactArea:
            add([RedactionMark.make(bounds: sized(CGSize(width: 120, height: 24)))], to: page, actionName: "Mark for Redaction")
        default:
            guard let kind = tool.formFieldKind else { return }
            let name = FormFields.uniqueName(for: kind, in: document)
            let field = FormFields.make(kind, rect: sized(kind.defaultSize), name: name)
            add([field], to: page, actionName: "Add \(kind.title)")
            showsInspector = true
            inspectorTab = .properties
        }
    }

    func handleClick(at point: CGPoint, on page: PDFPage) {
        switch tool {
        case .eraser:
            if let annotation = page.annotation(at: point), !annotation.isSubtype(.widget) || mode == .forms {
                remove([annotation], actionName: "Erase")
            }
        case .note:
            let note = AnnotationFactory.note(at: point, text: "", color: style.highlightColor)
            add([note], to: page, actionName: "Note")
            beginEditing(note)
        case .editText:
            beginTextEdit(at: point, on: page)
        default:
            break
        }
    }

    /// Opens the inspector on an annotation so its text can be edited.
    func beginEditing(_ annotation: PDFAnnotation) {
        selectedAnnotation = annotation
        showsInspector = true
        inspectorTab = .properties
        tool = .select
        selectedAnnotation = annotation
    }

    func chooseImage() -> NSImage? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an image to place on the page"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return NSImage(contentsOf: url)
    }

    // MARK: Text editing

    func beginTextEdit(at point: CGPoint, on page: PDFPage) {
        if let existing = page.annotation(at: point) as? TextReplacementAnnotation {
            sheet = .textEdit(TextEditRequest(page: page, rect: existing.bounds, text: existing.text,
                                              font: existing.textFont, color: existing.textColor, existing: existing))
            return
        }
        // Prefer the user's text selection when the click is inside it.
        var selection: PDFSelection?
        if let current = pdfView?.currentSelection, current.pages.contains(page),
           current.bounds(for: page).insetBy(dx: -2, dy: -2).contains(point) {
            selection = current
        } else {
            selection = page.selectionForLine(at: point)
        }
        guard let selection, let text = selection.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            alertMessage = "Click on a line of text to edit it. For scanned pages, run OCR first."
            return
        }
        let rect = selection.bounds(for: page)
        var font = NSFont.systemFont(ofSize: max(rect.height * 0.8, 6))
        var color = NSColor.black
        if let attributed = selection.attributedString, attributed.length > 0 {
            if let found = attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont { font = found }
            if let found = attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor { color = found }
        }
        sheet = .textEdit(TextEditRequest(page: page, rect: rect, text: text.trimmingCharacters(in: .newlines),
                                          font: font, color: color, existing: nil))
    }

    func commitTextEdit(_ request: TextEditRequest, text: String, font: NSFont, color: NSColor, coverColor: NSColor) {
        if let existing = request.existing {
            modify(existing, actionName: "Edit Text") { annotation in
                guard let replacement = annotation as? TextReplacementAnnotation else { return }
                replacement.text = text
                replacement.textFont = font
                replacement.textColor = color
                replacement.coverColor = coverColor
            }
            return
        }
        let rect = request.rect.insetBy(dx: -1, dy: -1)
        let replacement = TextReplacementAnnotation(bounds: rect, text: text, font: font, textColor: color, coverColor: coverColor)
        add([replacement], to: request.page, actionName: "Edit Text")
    }

    /// Samples the page color just outside `rect`, to cover replaced text.
    func backgroundColor(around rect: CGRect, on page: PDFPage) -> NSColor {
        guard let image = PageRenderer.cgImage(for: page, dpi: 36, includeAnnotations: false),
              let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return .white }
        let display = PageGeometry.displayRect(for: rect, on: page)
        let scale = CGFloat(image.width) / max(PageGeometry.displaySize(of: page).width, 1)
        let x = Int((display.minX - 2) * scale)
        let y = image.height - 1 - Int(display.midY * scale)
        guard x >= 0, x < image.width, y >= 0, y < image.height else { return .white }
        let offset = y * image.bytesPerRow + x * (image.bitsPerPixel / 8)
        return NSColor(srgbRed: CGFloat(bytes[offset]) / 255, green: CGFloat(bytes[offset + 1]) / 255,
                       blue: CGFloat(bytes[offset + 2]) / 255, alpha: 1)
    }

    // MARK: Links

    func addLink(on page: PDFPage, rect: CGRect, url: URL?, pageIndex: Int?) {
        let annotation: PDFAnnotation
        if let url {
            annotation = AnnotationFactory.link(rect: rect, url: url)
        } else if let pageIndex, let target = document.page(at: pageIndex) {
            annotation = AnnotationFactory.link(rect: rect, to: target)
        } else {
            return
        }
        add([annotation], to: page, actionName: "Add Link")
    }

    // MARK: Redaction

    func markForRedaction(_ text: String, caseSensitive: Bool) -> Int {
        let occurrences = PageOperations.occurrences(of: text, in: document, caseSensitive: caseSensitive)
        var items: [(PDFPage, PDFAnnotation)] = []
        for (index, rects) in occurrences {
            guard let page = document.page(at: index) else { continue }
            for rect in rects { items.append((page, RedactionMark.make(bounds: rect))) }
        }
        addGrouped(items, actionName: "Mark for Redaction")
        return items.count
    }

    func applyRedactions(fillColor: NSColor = .black, restoreText: Bool = true) {
        let marks = PageOperations.redactionMarks(in: document)
        guard !marks.isEmpty else {
            alertMessage = "Mark text or areas for redaction first."
            return
        }
        var ocr: OCROptions?
        if restoreText { ocr = OCROptions() }
        let replaced = PageOperations.redact(document, marks: marks, fillColor: fillColor, ocr: ocr)
        registerPageReplacement("Apply Redactions", replaced: replaced)
    }

    // MARK: Forms

    func detectFormFields() {
        var items: [(PDFPage, PDFAnnotation)] = []
        for page in document.pages {
            let existing = page.annotations.filter { $0.isSubtype(.widget) }.map(\.bounds)
            for (kind, rect) in FormFields.detectFields(on: page) where !existing.contains(where: { $0.intersects(rect) }) {
                let field = FormFields.make(kind, rect: rect, name: FormFields.uniqueName(for: kind, in: document) + "-\(items.count + 1)")
                items.append((page, field))
            }
        }
        if items.isEmpty {
            alertMessage = "No blank lines or boxes were found to turn into fields."
        } else {
            addGrouped(items, actionName: "Detect Form Fields")
        }
    }

    func resetForm() {
        let before = FormFields.values(in: document)
        FormFields.reset(document)
        registerFormChange("Reset Form", before: before)
    }

    func importFormData() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let before = FormFields.values(in: document)
        do {
            try FormFields.importJSON(Data(contentsOf: url), into: document)
            registerFormChange("Import Form Data", before: before)
        } catch {
            report(error)
        }
    }

    func exportFormData(asCSV: Bool) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [asCSV ? .commaSeparatedText : .json]
        panel.nameFieldStringValue = documentTitle + " form data." + (asCSV ? "csv" : "json")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if asCSV {
                try FormFields.exportCSV(document).write(to: url, atomically: true, encoding: .utf8)
            } else {
                try FormFields.exportJSON(document).write(to: url)
            }
        } catch {
            report(error)
        }
    }

    private func registerFormChange(_ name: String, before: [String: String]) {
        for page in document.pages { pdfView?.annotationsChanged(on: page) }
        let after = FormFields.values(in: document)
        registerUndo(name) { controller in
            FormFields.apply(before, to: controller.document)
            controller.registerFormChange(name, before: after)
        }
    }

    /// Marks the document edited after the user typed into a form field.
    func formFieldWasEdited() {
        registerUndo("Fill Form") { _ in }
    }
}
