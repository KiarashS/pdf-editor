import AppKit
import PDFEditorCore
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct PDFEditorApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: { PDFFileDocument() }) { file in
            ContentView(document: file.document, fileURL: file.fileURL)
        }
        .commands { EditorCommands() }

        Window("Batch Processing", id: WindowID.batch) {
            BatchView()
        }
        .defaultSize(width: 760, height: 560)

        Window("Compare Documents", id: WindowID.compare) {
            CompareView()
        }
        .defaultSize(width: 1200, height: 800)

        Settings {
            SettingsView()
        }
    }
}

enum WindowID {
    static let batch = "batch"
    static let compare = "compare"
}

struct EditorControllerKey: FocusedValueKey {
    typealias Value = EditorController
}

extension FocusedValues {
    var editorController: EditorController? {
        get { self[EditorControllerKey.self] }
        set { self[EditorControllerKey.self] = newValue }
    }
}

/// Creates new documents from images, the clipboard or several files.
@MainActor
enum DocumentCreator {
    static func newFromImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.message = "Choose images. Each image becomes one page."
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        saveAndOpen(PDFConverter.pdf(fromImages: urls, paperSize: nil), suggestedName: "Images")
    }

    static func newFromClipboard() {
        let pasteboard = NSPasteboard.general
        if let data = pasteboard.data(forType: .pdf), let document = PDFDocument(data: data) {
            saveAndOpen(document, suggestedName: "Clipboard")
        } else if let image = NSImage(pasteboard: pasteboard), let page = PageCompositor.page(for: image, pageSize: nil) {
            let document = PDFDocument()
            document.insert(page, at: 0)
            saveAndOpen(document, suggestedName: "Clipboard")
        } else if let text = pasteboard.string(forType: .string), !text.isEmpty {
            let attributed = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12)])
            saveAndOpen(PDFConverter.pdf(fromAttributedString: attributed), suggestedName: "Clipboard")
        } else {
            NSSound.beep()
        }
    }

    static func combineFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .image, .rtf, .plainText]
        panel.allowsMultipleSelection = true
        panel.message = "Choose the files to combine, in order."
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let combined = PDFDocument()
        for url in panel.urls {
            let source: PDFDocument?
            if UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true {
                source = PDFConverter.pdf(fromImages: [url], paperSize: nil)
            } else if UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true {
                source = PDFDocument(url: url)
            } else {
                source = try? PDFConverter.pdf(fromTextFile: url)
            }
            guard let source, !source.isLocked else { continue }
            _ = combined.insertPages(from: source, at: combined.pageCount)
        }
        saveAndOpen(combined, suggestedName: "Combined")
    }

    static func newBlank(size: PaperSize) {
        let document = PDFDocument()
        if let page = PageCompositor.blankPage(size: size.size) { document.insert(page, at: 0) }
        saveAndOpen(document, suggestedName: "Untitled")
    }

    static func saveAndOpen(_ document: PDFDocument, suggestedName: String) {
        guard document.pageCount > 0 else {
            NSSound.beep()
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = suggestedName + ".pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard document.write(to: url) else {
            NSAlert(error: ExportError.serializationFailed).runModal()
            return
        }
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            guard let error else { return }
            Task { @MainActor in NSAlert(error: error).runModal() }
        }
    }
}

struct EditorCommands: Commands {
    @FocusedValue(\.editorController) private var controller
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Menu("New From") {
                Button("Images…") { DocumentCreator.newFromImages() }
                Button("Clipboard") { DocumentCreator.newFromClipboard() }
                    .keyboardShortcut("n", modifiers: [.command, .option])
                Divider()
                ForEach([PaperSize.letter, .a4, .legal], id: \.self) { size in
                    Button("Blank \(size.title)") { DocumentCreator.newBlank(size: size) }
                }
            }
            Button("Combine Files…") { DocumentCreator.combineFiles() }
        }

        CommandGroup(replacing: .printItem) {
            Button("Print…") { controller?.printDocument() }
                .keyboardShortcut("p")
                .disabled(controller == nil)
        }

        CommandGroup(after: .saveItem) {
            Button("Export…") { controller?.sheet = .convert }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(controller == nil)
            Button("Save Flattened Copy…") { controller?.saveFlattenedCopy() }
                .disabled(controller == nil)
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Duplicate Annotation") { controller?.duplicateSelectedAnnotation() }
                .keyboardShortcut("d")
                .disabled(controller?.selectedAnnotation == nil)
            Button("Find…") {
                controller?.sidebarTab = .search
            }
            .keyboardShortcut("f")
            .disabled(controller == nil)
            Button("Find Next") { controller?.nextSearchResult() }
                .keyboardShortcut("g")
                .disabled(controller?.searchResults.isEmpty ?? true)
            Button("Find Previous") { controller?.previousSearchResult() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(controller?.searchResults.isEmpty ?? true)
        }

        CommandGroup(after: .toolbar) {
            Divider()
            Button("Zoom In") { controller?.zoomIn() }.keyboardShortcut("+")
            Button("Zoom Out") { controller?.zoomOut() }.keyboardShortcut("-")
            Button("Actual Size") { controller?.zoom(toPercent: 100) }.keyboardShortcut("0")
            Button("Fit Page") { controller?.zoomToFit() }.keyboardShortcut("9")
            Button("Fit Width") { controller?.zoomToFitWidth() }.keyboardShortcut("8")
            Divider()
            Button("Single Page") { controller?.displayMode = .singlePage }
            Button("Continuous") { controller?.displayMode = .singlePageContinuous }
            Button("Two Pages") { controller?.displayMode = .twoUp }
            Button("Two Pages Continuous") { controller?.displayMode = .twoUpContinuous }
            Divider()
            Menu("Reading Theme") {
                ForEach(ReadingTheme.allCases) { theme in
                    Button(theme.title) { controller?.readingTheme = theme }
                }
            }
            Button("Slideshow") { controller?.startPresentation() }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
            Button("Read Aloud") { controller?.toggleReadAloud() }
        }

        CommandMenu("Go") {
            Button("Next Page") { controller?.nextPage() }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button("Previous Page") { controller?.previousPage() }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("First Page") { controller?.go(toPage: 0) }
                .keyboardShortcut(.upArrow, modifiers: [.command])
            Button("Last Page") { controller.map { $0.go(toPage: $0.pageCount - 1) } }
                .keyboardShortcut(.downArrow, modifiers: [.command])
            Divider()
            Button("Add Bookmark") { controller?.addBookmark() }
                .keyboardShortcut("b", modifiers: [.command, .shift])
        }

        CommandMenu("Tools") {
            ForEach(Array(EditorMode.allCases.enumerated()), id: \.element) { offset, mode in
                Button(mode.title) { controller?.mode = mode }
                    .keyboardShortcut(KeyEquivalent(Character("\(offset + 1)")), modifiers: [.command])
                    .disabled(controller == nil)
            }
            Divider()
            Group {
                Button("Recognize Text (OCR)…") { controller?.sheet = .ocr }
                Button("Compress…") { controller?.sheet = .compress }
                Button("Convert…") { controller?.sheet = .convert }
                Divider()
                Button("Watermark…") { controller?.sheet = .watermark }
                Button("Header & Footer…") { controller?.sheet = .headerFooter }
                Button("Background…") { controller?.sheet = .background }
                Button("Crop Pages…") { controller?.sheet = .crop }
                Button("Split Document…") { controller?.sheet = .split }
                Divider()
                Button("Password & Permissions…") { controller?.sheet = .security }
                Button("Flatten Annotations") { controller.map { $0.flatten(pages: PageRange.all($0.pageCount)) } }
            }
            .disabled(controller == nil)
            Divider()
            Button("Batch Processing…") { openWindow(id: WindowID.batch) }
            Button("Compare Documents…") { openWindow(id: WindowID.compare) }
        }
    }
}
