import AppKit
import Observation
import PDFEditorCore
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// The open documents of the main window. Home is shown when no tab is selected.
@MainActor
@Observable
final class Workspace {
    static let shared = Workspace()

    private(set) var documents: [EditorController] = []
    var selectedID: UUID?

    var selected: EditorController? {
        documents.first { $0.id == selectedID }
    }

    var isShowingHome: Bool { selected == nil }

    func showHome() {
        selectedID = nil
    }

    func select(_ document: EditorController) {
        selectedID = document.id
    }

    // MARK: Opening

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.message = "Choose PDFs to open"
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach { open($0) }
    }

    /// Opens `url` in a tab (or selects its existing tab) and then performs `action`.
    func open(_ url: URL, then action: PendingDocumentAction? = nil) {
        let target = url.standardizedFileURL
        if let existing = documents.first(where: { $0.fileURL?.standardizedFileURL == target }) {
            select(existing)
            if let action { existing.perform(action) }
            AppRouter.shared.showMainWindow()
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            alert("“\(url.lastPathComponent)” could not be opened.", detail: "The file may have been moved, or KPDF may not have permission to read it.")
            return
        }
        guard let file = PDFFileDocument(data: data) else {
            alert("“\(url.lastPathComponent)” is not a PDF KPDF can read.", detail: "The file may be damaged.")
            return
        }
        let controller = EditorController(fileDocument: file, fileURL: url)
        add(controller)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        LibraryStore.shared.noteOpened(url, pageCount: controller.pageCount)
        if let action { perform(action, on: controller) }
    }

    /// Opens an in-memory PDF as an unsaved tab.
    func openUntitled(_ pdf: PDFDocument, name: String) {
        guard pdf.pageCount > 0 else {
            NSSound.beep()
            return
        }
        let controller = EditorController(fileDocument: PDFFileDocument(pdf: pdf, data: nil), fileURL: nil)
        controller.untitledName = name
        // A new document has unsaved content from the start.
        controller.changeCount = 1
        add(controller)
    }

    func chooseAndOpen(message: String, then action: PendingDocumentAction?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.message = message
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url, then: action)
    }

    private func add(_ controller: EditorController) {
        controller.undoManager = UndoManager()
        documents.append(controller)
        select(controller)
        AppRouter.shared.showMainWindow()
    }

    private func perform(_ action: PendingDocumentAction, on controller: EditorController) {
        // Give the tab a moment to build its views before showing sheets.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated { controller.perform(action) }
        }
    }

    // MARK: Tabs

    func selectNext() {
        moveSelection(by: 1)
    }

    func selectPrevious() {
        moveSelection(by: -1)
    }

    private func moveSelection(by offset: Int) {
        // Home counts as position 0, documents follow.
        let count = documents.count + 1
        let current = selected.flatMap { document in documents.firstIndex { $0 === document } }.map { $0 + 1 } ?? 0
        let next = ((current + offset) % count + count) % count
        selectedID = next == 0 ? nil : documents[next - 1].id
    }

    func move(_ document: EditorController, to index: Int) {
        guard let from = documents.firstIndex(where: { $0 === document }) else { return }
        documents.remove(at: from)
        documents.insert(document, at: min(max(index, 0), documents.count))
    }

    /// Closes a tab, asking about unsaved changes. Returns false if the user cancelled.
    @discardableResult
    func close(_ document: EditorController) -> Bool {
        guard confirmClose(document) else { return false }
        guard let index = documents.firstIndex(where: { $0 === document }) else { return true }
        document.prepareForClose()
        documents.remove(at: index)
        if selectedID == document.id {
            if documents.isEmpty {
                selectedID = nil
            } else {
                selectedID = documents[min(index, documents.count - 1)].id
            }
        }
        return true
    }

    func closeOthers(than document: EditorController) {
        for other in documents where other !== document {
            guard close(other) else { return }
        }
    }

    /// ⌘W: closes the key window if it isn't the main window, else the current tab.
    func closeFromMenu() {
        if let key = NSApp.keyWindow, key !== AppRouter.shared.mainWindow {
            key.performClose(nil)
        } else if let selected {
            close(selected)
        } else {
            AppRouter.shared.mainWindow?.performClose(nil)
        }
    }

    /// Asks to save every edited document, for quitting. Returns false to cancel.
    func confirmCloseAll() -> Bool {
        for document in documents where document.isEdited {
            select(document)
            guard confirmClose(document) else { return false }
        }
        return true
    }

    private func confirmClose(_ document: EditorController) -> Bool {
        guard document.isEdited else { return true }
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes made to “\(document.documentTitle)”?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save(document)
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    // MARK: Saving

    /// Saves to the document's file, or asks for one. Returns false if nothing was saved.
    @discardableResult
    func save(_ document: EditorController) -> Bool {
        if let url = document.fileURL {
            return write(document, to: url)
        }
        return saveAs(document)
    }

    @discardableResult
    func saveAs(_ document: EditorController) -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = document.documentTitle + ".pdf"
        if let directory = document.fileURL?.deletingLastPathComponent() { panel.directoryURL = directory }
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return write(document, to: url)
    }

    private func write(_ document: EditorController, to url: URL) -> Bool {
        do {
            try document.save(to: url)
            return true
        } catch {
            alert("The document could not be saved.", detail: error.localizedDescription)
            return false
        }
    }

    // MARK: Undo

    /// Undo goes to a text field being edited, otherwise to the current document.
    func undo() {
        if NSApp.keyWindow?.firstResponder is NSText || NSApp.keyWindow !== AppRouter.shared.mainWindow {
            NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
        } else if let selected, selected.undoManager?.canUndo == true {
            selected.undoManager?.undo()
        }
    }

    func redo() {
        if NSApp.keyWindow?.firstResponder is NSText || NSApp.keyWindow !== AppRouter.shared.mainWindow {
            NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
        } else if let selected, selected.undoManager?.canRedo == true {
            selected.undoManager?.redo()
        }
    }

    private func alert(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }
}

extension EditorController: Identifiable {
    var isEdited: Bool { changeCount != savedChangeCount }

    /// Writes the document as it would be saved (overlays burned in,
    /// password applied) and marks it clean.
    func save(to url: URL) throws {
        let data = try fileDocument.snapshot(contentType: .pdf)
        try data.write(to: url, options: .atomic)
        fileURL = url
        savedChangeCount = changeCount
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        LibraryStore.shared.noteOpened(url, pageCount: pageCount)
        LibraryStore.shared.recordPosition(of: url, page: currentPageIndex, pageCount: pageCount)
    }

    func prepareForClose() {
        assistant.stop()
        if isSpeaking { toggleReadAloud() }
        if let fileURL { LibraryStore.shared.recordPosition(of: fileURL, page: currentPageIndex, pageCount: pageCount) }
    }
}
