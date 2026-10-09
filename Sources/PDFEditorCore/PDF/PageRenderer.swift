import AppKit
import ImageIO
import PDFKit

/// Renders pages to bitmaps.
public enum PageRenderer {
    /// Renders the visible (crop box) area of `page` upright, at `dpi`.
    ///
    /// - Parameters:
    ///   - includeAnnotations: draw annotations on top of the page content.
    ///   - background: fill color under the page; `nil` keeps transparency.
    public static func cgImage(for page: PDFPage,
                               dpi: CGFloat = 144,
                               includeAnnotations: Bool = true,
                               background: CGColor? = CGColor(gray: 1, alpha: 1),
                               decorate: ((CGContext) -> Void)? = nil) -> CGImage? {
        let scale = dpi / 72
        let size = PageGeometry.displaySize(of: page)
        let width = max(Int((size.width * scale).rounded()), 1)
        let height = max(Int((size.height * scale).rounded()), 1)
        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        if let background {
            context.setFillColor(background)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        context.concatenate(PageGeometry.displayToPage(page).inverted())
        drawContent(of: page, in: context, includeAnnotations: includeAnnotations)
        decorate?(context)
        return context.makeImage()
    }

    /// Draws page content (and optionally annotations) in page space.
    public static func drawContent(of page: PDFPage, in context: CGContext, includeAnnotations: Bool) {
        if let pageRef = page.pageRef {
            context.saveGState()
            context.drawPDFPage(pageRef)
            context.restoreGState()
        }
        guard includeAnnotations else { return }
        NSGraphicsContext.drawing(in: context) {
            for annotation in page.annotations where annotation.shouldDisplay {
                context.saveGState()
                annotation.draw(with: .mediaBox, in: context)
                context.restoreGState()
            }
        }
    }

    public static func nsImage(for page: PDFPage, dpi: CGFloat = 144, includeAnnotations: Bool = true) -> NSImage? {
        guard let image = cgImage(for: page, dpi: dpi, includeAnnotations: includeAnnotations) else { return nil }
        let size = PageGeometry.displaySize(of: page)
        return NSImage(cgImage: image, size: size)
    }

    public enum ImageFormat: String, CaseIterable, Identifiable, Sendable {
        case png, jpeg, tiff, heic

        public var id: String { rawValue }
        public var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
    }

    /// Encodes a rendered image. `quality` applies to JPEG and HEIC.
    public static func encode(_ image: CGImage, as format: ImageFormat, quality: CGFloat = 0.85) -> Data? {
        if format == .heic {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.heic" as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            return CGImageDestinationFinalize(destination) ? data as Data : nil
        }
        let rep = NSBitmapImageRep(cgImage: image)
        switch format {
        case .png: return rep.representation(using: .png, properties: [:])
        case .jpeg: return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
        case .tiff: return rep.representation(using: .tiff, properties: [.compressionMethod: NSBitmapImageRep.TIFFCompression.lzw.rawValue])
        case .heic: return nil
        }
    }
}
