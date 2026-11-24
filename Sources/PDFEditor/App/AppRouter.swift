import AppKit
import PDFEditorCore
import SwiftUI

/// Something to do once a document tab has opened, e.g. after the user
/// picked a file from Home's AI or Tools buttons.
enum PendingDocumentAction {
    case showAssistant
    case tool(QuickTool)
}

/// App-wide navigation: the main window, Home and opening documents.
@MainActor
final class AppRouter {
    static let shared = AppRouter()

    var openWindow: OpenWindowAction?
    weak var mainWindow: NSWindow?

    /// Brings the main window forward, reopening it if it was closed.
    func showMainWindow() {
        if let mainWindow, mainWindow.isVisible || mainWindow.isMiniaturized {
            mainWindow.deminiaturize(nil)
            mainWindow.makeKeyAndOrderFront(nil)
        } else {
            openWindow?(id: WindowID.main)
        }
        NSApp.activate()
    }

    func showHome() {
        Workspace.shared.showHome()
        showMainWindow()
    }

    func openDocument(at url: URL, then action: PendingDocumentAction? = nil) {
        Workspace.shared.open(url, then: action)
    }

    func chooseAndOpen(message: String, then action: PendingDocumentAction?) {
        Workspace.shared.chooseAndOpen(message: message, then: action)
    }
}

/// One-click tools offered in the Tools panel and on Home.
enum QuickTool: String, CaseIterable, Identifiable {
    case insert, extract, replace, rotate, organize
    case ocr, compare, crop, split, watermark, background, headerFooter, bates, compress, protect, flatten, redact, slideshow
    case toImage, toWord, toExcel, toPowerPoint, toText, toRTF, toHTML, toMarkdown, toCSV, toODT, toImagePDF

    var id: String { rawValue }

    var title: String {
        switch self {
        case .insert: return "Insert"
        case .extract: return "Extract"
        case .replace: return "Replace"
        case .rotate: return "Rotate"
        case .organize: return "Organize"
        case .ocr: return "OCR"
        case .compare: return "Compare"
        case .crop: return "Crop"
        case .split: return "Split"
        case .watermark: return "Watermark"
        case .background: return "Background"
        case .headerFooter: return "Header & Footer"
        case .bates: return "Bates Numbering"
        case .compress: return "Compress"
        case .protect: return "Protect"
        case .flatten: return "Flatten"
        case .redact: return "Redact"
        case .slideshow: return "Slideshow"
        case .toImage: return "Image"
        case .toWord: return "Word"
        case .toExcel: return "Excel"
        case .toPowerPoint: return "PowerPoint"
        case .toText: return "Text"
        case .toRTF: return "RTF"
        case .toHTML: return "HTML"
        case .toMarkdown: return "Markdown"
        case .toCSV: return "CSV"
        case .toODT: return "OpenDocument"
        case .toImagePDF: return "Image PDF"
        }
    }

    var systemImage: String {
        switch self {
        case .insert: return "doc.badge.plus"
        case .extract: return "rectangle.portrait.and.arrow.right"
        case .replace: return "arrow.left.arrow.right.square"
        case .rotate: return "rotate.right"
        case .organize: return "square.grid.2x2"
        case .ocr: return "text.viewfinder"
        case .compare: return "doc.on.doc"
        case .crop: return "crop"
        case .split: return "scissors"
        case .watermark: return "drop.fill"
        case .background: return "paintpalette.fill"
        case .headerFooter: return "text.append"
        case .bates: return "number.square"
        case .compress: return "arrow.down.right.and.arrow.up.left"
        case .protect: return "lock.fill"
        case .flatten: return "square.3.layers.3d.down.right"
        case .redact: return "eye.slash.fill"
        case .slideshow: return "play.rectangle.fill"
        case .toImage: return "photo.fill"
        case .toWord: return "doc.richtext.fill"
        case .toExcel: return "tablecells.fill"
        case .toPowerPoint: return "rectangle.on.rectangle.angled.fill"
        case .toText: return "doc.plaintext.fill"
        case .toRTF: return "doc.text.fill"
        case .toHTML: return "globe"
        case .toMarkdown: return "number"
        case .toCSV: return "list.bullet.rectangle.fill"
        case .toODT: return "doc.fill"
        case .toImagePDF: return "doc.viewfinder.fill"
        }
    }

    var colors: [Color] {
        func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r / 255, green: g / 255, blue: b / 255) }
        switch self {
        case .insert, .organize: return [rgb(96, 165, 250), rgb(59, 91, 219)]
        case .extract: return [rgb(167, 139, 250), rgb(109, 74, 255)]
        case .replace: return [rgb(129, 140, 248), rgb(79, 70, 229)]
        case .rotate: return [rgb(125, 211, 252), rgb(14, 116, 144)]
        case .ocr: return [rgb(56, 189, 248), rgb(37, 99, 235)]
        case .compare: return [rgb(251, 146, 60), rgb(234, 88, 12)]
        case .crop: return [rgb(74, 222, 128), rgb(22, 163, 74)]
        case .split: return [rgb(250, 204, 21), rgb(217, 119, 6)]
        case .watermark: return [rgb(147, 197, 253), rgb(59, 130, 246)]
        case .background: return [rgb(244, 114, 182), rgb(190, 24, 93)]
        case .headerFooter: return [rgb(103, 232, 249), rgb(8, 145, 178)]
        case .bates: return [rgb(165, 180, 252), rgb(67, 56, 202)]
        case .compress: return [rgb(45, 212, 191), rgb(13, 148, 136)]
        case .protect: return [rgb(148, 163, 184), rgb(51, 65, 85)]
        case .flatten: return [rgb(196, 181, 253), rgb(124, 58, 237)]
        case .redact: return [rgb(82, 82, 91), rgb(24, 24, 27)]
        case .slideshow: return [rgb(251, 113, 133), rgb(225, 29, 72)]
        case .toImage: return [rgb(192, 132, 252), rgb(126, 34, 206)]
        case .toWord: return [rgb(96, 165, 250), rgb(29, 78, 216)]
        case .toExcel: return [rgb(74, 222, 128), rgb(21, 128, 61)]
        case .toPowerPoint: return [rgb(251, 146, 60), rgb(194, 65, 12)]
        case .toText, .toRTF, .toODT: return [rgb(156, 163, 175), rgb(75, 85, 99)]
        case .toHTML: return [rgb(56, 189, 248), rgb(2, 132, 199)]
        case .toMarkdown: return [rgb(100, 116, 139), rgb(30, 41, 59)]
        case .toCSV: return [rgb(52, 211, 153), rgb(5, 150, 105)]
        case .toImagePDF: return [rgb(248, 113, 113), rgb(185, 28, 28)]
        }
    }

    var conversionFormat: ConversionFormat? {
        switch self {
        case .toImage: return .image
        case .toWord: return .word
        case .toExcel: return .excel
        case .toPowerPoint: return .powerpoint
        case .toText: return .text
        case .toRTF: return .rtf
        case .toHTML: return .html
        case .toMarkdown: return .markdown
        case .toCSV: return .csv
        case .toODT: return .openDocument
        case .toImagePDF: return .pdfImageOnly
        default: return nil
        }
    }

    static let organizePrimary: [QuickTool] = [.insert, .extract, .replace, .rotate]
    static let editPrimary: [QuickTool] = [.ocr, .compare, .crop, .split, .watermark, .background, .headerFooter, .bates]
    static let editMore: [QuickTool] = [.compress, .protect, .flatten, .redact, .slideshow]
    static let convertPrimary: [QuickTool] = [.toImage, .toWord, .toExcel, .toPowerPoint]
    static let convertMore: [QuickTool] = [.toText, .toRTF, .toHTML, .toMarkdown, .toCSV, .toODT, .toImagePDF]
}

extension EditorController {
    /// Runs a tool from the Tools panel or a Home shortcut.
    func perform(_ tool: QuickTool) {
        showsToolsPanel = false
        if let format = tool.conversionFormat {
            convertPreset = format
            sheet = .convert
            return
        }
        switch tool {
        case .insert: insertFiles(at: currentPageIndex + 1)
        case .extract: extractPages(targetPages)
        case .replace: replacePages(targetPages)
        case .rotate: rotatePages(targetPages, by: 90)
        case .organize: mode = .pages
        case .ocr: sheet = .ocr
        case .compare:
            CompareRequest.original = fileURL
            AppRouter.shared.openWindow?(id: WindowID.compare)
        case .crop: sheet = .crop
        case .split: sheet = .split
        case .watermark: sheet = .watermark
        case .background: sheet = .background
        case .headerFooter:
            batesPreset = false
            sheet = .headerFooter
        case .bates:
            batesPreset = true
            sheet = .headerFooter
        case .compress: sheet = .compress
        case .protect: sheet = .security
        case .flatten: flatten(pages: PageRange.all(pageCount))
        case .redact: mode = .protect
        case .slideshow: startPresentation()
        default: break
        }
    }

    func perform(_ action: PendingDocumentAction) {
        switch action {
        case .showAssistant:
            inspectorTab = .assistant
            showsInspector = true
        case .tool(let tool):
            perform(tool)
        }
    }
}

/// Lets a document window pre-fill the Compare window with its file.
@MainActor
enum CompareRequest {
    static var original: URL?
}
