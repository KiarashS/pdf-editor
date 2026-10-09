import AppKit
import PDFKit

/// An annotation drawn by the app and burned into the page content when the
/// document is saved. PDFKit cannot write custom appearance streams, so
/// images and replaced text live as live, movable overlays while editing and
/// become ordinary page content in the saved file.
open class OverlayAnnotation: PDFAnnotation {
    public override init(bounds: CGRect, forType annotationType: PDFAnnotationSubtype, withProperties properties: [AnyHashable: Any]?) {
        super.init(bounds: bounds, forType: annotationType, withProperties: properties)
        shouldPrint = true
    }

    public init(bounds: CGRect) {
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
        shouldPrint = true
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    open var overlayKindName: String { "Overlay" }

    /// Draws the overlay in page space within `bounds`.
    open func drawOverlay(in context: CGContext) {}

    open override func draw(with box: PDFDisplayBox, in context: CGContext) {
        context.saveGState()
        NSGraphicsContext.drawing(in: context) {
            drawOverlay(in: context)
        }
        context.restoreGState()
    }
}

/// An image placed on the page (pictures, image signatures, image stamps).
public final class ImageOverlayAnnotation: OverlayAnnotation {
    public var image: NSImage = NSImage()
    public var imageOpacity: CGFloat = 1
    /// Clockwise rotation in degrees applied around the center.
    public var imageRotation: CGFloat = 0

    public init(image: NSImage, bounds: CGRect) {
        self.image = image
        super.init(bounds: bounds)
    }

    public override init(bounds: CGRect, forType annotationType: PDFAnnotationSubtype, withProperties properties: [AnyHashable: Any]?) {
        super.init(bounds: bounds, forType: annotationType, withProperties: properties)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    public override var overlayKindName: String { "Image" }

    public override func drawOverlay(in context: CGContext) {
        context.setAlpha(imageOpacity)
        if imageRotation != 0 {
            context.translateBy(x: bounds.midX, y: bounds.midY)
            context.rotate(by: -imageRotation * .pi / 180)
            context.translateBy(x: -bounds.midX, y: -bounds.midY)
        }
        image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
    }
}

/// Replaces existing page text: paints over the original glyphs and draws new text.
public final class TextReplacementAnnotation: OverlayAnnotation {
    public var text: String = ""
    public var textFont: NSFont = .systemFont(ofSize: 12)
    public var textColor: NSColor = .black
    /// Color used to cover the original text, usually the page background.
    public var coverColor: NSColor = .white
    public var textAlignment: NSTextAlignment = .left
    /// The area of the original text that gets covered.
    public var coveredRect: CGRect = .zero

    public init(bounds: CGRect, text: String, font: NSFont, textColor: NSColor, coverColor: NSColor) {
        self.text = text
        self.textFont = font
        self.textColor = textColor
        self.coverColor = coverColor
        self.coveredRect = bounds
        super.init(bounds: bounds)
    }

    public override init(bounds: CGRect, forType annotationType: PDFAnnotationSubtype, withProperties properties: [AnyHashable: Any]?) {
        super.init(bounds: bounds, forType: annotationType, withProperties: properties)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    public override var overlayKindName: String { "Edited Text" }

    public override var bounds: CGRect {
        didSet {
            // Moving the box moves the new text; the covered area stays put
            // only until the user moves it, so follow the box.
            let dx = bounds.minX - oldValue.minX
            let dy = bounds.minY - oldValue.minY
            if bounds.size == oldValue.size {
                coveredRect = coveredRect.offsetBy(dx: dx, dy: dy)
            } else {
                coveredRect = bounds
            }
        }
    }

    public override func drawOverlay(in context: CGContext) {
        context.setFillColor(coverColor.cgColor)
        context.fill(coveredRect.insetBy(dx: -1, dy: -1))
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = textAlignment
        paragraph.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: textFont,
            .foregroundColor: textColor,
            .paragraphStyle: paragraph,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        // Grow downward if the replacement needs more room than the box.
        let needed = string.boundingRect(with: CGSize(width: bounds.width, height: .greatestFiniteMagnitude),
                                         options: [.usesLineFragmentOrigin, .usesFontLeading])
        let height = max(bounds.height, ceil(needed.height))
        let rect = CGRect(x: bounds.minX, y: bounds.maxY - height, width: bounds.width, height: height)
        string.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
    }
}

extension PDFPage {
    /// Overlay annotations on this page.
    public var overlayAnnotations: [OverlayAnnotation] {
        annotations.compactMap { $0 as? OverlayAnnotation }
    }
}
