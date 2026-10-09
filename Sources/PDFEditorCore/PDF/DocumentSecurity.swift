import Foundation
import PDFKit

/// Password and permission settings applied when the document is written.
public struct SecuritySettings: Equatable, Sendable {
    /// Required to open the document.
    public var openPassword: String = ""
    /// Required to change permissions.
    public var permissionsPassword: String = ""
    public var allowsPrinting = true
    public var allowsCopying = true

    public init() {}

    public var isEncrypted: Bool { !openPassword.isEmpty || !permissionsPassword.isEmpty }

    /// Restricting permissions only works with an owner (permissions) password.
    public var restrictsPermissions: Bool { !allowsPrinting || !allowsCopying }

    public func writeOptions() -> [PDFDocumentWriteOption: Any] {
        guard isEncrypted else { return [:] }
        var options: [PDFDocumentWriteOption: Any] = [:]
        if !openPassword.isEmpty {
            options[.userPasswordOption] = openPassword
        }
        // Without an explicit owner password, reuse the open password so the
        // file cannot be re-permissioned without it.
        let owner = permissionsPassword.isEmpty ? openPassword : permissionsPassword
        options[.ownerPasswordOption] = owner
        options[PDFDocumentWriteOption(rawValue: kCGPDFContextAllowsPrinting as String)] = allowsPrinting
        options[PDFDocumentWriteOption(rawValue: kCGPDFContextAllowsCopying as String)] = allowsCopying
        return options
    }
}

/// Options applied when writing the final file.
public struct ExportOptions: Equatable {
    public var security = SecuritySettings()
    /// Burn all annotations into the page content.
    public var flattenAnnotations = false
    /// Re-encode images as JPEG.
    public var saveImagesAsJPEG = false
    /// Downsample images to screen resolution.
    public var optimizeImagesForScreen = false

    public init() {}

    public func writeOptions() -> [PDFDocumentWriteOption: Any] {
        var options = security.writeOptions()
        if flattenAnnotations { options[.burnInAnnotationsOption] = true }
        if saveImagesAsJPEG { options[.saveImagesAsJPEGOption] = true }
        if optimizeImagesForScreen { options[.optimizeImagesForScreenOption] = true }
        return options
    }
}

public enum ExportError: Error, LocalizedError {
    case serializationFailed
    case locked

    public var errorDescription: String? {
        switch self {
        case .serializationFailed: return "The PDF could not be written."
        case .locked: return "The document is locked. Unlock it with its password first."
        }
    }
}

/// Produces the bytes of the saved file.
public enum DocumentExporter {
    /// Serializes `document`, burning overlay annotations into page content and
    /// applying `options`. The live document is left as it was.
    public static func export(_ document: PDFDocument, options: ExportOptions = ExportOptions()) throws -> Data {
        guard !document.isLocked else { throw ExportError.locked }

        var overlaysByPage: [Int: [OverlayAnnotation]] = [:]
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let overlays = page.overlayAnnotations
            if !overlays.isEmpty { overlaysByPage[index] = overlays }
        }

        let writeOptions = options.writeOptions()
        if overlaysByPage.isEmpty {
            guard let data = document.data(withOptions: writeOptions) else { throw ExportError.serializationFailed }
            return data
        }

        // Serialize without the overlays, then burn them into a copy.
        for (index, overlays) in overlaysByPage {
            guard let page = document.page(at: index) else { continue }
            overlays.forEach { page.removeAnnotation($0) }
        }
        let plain = document.dataRepresentation()
        for (index, overlays) in overlaysByPage {
            guard let page = document.page(at: index) else { continue }
            overlays.forEach { page.addAnnotation($0) }
        }
        guard let plain, let copy = PDFDocument(data: plain) else { throw ExportError.serializationFailed }

        for (index, overlays) in overlaysByPage {
            guard let page = copy.page(at: index),
                  let composed = PageCompositor.compose(page, overlay: { context, _ in
                      NSGraphicsContext.drawing(in: context) {
                          for overlay in overlays {
                              context.saveGState()
                              overlay.drawOverlay(in: context)
                              context.restoreGState()
                          }
                      }
                  }) else { continue }
            copy.replacePage(at: index, with: composed)
        }
        guard let data = copy.data(withOptions: writeOptions) else { throw ExportError.serializationFailed }
        return data
    }
}
