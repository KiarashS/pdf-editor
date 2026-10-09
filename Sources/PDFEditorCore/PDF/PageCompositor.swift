import AppKit
import PDFKit

/// Rebuilds pages with extra drawing burned into the page content.
///
/// The original page is embedded with `CGContext.drawPDFPage`, which keeps
/// text and vector graphics intact. Drawing closures receive the context in
/// page (user) space; use `displayContext` helpers to draw upright on rotated pages.
public enum PageCompositor {
    public typealias Drawing = (_ context: CGContext, _ page: PDFPage) -> Void

    /// Returns a new page whose content is `underlay` + original content + `overlay`.
    /// Annotations are not copied; `PDFDocument.replacePage` moves them.
    public static func compose(_ page: PDFPage,
                               includeOriginal: Bool = true,
                               underlay: Drawing? = nil,
                               overlay: Drawing? = nil) -> PDFPage? {
        var mediaBox = page.bounds(for: .mediaBox)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

        context.beginPDFPage(nil)
        if let underlay {
            context.saveGState()
            underlay(context, page)
            context.restoreGState()
        }
        if includeOriginal, let pageRef = page.pageRef {
            context.saveGState()
            context.drawPDFPage(pageRef)
            context.restoreGState()
        }
        if let overlay {
            context.saveGState()
            overlay(context, page)
            context.restoreGState()
        }
        context.endPDFPage()
        context.closePDF()

        guard let document = PDFDocument(data: data as Data), let newPage = document.page(at: 0) else { return nil }
        newPage.setBounds(page.bounds(for: .cropBox), for: .cropBox)
        newPage.rotation = page.rotation
        return newPage
    }

    /// Creates a page that shows `image` filling the page's media box. Used by
    /// rasterizing operations (redaction, compression).
    public static func imagePage(_ image: CGImage, like page: PDFPage, jpegQuality: CGFloat? = nil) -> PDFPage? {
        compose(page, includeOriginal: false, overlay: { context, page in
            var drawable = image
            if let jpegQuality,
               let data = PageRenderer.encode(image, as: .jpeg, quality: jpegQuality),
               let provider = CGDataProvider(data: data as CFData),
               let jpeg = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) {
                drawable = jpeg
            }
            context.saveGState()
            // The bitmap was rendered upright from the crop box.
            context.concatenate(PageGeometry.displayToPage(page))
            let size = PageGeometry.displaySize(of: page)
            context.draw(drawable, in: CGRect(origin: .zero, size: size))
            context.restoreGState()
        })
    }

    /// Prepares `context` (in page space) so that drawing happens in display
    /// space: origin at the bottom-left of the page as the reader sees it.
    public static func enterDisplaySpace(_ context: CGContext, page: PDFPage) -> CGSize {
        context.concatenate(PageGeometry.displayToPage(page))
        return PageGeometry.displaySize(of: page)
    }

    /// A blank page of the given size.
    public static func blankPage(size: CGSize, color: NSColor? = nil) -> PDFPage? {
        var mediaBox = CGRect(origin: .zero, size: size)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }
        context.beginPDFPage(nil)
        if let color {
            context.setFillColor(color.cgColor)
            context.fill(mediaBox)
        }
        context.endPDFPage()
        context.closePDF()
        return PDFDocument(data: data as Data)?.page(at: 0)
    }

    /// A page showing `image` scaled to fit `pageSize` (or the image's own
    /// size at 72 dpi when `pageSize` is nil), with `margin` points around it.
    public static func page(for image: NSImage, pageSize: CGSize?, margin: CGFloat = 0) -> PDFPage? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let imageSize = image.size.width > 0 ? image.size : CGSize(width: cgImage.width, height: cgImage.height)
        var size = pageSize ?? CGSize(width: imageSize.width + margin * 2, height: imageSize.height + margin * 2)
        // Match orientation to the image when a fixed paper size is used.
        if pageSize != nil, (imageSize.width > imageSize.height) != (size.width > size.height) {
            size = CGSize(width: size.height, height: size.width)
        }
        var mediaBox = CGRect(origin: .zero, size: size)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }
        context.beginPDFPage(nil)
        let available = mediaBox.insetBy(dx: margin, dy: margin)
        let scale = min(available.width / imageSize.width, available.height / imageSize.height)
        let drawSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let rect = CGRect(x: available.midX - drawSize.width / 2, y: available.midY - drawSize.height / 2,
                          width: drawSize.width, height: drawSize.height)
        context.interpolationQuality = .high
        context.draw(cgImage, in: rect)
        context.endPDFPage()
        context.closePDF()
        return PDFDocument(data: data as Data)?.page(at: 0)
    }
}
