import AppKit
import PDFKit

/// Full-screen slideshow of a document.
@MainActor
enum PresentationController {
    private static var windows: [PresentationWindow] = []

    static func present(_ document: PDFDocument, startingAt index: Int) {
        guard let screen = NSScreen.main else { return }
        let window = PresentationWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false

        let view = SlideView(frame: screen.frame)
        view.document = document
        view.displayMode = .singlePage
        view.displaysPageBreaks = false
        view.autoScales = true
        view.backgroundColor = .black
        view.pageShadowsEnabled = false
        if let page = document.page(at: index) { view.go(to: page) }
        window.contentView = view
        window.onClose = { closed in windows.removeAll { $0 === closed } }
        windows.append(window)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSCursor.setHiddenUntilMouseMoves(true)
    }
}

final class PresentationWindow: NSWindow {
    var onClose: ((PresentationWindow) -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        close()
    }

    override func close() {
        super.close()
        onClose?(self)
        onClose = nil
    }
}

/// Single-page PDF view driven by the keyboard and clicks.
final class SlideView: PDFView {
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 124, 125, 49, 121, 36: // right, down, space, page down, return
            if canGoToNextPage { goToNextPage(nil) }
        case 123, 126, 116, 51: // left, up, page up, delete
            if canGoToPreviousPage { goToPreviousPage(nil) }
        case 115: // home
            goToFirstPage(nil)
        case 119: // end
            goToLastPage(nil)
        case 53: // escape
            window?.close()
        default:
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if canGoToNextPage { goToNextPage(nil) }
    }

    override func rightMouseDown(with event: NSEvent) {
        if canGoToPreviousPage { goToPreviousPage(nil) }
    }
}
