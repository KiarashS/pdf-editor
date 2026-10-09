import AppKit
import PDFKit

/// Coordinate helpers for drawing on a page the way the reader sees it.
public enum PageGeometry {
    /// Normalized clockwise rotation (0, 90, 180 or 270).
    public static func rotation(of page: PDFPage) -> Int {
        ((page.rotation % 360) + 360) % 360
    }

    /// Size of the crop box as displayed, i.e. after applying the page rotation.
    public static func displaySize(of page: PDFPage, box: PDFDisplayBox = .cropBox) -> CGSize {
        let rect = page.bounds(for: box)
        switch rotation(of: page) {
        case 90, 270: return CGSize(width: rect.height, height: rect.width)
        default: return rect.size
        }
    }

    /// Transform from display space (origin bottom-left of the page as the
    /// reader sees it, size `displaySize`) to the page's user space.
    public static func displayToPage(_ page: PDFPage, box: PDFDisplayBox = .cropBox) -> CGAffineTransform {
        let rect = page.bounds(for: box)
        let w = rect.width
        let h = rect.height
        let base: CGAffineTransform
        switch rotation(of: page) {
        case 90:
            base = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: w, ty: 0)
        case 180:
            base = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case 270:
            base = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: h)
        default:
            base = .identity
        }
        return base.concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY))
    }

    /// Rect in display space for a rectangle given in page space.
    public static func displayRect(for pageRect: CGRect, on page: PDFPage) -> CGRect {
        pageRect.applying(displayToPage(page).inverted())
    }

    /// Rect in page space for a rectangle given in display space.
    public static func pageRect(for displayRect: CGRect, on page: PDFPage) -> CGRect {
        displayRect.applying(displayToPage(page))
    }

    /// Lays out `size` inside `container` at one of nine anchor positions.
    public static func place(_ size: CGSize, in container: CGRect, anchor: Anchor, margin: CGFloat) -> CGRect {
        let inner = container.insetBy(dx: margin, dy: margin)
        let x: CGFloat
        switch anchor.horizontal {
        case .leading: x = inner.minX
        case .center: x = inner.midX - size.width / 2
        case .trailing: x = inner.maxX - size.width
        }
        let y: CGFloat
        switch anchor.vertical {
        case .top: y = inner.maxY - size.height
        case .middle: y = inner.midY - size.height / 2
        case .bottom: y = inner.minY
        }
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    public struct Anchor: Hashable, Codable, CaseIterable, Identifiable {
        public enum Horizontal: String, Codable { case leading, center, trailing }
        public enum Vertical: String, Codable { case top, middle, bottom }
        public var horizontal: Horizontal
        public var vertical: Vertical

        public init(_ vertical: Vertical, _ horizontal: Horizontal) {
            self.vertical = vertical
            self.horizontal = horizontal
        }

        public var id: String { vertical.rawValue + "-" + horizontal.rawValue }

        public static let topLeading = Anchor(.top, .leading)
        public static let top = Anchor(.top, .center)
        public static let topTrailing = Anchor(.top, .trailing)
        public static let leading = Anchor(.middle, .leading)
        public static let center = Anchor(.middle, .center)
        public static let trailing = Anchor(.middle, .trailing)
        public static let bottomLeading = Anchor(.bottom, .leading)
        public static let bottom = Anchor(.bottom, .center)
        public static let bottomTrailing = Anchor(.bottom, .trailing)

        public static let allCases: [Anchor] = [
            .topLeading, .top, .topTrailing,
            .leading, .center, .trailing,
            .bottomLeading, .bottom, .bottomTrailing,
        ]
    }
}

/// Standard paper sizes in PDF points.
public enum PaperSize: String, CaseIterable, Identifiable, Codable {
    case letter, legal, tabloid, a3, a4, a5, b5

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .letter: return "US Letter"
        case .legal: return "US Legal"
        case .tabloid: return "Tabloid"
        case .a3: return "A3"
        case .a4: return "A4"
        case .a5: return "A5"
        case .b5: return "B5"
        }
    }

    public var size: CGSize {
        switch self {
        case .letter: return CGSize(width: 612, height: 792)
        case .legal: return CGSize(width: 612, height: 1008)
        case .tabloid: return CGSize(width: 792, height: 1224)
        case .a3: return CGSize(width: 842, height: 1191)
        case .a4: return CGSize(width: 595, height: 842)
        case .a5: return CGSize(width: 420, height: 595)
        case .b5: return CGSize(width: 499, height: 709)
        }
    }
}

extension NSGraphicsContext {
    /// Runs `body` with an AppKit graphics context wrapping `cgContext`, so
    /// NSString/NSImage/NSBezierPath drawing goes to that context.
    public static func drawing(in cgContext: CGContext, flipped: Bool = false, _ body: () -> Void) {
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cgContext, flipped: flipped)
        body()
        NSGraphicsContext.current = previous
    }
}
