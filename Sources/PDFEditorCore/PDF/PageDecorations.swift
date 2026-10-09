import AppKit
import PDFKit

/// Text or image watermark settings.
public struct WatermarkOptions: Equatable {
    public enum Content: Equatable {
        case text(String)
        case image(NSImage)
    }

    public var content: Content = .text("CONFIDENTIAL")
    public var fontName: String = "Helvetica-Bold"
    public var fontSize: CGFloat = 60
    public var color: NSColor = .systemRed
    public var opacity: CGFloat = 0.25
    /// Counter-clockwise rotation in degrees, as seen by the reader.
    public var rotation: CGFloat = 45
    public var anchor: PageGeometry.Anchor = .center
    /// Repeat the watermark across the page.
    public var tiled: Bool = false
    public var tileSpacing: CGFloat = 80
    /// Image width relative to the page width (0...1).
    public var imageScale: CGFloat = 0.5
    /// Draw beneath the page content instead of on top.
    public var behindContent: Bool = false

    public init() {}
}

/// Header, footer and Bates numbering settings. Text fields support the
/// tokens `{page}`, `{pages}`, `{date}`, `{bates}`, `{filename}` and `{title}`.
public struct HeaderFooterOptions: Equatable {
    public var headerLeft = ""
    public var headerCenter = ""
    public var headerRight = ""
    public var footerLeft = ""
    public var footerCenter = "Page {page} of {pages}"
    public var footerRight = ""
    public var fontName = "Helvetica"
    public var fontSize: CGFloat = 10
    public var color: NSColor = .black
    public var verticalMargin: CGFloat = 24
    public var horizontalMargin: CGFloat = 36
    /// Number used for the first page in the range.
    public var startNumber = 1
    public var dateFormat = "yyyy-MM-dd"
    public var batesPrefix = ""
    public var batesSuffix = ""
    public var batesStart = 1
    public var batesDigits = 6
    public var fileName = ""
    public var title = ""

    public init() {}

    public var isEmpty: Bool {
        [headerLeft, headerCenter, headerRight, footerLeft, footerCenter, footerRight]
            .allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Expands tokens for the `ordinal`-th page in the range (0-based).
    public func expand(_ template: String, ordinal: Int, totalPages: Int, date: Date = Date()) -> String {
        guard template.contains("{") else { return template }
        let formatter = DateFormatter()
        formatter.dateFormat = dateFormat
        let bates = batesPrefix + String(format: "%0\(max(batesDigits, 1))d", batesStart + ordinal) + batesSuffix
        return template
            .replacingOccurrences(of: "{page}", with: String(startNumber + ordinal))
            .replacingOccurrences(of: "{pages}", with: String(totalPages))
            .replacingOccurrences(of: "{date}", with: formatter.string(from: date))
            .replacingOccurrences(of: "{bates}", with: bates)
            .replacingOccurrences(of: "{filename}", with: fileName)
            .replacingOccurrences(of: "{title}", with: title)
    }
}

/// Page background settings.
public struct BackgroundOptions: Equatable {
    public var color: NSColor = NSColor(calibratedRed: 1, green: 0.98, blue: 0.9, alpha: 1)
    public var image: NSImage?
    public var opacity: CGFloat = 1
    /// Image scale relative to the page; 1 fills the page (aspect fill).
    public var imageFillsPage = true

    public init() {}
}

/// Burns watermarks, headers/footers and backgrounds into page content.
public enum PageDecorator {
    /// Applies `transform` to each page in `indexes`, replacing pages in place.
    /// Returns the replaced pages keyed by index so the change can be undone.
    @discardableResult
    public static func replacePages(in document: PDFDocument,
                                    indexes: IndexSet,
                                    transform: (_ page: PDFPage, _ ordinal: Int) -> PDFPage?) -> [Int: PDFPage] {
        var replaced: [Int: PDFPage] = [:]
        for (ordinal, index) in indexes.enumerated() {
            guard let page = document.page(at: index), let newPage = transform(page, ordinal) else { continue }
            if let old = document.replacePage(at: index, with: newPage) {
                replaced[index] = old
            }
        }
        return replaced
    }

    @discardableResult
    public static func applyWatermark(_ options: WatermarkOptions, to document: PDFDocument, pages: IndexSet) -> [Int: PDFPage] {
        replacePages(in: document, indexes: pages) { page, _ in
            let draw: PageCompositor.Drawing = { context, page in drawWatermark(options, in: context, page: page) }
            return options.behindContent
                ? PageCompositor.compose(page, underlay: draw)
                : PageCompositor.compose(page, overlay: draw)
        }
    }

    @discardableResult
    public static func applyHeaderFooter(_ options: HeaderFooterOptions, to document: PDFDocument, pages: IndexSet) -> [Int: PDFPage] {
        let total = document.pageCount
        return replacePages(in: document, indexes: pages) { page, ordinal in
            PageCompositor.compose(page, overlay: { context, page in
                drawHeaderFooter(options, in: context, page: page, ordinal: ordinal, totalPages: total)
            })
        }
    }

    @discardableResult
    public static func applyBackground(_ options: BackgroundOptions, to document: PDFDocument, pages: IndexSet) -> [Int: PDFPage] {
        replacePages(in: document, indexes: pages) { page, _ in
            PageCompositor.compose(page, underlay: { context, page in
                drawBackground(options, in: context, page: page)
            })
        }
    }

    // MARK: Drawing

    public static func drawWatermark(_ options: WatermarkOptions, in context: CGContext, page: PDFPage) {
        let pageSize = PageCompositor.enterDisplaySpace(context, page: page)
        context.setAlpha(options.opacity)

        let itemSize: CGSize
        let drawItem: (CGPoint) -> Void
        switch options.content {
        case .text(let text):
            let font = NSFont(name: options.fontName, size: options.fontSize) ?? .boldSystemFont(ofSize: options.fontSize)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: options.color]
            let string = NSAttributedString(string: text, attributes: attributes)
            itemSize = string.size()
            drawItem = { center in
                NSGraphicsContext.drawing(in: context) {
                    string.draw(at: CGPoint(x: center.x - itemSize.width / 2, y: center.y - itemSize.height / 2))
                }
            }
        case .image(let image):
            let width = pageSize.width * max(min(options.imageScale, 1), 0.02)
            let aspect = image.size.height / max(image.size.width, 1)
            itemSize = CGSize(width: width, height: width * aspect)
            drawItem = { center in
                NSGraphicsContext.drawing(in: context) {
                    image.draw(in: CGRect(x: center.x - itemSize.width / 2, y: center.y - itemSize.height / 2,
                                          width: itemSize.width, height: itemSize.height))
                }
            }
        }

        func drawRotated(at center: CGPoint) {
            context.saveGState()
            context.translateBy(x: center.x, y: center.y)
            context.rotate(by: options.rotation * .pi / 180)
            drawItem(.zero)
            context.restoreGState()
        }

        if options.tiled {
            let stepX = itemSize.width + options.tileSpacing
            let stepY = itemSize.height + options.tileSpacing
            var y = stepY / 2
            var row = 0
            while y < pageSize.height + stepY {
                var x = (row % 2 == 0 ? 0 : stepX / 2) + stepX / 2
                while x < pageSize.width + stepX {
                    drawRotated(at: CGPoint(x: x, y: y))
                    x += stepX
                }
                y += stepY
                row += 1
            }
        } else {
            let frame = PageGeometry.place(itemSize, in: CGRect(origin: .zero, size: pageSize), anchor: options.anchor, margin: 36)
            drawRotated(at: CGPoint(x: frame.midX, y: frame.midY))
        }
    }

    public static func drawHeaderFooter(_ options: HeaderFooterOptions, in context: CGContext, page: PDFPage, ordinal: Int, totalPages: Int) {
        let pageSize = PageCompositor.enterDisplaySpace(context, page: page)
        let font = NSFont(name: options.fontName, size: options.fontSize) ?? .systemFont(ofSize: options.fontSize)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: options.color]

        let slots: [(String, PageGeometry.Anchor)] = [
            (options.headerLeft, .topLeading), (options.headerCenter, .top), (options.headerRight, .topTrailing),
            (options.footerLeft, .bottomLeading), (options.footerCenter, .bottom), (options.footerRight, .bottomTrailing),
        ]
        NSGraphicsContext.drawing(in: context) {
            for (template, anchor) in slots where !template.isEmpty {
                let text = options.expand(template, ordinal: ordinal, totalPages: totalPages)
                let string = NSAttributedString(string: text, attributes: attributes)
                let size = string.size()
                let container = CGRect(origin: .zero, size: pageSize)
                    .insetBy(dx: options.horizontalMargin, dy: options.verticalMargin)
                let frame = PageGeometry.place(size, in: container, anchor: anchor, margin: 0)
                string.draw(at: frame.origin)
            }
        }
    }

    public static func drawBackground(_ options: BackgroundOptions, in context: CGContext, page: PDFPage) {
        let pageSize = PageCompositor.enterDisplaySpace(context, page: page)
        let rect = CGRect(origin: .zero, size: pageSize)
        context.setAlpha(options.opacity)
        if let image = options.image {
            let imageSize = image.size
            let scale = options.imageFillsPage
                ? max(rect.width / max(imageSize.width, 1), rect.height / max(imageSize.height, 1))
                : min(rect.width / max(imageSize.width, 1), rect.height / max(imageSize.height, 1))
            let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            context.clip(to: rect)
            NSGraphicsContext.drawing(in: context) {
                image.draw(in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
            }
        } else {
            context.setFillColor(options.color.cgColor)
            context.fill(rect)
        }
    }
}
