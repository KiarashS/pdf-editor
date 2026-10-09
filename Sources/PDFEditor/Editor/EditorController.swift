import AppKit
import AVFoundation
import Observation
import PDFEditorCore
import PDFKit
import SwiftUI

/// Sheets presented over the editor window.
enum EditorSheet: Identifiable {
    case watermark, headerFooter, background, security, compress, convert, ocr, crop, split, insertBlank
    case link(page: PDFPage, rect: CGRect)
    case textEdit(TextEditRequest)
    case newSignature
    case redactSearch
    case measureSettings

    var id: String {
        switch self {
        case .watermark: return "watermark"
        case .headerFooter: return "headerFooter"
        case .background: return "background"
        case .security: return "security"
        case .compress: return "compress"
        case .convert: return "convert"
        case .ocr: return "ocr"
        case .crop: return "crop"
        case .split: return "split"
        case .insertBlank: return "insertBlank"
        case .link: return "link"
        case .textEdit: return "textEdit"
        case .newSignature: return "newSignature"
        case .redactSearch: return "redactSearch"
        case .measureSettings: return "measureSettings"
        }
    }
}

/// Text the user clicked with the Edit Text tool.
struct TextEditRequest {
    let page: PDFPage
    let rect: CGRect
    let text: String
    let font: NSFont
    let color: NSColor
    /// Set when editing an existing replacement instead of page text.
    let existing: TextReplacementAnnotation?
}

struct ProgressState: Equatable {
    var title: String
    var fraction: Double?
}

/// Owns the editing state of one document window and performs every
/// change, registering undo for each.
@MainActor
@Observable
final class EditorController {
    @ObservationIgnored let fileDocument: PDFFileDocument
    @ObservationIgnored private(set) var pdfView: EditorPDFView?
    @ObservationIgnored var undoManager: UndoManager?
    @ObservationIgnored let signatureStore = SignatureStore()
    @ObservationIgnored private let speech = AVSpeechSynthesizer()
    /// AI chat for this document; kept here so it survives inspector tab changes.
    @ObservationIgnored let assistant = AssistantModel()

    var document: PDFDocument { fileDocument.pdf }
    var fileURL: URL?

    // View state
    var mode: EditorMode = .read {
        didSet {
            guard oldValue != mode else { return }
            tool = mode.tools.first ?? .select
            selectedAnnotation = nil
            if mode == .pages { organizerSelection = [currentPageIndex] }
        }
    }
    var tool: Tool = .select {
        didSet {
            pdfView?.toolDidChange()
            if tool != .select { selectedAnnotation = nil }
        }
    }
    var style = AnnotationStyle()
    var selectedAnnotation: PDFAnnotation? {
        didSet {
            pdfView?.overlay.needsDisplay = true
            if selectedAnnotation != nil, inspectorTab == .assistant { inspectorTab = .properties }
        }
    }
    var showsInspector = false
    var inspectorTab: InspectorTab = .properties
    var sidebarTab: SidebarTab = .thumbnails
    var sheet: EditorSheet?
    var alertMessage: String?
    var progress: ProgressState?
    var canvasGeneration = 0
    /// Incremented whenever pages or annotations change.
    var revision = 0
    var currentPageIndex = 0
    var pageCount = 0
    var isLocked = false
    var zoomPercent = 100
    var displayMode: PDFDisplayMode = .singlePageContinuous {
        didSet { pdfView?.displayMode = displayMode }
    }
    var displaysAsBook = false {
        didSet { pdfView?.displaysAsBook = displaysAsBook }
    }
    var readingTheme: ReadingTheme = .normal {
        didSet { pdfView?.apply(theme: readingTheme) }
    }
    var organizerSelection: Set<Int> = []
    var organizerThumbnailSize: CGFloat = 150
    var selectedStampName = "Approved"
    var customStampText = ""
    var selectedSignatureID: UUID?
    var signaturesRevision = 0
    var measureUnit: AnnotationFactory.MeasureUnit = .millimeters
    var measureScale: CGFloat = 1
    var isSpeaking = false

    // Search
    var searchText = ""
    var searchCaseSensitive = false
    var searchResults: [PDFSelection] = []
    var searchIndex = 0

    /// Image chosen for the Add Image tool, placed on the next click or drag.
    @ObservationIgnored var pendingImage: NSImage?

    init(fileDocument: PDFFileDocument, fileURL: URL?) {
        self.fileDocument = fileDocument
        self.fileURL = fileURL
        pageCount = fileDocument.pdf.pageCount
        isLocked = fileDocument.pdf.isLocked
        AnnotationFactory.authorName = UserDefaults.standard.string(forKey: SettingsKeys.authorName) ?? NSFullUserName()
    }

    var documentTitle: String {
        if let title = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, !title.isEmpty { return title }
        return fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
    }

    var currentPage: PDFPage? { document.page(at: currentPageIndex) }

    // MARK: Canvas

    func attach(_ view: EditorPDFView) {
        pdfView = view
        view.displayMode = displayMode
        view.displaysAsBook = displaysAsBook
        view.apply(theme: readingTheme)
        canvasGeneration += 1
    }

    /// Called by the canvas when the visible page or zoom changes.
    func canvasDidScroll() {
        guard let view = pdfView, let page = view.currentPage else { return }
        let index = document.index(for: page)
        if index != NSNotFound, index != currentPageIndex { currentPageIndex = index }
        let percent = Int((view.scaleFactor * 100).rounded())
        if percent != zoomPercent { zoomPercent = percent }
    }

    func documentChanged() {
        revision += 1
        pageCount = document.pageCount
        if currentPageIndex >= pageCount { currentPageIndex = max(pageCount - 1, 0) }
        organizerSelection = organizerSelection.filter { $0 < pageCount }
        if let annotation = selectedAnnotation, annotation.page == nil || annotation.page?.document !== document {
            selectedAnnotation = nil
        }
        pdfView?.layoutDocumentView()
        pdfView?.overlay.needsDisplay = true
    }

    func refresh(_ annotation: PDFAnnotation) {
        if let page = annotation.page { pdfView?.annotationsChanged(on: page) }
        pdfView?.overlay.needsDisplay = true
        revision += 1
    }

    // MARK: Undo

    /// Registers `undo` and marks the document as edited.
    func registerUndo(_ name: String, _ undo: @escaping (EditorController) -> Void) {
        if let undoManager {
            undoManager.registerUndo(withTarget: self) { target in
                MainActor.assumeIsolated { undo(target) }
            }
            undoManager.setActionName(name)
        }
        documentChanged()
    }

    // MARK: Navigation

    func go(toPage index: Int) {
        guard let page = document.page(at: index) else { return }
        currentPageIndex = index
        pdfView?.go(to: page)
    }

    func go(to annotation: PDFAnnotation) {
        guard let page = annotation.page else { return }
        pdfView?.go(to: annotation.bounds.insetBy(dx: -40, dy: -40), on: page)
        selectedAnnotation = annotation
    }

    func nextPage() { go(toPage: min(currentPageIndex + 1, pageCount - 1)) }
    func previousPage() { go(toPage: max(currentPageIndex - 1, 0)) }

    func zoomIn() { pdfView?.zoomIn(nil); canvasDidScroll() }
    func zoomOut() { pdfView?.zoomOut(nil); canvasDidScroll() }

    func zoom(toPercent percent: Int) {
        guard let view = pdfView else { return }
        view.autoScales = false
        view.scaleFactor = CGFloat(percent) / 100
        canvasDidScroll()
    }

    func zoomToFit() {
        guard let view = pdfView else { return }
        view.autoScales = true
        canvasDidScroll()
    }

    func zoomToFitWidth() {
        guard let view = pdfView, let page = currentPage else { return }
        let width = PageGeometry.displaySize(of: page).width
        let available = view.bounds.width - 40
        view.autoScales = false
        view.scaleFactor = max(available / max(width, 1), 0.1)
        canvasDidScroll()
    }

    // MARK: Locking

    func unlock(password: String) -> Bool {
        guard document.unlock(withPassword: password) else { return false }
        isLocked = false
        // Keep the file encrypted with the same password when it is saved.
        if document.isEncrypted {
            fileDocument.exportOptions.security.openPassword = password
        }
        documentChanged()
        return true
    }

    // MARK: Errors and progress

    func report(_ error: Error) {
        alertMessage = error.localizedDescription
    }

    func run(_ title: String, _ work: () throws -> Void) {
        do { try work() } catch { report(error) }
    }

    // MARK: Search

    func search() {
        clearSearchHighlights()
        let text = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            searchResults = []
            return
        }
        let options: NSString.CompareOptions = searchCaseSensitive ? [] : [.caseInsensitive]
        searchResults = document.findString(text, withOptions: options)
        for selection in searchResults { selection.color = NSColor.systemYellow.withAlphaComponent(0.6) }
        pdfView?.highlightedSelections = searchResults
        searchIndex = 0
        if !searchResults.isEmpty { showSearchResult(0) }
    }

    func showSearchResult(_ index: Int) {
        guard searchResults.indices.contains(index) else { return }
        searchIndex = index
        let selection = searchResults[index]
        pdfView?.setCurrentSelection(selection, animate: true)
        pdfView?.go(to: selection)
        if let page = selection.pages.first {
            let pageIndex = document.index(for: page)
            if pageIndex != NSNotFound { currentPageIndex = pageIndex }
        }
    }

    func nextSearchResult() {
        guard !searchResults.isEmpty else { return }
        showSearchResult((searchIndex + 1) % searchResults.count)
    }

    func previousSearchResult() {
        guard !searchResults.isEmpty else { return }
        showSearchResult((searchIndex - 1 + searchResults.count) % searchResults.count)
    }

    func clearSearchHighlights() {
        pdfView?.highlightedSelections = nil
    }

    // MARK: Bookmarks (outline)

    func addBookmark(title: String? = nil) {
        guard let page = currentPage else { return }
        let root: PDFOutline
        if let existing = document.outlineRoot {
            root = existing
        } else {
            root = PDFOutline()
            document.outlineRoot = root
        }
        let item = PDFOutline()
        item.label = title ?? "Page \(currentPageIndex + 1)"
        let top = page.bounds(for: .cropBox).maxY
        item.destination = PDFDestination(page: page, at: CGPoint(x: 0, y: top))
        let index = root.numberOfChildren
        root.insertChild(item, at: index)
        registerUndo("Add Bookmark") { controller in controller.removeBookmark(item) }
    }

    func removeBookmark(_ item: PDFOutline) {
        guard let parent = item.parent else { return }
        let index = item.index
        item.removeFromParent()
        registerUndo("Remove Bookmark") { controller in
            parent.insertChild(item, at: min(index, parent.numberOfChildren))
            controller.registerUndo("Remove Bookmark") { $0.removeBookmark(item) }
        }
    }

    func renameBookmark(_ item: PDFOutline, to title: String) {
        let old = item.label ?? ""
        guard old != title else { return }
        item.label = title
        registerUndo("Rename Bookmark") { $0.renameBookmark(item, to: old) }
    }

    func go(to outline: PDFOutline) {
        if let destination = outline.destination {
            pdfView?.go(to: destination)
        } else if let action = outline.action as? PDFActionGoTo {
            pdfView?.go(to: action.destination)
        } else if let action = outline.action {
            pdfView?.perform(action)
        }
        canvasDidScroll()
    }

    // MARK: Metadata and security

    func updateMetadata(_ metadata: DocumentMetadata) {
        let old = DocumentMetadata(document: document)
        guard old != metadata else { return }
        metadata.apply(to: document)
        registerUndo("Edit Properties") { $0.updateMetadata(old) }
    }

    func setSecurity(_ settings: SecuritySettings) {
        let old = fileDocument.exportOptions.security
        fileDocument.exportOptions.security = settings
        registerUndo(settings.isEncrypted ? "Set Password" : "Remove Password") { $0.setSecurity(old) }
    }

    var security: SecuritySettings { fileDocument.exportOptions.security }

    // MARK: Read aloud

    func toggleReadAloud() {
        if speech.isSpeaking {
            speech.stopSpeaking(at: .immediate)
            isSpeaking = false
            return
        }
        let text: String
        if let selection = pdfView?.currentSelection?.string, !selection.isEmpty {
            text = selection
        } else {
            text = currentPage?.string ?? ""
        }
        guard !text.isEmpty else { return }
        speech.speak(AVSpeechUtterance(string: text))
        isSpeaking = true
    }

    // MARK: Printing and presentation

    func printDocument() {
        guard let window = pdfView?.window else { return }
        // Print what the saved file would contain, including burned-in overlays.
        let target: PDFDocument
        if let data = try? DocumentExporter.export(document), let copy = PDFDocument(data: data) {
            target = copy
        } else {
            target = document
        }
        guard let operation = target.printOperation(for: NSPrintInfo.shared, scalingMode: .pageScaleToFit, autoRotate: true) else { return }
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    func startPresentation() {
        guard let data = try? DocumentExporter.export(document), let copy = PDFDocument(data: data) else { return }
        PresentationController.present(copy, startingAt: currentPageIndex)
    }

    /// Writes the current state to a temporary file and returns its URL, for sharing.
    func temporaryExport() -> URL? {
        guard let data = try? DocumentExporter.export(document, options: fileDocument.exportOptions) else { return nil }
        let name = (fileURL?.deletingPathExtension().lastPathComponent ?? "Document") + ".pdf"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        do {
            try data.write(to: url)
            return url
        } catch {
            report(error)
            return nil
        }
    }
}
