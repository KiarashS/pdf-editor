import AppKit
import PDFKit

/// A saved signature the user can place on documents.
public struct Signature: Codable, Identifiable, Equatable {
    public enum Kind: Codable, Equatable {
        /// Freehand strokes in a 0...1 normalized box (origin bottom-left).
        case drawn(strokes: [[CGPoint]], aspectRatio: CGFloat)
        /// Typed name in a script font.
        case typed(text: String, fontName: String)
        /// PNG image data.
        case image(Data)
    }

    public var id = UUID()
    public var name: String
    public var kind: Kind
    public var colorHex: String = "#1A1A8C"
    public var createdAt = Date()

    public init(name: String, kind: Kind, colorHex: String = "#1A1A8C") {
        self.name = name
        self.kind = kind
        self.colorHex = colorHex
    }

    public var color: NSColor { NSColor(hex: colorHex) ?? .black }

    /// Natural size used when the signature is placed by clicking.
    public var defaultSize: CGSize {
        switch kind {
        case .drawn(_, let aspect):
            let width: CGFloat = 160
            return CGSize(width: width, height: max(width / max(aspect, 0.1), 20))
        case .typed(let text, let fontName):
            let font = NSFont(name: fontName, size: 28) ?? .systemFont(ofSize: 28)
            let size = NSAttributedString(string: text, attributes: [.font: font]).size()
            return CGSize(width: ceil(size.width) + 8, height: ceil(size.height) + 4)
        case .image(let data):
            let image = NSImage(data: data)
            let size = image?.size ?? CGSize(width: 160, height: 60)
            let scale = 160 / max(size.width, 1)
            return CGSize(width: 160, height: size.height * scale)
        }
    }

    /// Annotations that place this signature in `rect` (page space).
    public func annotations(in rect: CGRect) -> [PDFAnnotation] {
        switch kind {
        case .drawn(let strokes, _):
            let pageStrokes = strokes.map { stroke in
                stroke.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) }
            }
            guard let ink = AnnotationFactory.ink(strokes: pageStrokes, color: color, lineWidth: max(rect.height / 40, 1.2)) else { return [] }
            ink.contents = "Signature: \(name)"
            return [ink]
        case .typed(let text, let fontName):
            var style = AnnotationStyle()
            style.fontName = fontName
            style.fontSize = max(rect.height * 0.7, 8)
            style.textColor = color
            let annotation = AnnotationFactory.textBox(rect: rect, text: text, style: style, bordered: false)
            return [annotation]
        case .image(let data):
            guard let image = NSImage(data: data) else { return [] }
            let overlay = ImageOverlayAnnotation(image: image, bounds: rect)
            overlay.contents = "Signature: \(name)"
            return [overlay]
        }
    }

    /// Preview image for lists.
    public func previewImage(size: CGSize = CGSize(width: 200, height: 70)) -> NSImage {
        NSImage(size: size, flipped: false) { bounds in
            switch kind {
            case .drawn(let strokes, let aspect):
                let height = min(bounds.height, bounds.width / max(aspect, 0.1))
                let width = height * aspect
                let box = CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
                color.setStroke()
                for stroke in strokes where !stroke.isEmpty {
                    let path = NSBezierPath()
                    path.lineWidth = 2
                    path.lineCapStyle = .round
                    path.lineJoinStyle = .round
                    path.move(to: CGPoint(x: box.minX + stroke[0].x * box.width, y: box.minY + stroke[0].y * box.height))
                    for point in stroke.dropFirst() {
                        path.line(to: CGPoint(x: box.minX + point.x * box.width, y: box.minY + point.y * box.height))
                    }
                    path.stroke()
                }
            case .typed(let text, let fontName):
                let font = NSFont(name: fontName, size: bounds.height * 0.55) ?? .systemFont(ofSize: bounds.height * 0.55)
                let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
                let size = string.size()
                string.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
            case .image(let data):
                if let image = NSImage(data: data) {
                    let scale = min(bounds.width / max(image.size.width, 1), bounds.height / max(image.size.height, 1))
                    let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                    image.draw(in: CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height))
                }
            }
            return true
        }
    }

    /// Normalizes strokes drawn in a canvas of `canvasSize` into a tight 0...1 box.
    public static func normalized(strokes: [[CGPoint]]) -> (strokes: [[CGPoint]], aspectRatio: CGFloat)? {
        let points = strokes.flatMap { $0 }
        guard let first = points.first else { return nil }
        var rect = CGRect(origin: first, size: .zero)
        for point in points { rect = rect.union(CGRect(origin: point, size: .zero)) }
        let width = max(rect.width, 1)
        let height = max(rect.height, 1)
        let normalized = strokes.map { stroke in
            stroke.map { CGPoint(x: ($0.x - rect.minX) / width, y: ($0.y - rect.minY) / height) }
        }
        return (normalized, width / height)
    }
}

/// Persists signatures in Application Support.
public final class SignatureStore {
    public private(set) var signatures: [Signature] = []
    private let url: URL

    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PDFEditor", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("signatures.json")
        load()
    }

    public func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Signature].self, from: data) else { return }
        signatures = decoded
    }

    public func add(_ signature: Signature) {
        signatures.append(signature)
        save()
    }

    public func remove(id: Signature.ID) {
        signatures.removeAll { $0.id == id }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(signatures) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Script fonts that ship with macOS, for typed signatures.
    public static let scriptFonts = ["Snell Roundhand", "Zapfino", "Bradley Hand", "Noteworthy-Light", "Savoye LET", "Apple Chancery", "Chalkduster"]
}

extension NSColor {
    public convenience init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6 || text.count == 8, let value = UInt64(text, radix: 16) else { return nil }
        let hasAlpha = text.count == 8
        let r = CGFloat((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = CGFloat((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = CGFloat((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? CGFloat(value & 0xFF) / 255 : 1
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }

    public var hexString: String {
        let color = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X",
                      Int((color.redComponent * 255).rounded()),
                      Int((color.greenComponent * 255).rounded()),
                      Int((color.blueComponent * 255).rounded()))
    }
}
