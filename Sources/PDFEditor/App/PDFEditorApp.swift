import AppKit
import PDFEditorCore
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct KPDFApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // One main window, like UPDF: Home and the open PDFs as tabs.
        Window("KPDF", id: WindowID.main) {
            WorkspaceView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 840)
        .defaultLaunchBehavior(.presented)
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
    static let main = "main"
    static let batch = "batch"
    static let compare = "compare"
}

/// Opens files from Finder into tabs, reopens the main window from the Dock,
/// and asks about unsaved changes before quitting.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    override init() {
        LegacyDataMigration.run()
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Tabs are drawn by KPDF itself.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { Workspace.shared.open(url) }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { AppRouter.shared.showMainWindow() }
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Workspace.shared.confirmCloseAll() ? .terminateNow : .terminateCancel
    }
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

    /// Opens the new PDF as an unsaved tab; ⌘S asks where to save it.
    static func saveAndOpen(_ document: PDFDocument, suggestedName: String) {
        Workspace.shared.openUntitled(document, name: suggestedName)
    }
}

struct EditorCommands: Commands {
    @FocusedValue(\.editorController) private var controller
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Blank PDF") { DocumentCreator.newBlank(size: .letter) }
                .keyboardShortcut("n")
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
            Divider()
            Button("Open…") { Workspace.shared.presentOpenPanel() }
                .keyboardShortcut("o")
            OpenRecentMenu()
            Divider()
            Button("Home") { AppRouter.shared.showHome() }
                .keyboardShortcut("h", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .saveItem) {
            Button("Close Tab") { Workspace.shared.closeFromMenu() }
                .keyboardShortcut("w")
            Divider()
            Button("Save") { controller.map { Workspace.shared.save($0) } }
                .keyboardShortcut("s")
                .disabled(controller == nil)
            Button("Save As…") { controller.map { Workspace.shared.saveAs($0) } }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(controller == nil)
        }

        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { Workspace.shared.undo() }
                .keyboardShortcut("z")
            Button("Redo") { Workspace.shared.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }

        CommandGroup(before: .windowList) {
            Button("Show Next Tab") { Workspace.shared.selectNext() }
                .keyboardShortcut(.tab, modifiers: [.control])
            Button("Show Previous Tab") { Workspace.shared.selectPrevious() }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
            Divider()
        }

        CommandGroup(replacing: .printItem) {
            Button("Print…") { controller?.printDocument() }
                .keyboardShortcut("p")
                .disabled(controller == nil)
        }

        CommandGroup(after: .saveItem) {
            Button("Export…") {
                controller?.convertPreset = nil
                controller?.sheet = .convert
            }
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

/// Carries settings and the data folder over from builds named "PDF Editor"
/// (bundle ID com.pdfeditor.app, folder Application Support/PDFEditor).
enum LegacyDataMigration {
    private static let doneKey = "migration.fromPDFEditor"

    static func run() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        for domain in ["com.pdfeditor.app", "PDFEditor"] {
            for (key, value) in defaults.persistentDomain(forName: domain) ?? [:] where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let old = support.appendingPathComponent("PDFEditor", isDirectory: true)
        let new = support.appendingPathComponent("KPDF", isDirectory: true)
        if FileManager.default.fileExists(atPath: old.path), !FileManager.default.fileExists(atPath: new.path) {
            try? FileManager.default.moveItem(at: old, to: new)
        }
        defaults.set(true, forKey: doneKey)
    }
}

/// File > Open Recent, from the Home library.
@MainActor
struct OpenRecentMenu: View {
    @State private var library = LibraryStore.shared

    var body: some View {
        Menu("Open Recent") {
            ForEach(library.recents.prefix(15)) { item in
                Button(item.title) { library.open(item) }
            }
            if !library.recents.isEmpty {
                Divider()
                Button("Clear Menu") { library.clearRecents() }
            }
        }
    }
}
