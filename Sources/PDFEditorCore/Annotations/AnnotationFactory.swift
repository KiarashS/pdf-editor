import AppKit
import PDFKit

/// Visual style shared by annotation tools.
public struct AnnotationStyle: Equatable {
    public var strokeColor: NSColor = .systemRed
    public var fillColor: NSColor? = nil
    public var highlightColor: NSColor = NSColor.systemYellow
    public var lineWidth: CGFloat = 2
    public var opacity: CGFloat = 1
    public var fontName: String = "Helvetica"
    public var fontSize: CGFloat = 14
    public var textColor: NSColor = .black
    public var dashed = false

    public init() {}

    public var font: NSFont { NSFont(name: fontName, size: fontSize) ?? .systemFont(ofSize: fontSize) }
}

/// Creates PDFKit annotations for the editor's tools.
///
/// PDFKit expects ink paths, line end points and quad points relative to
/// the annotation's bounds origin; the helpers here take page-space input
/// and do that conversion.
public enum AnnotationFactory {
    public static var authorName: String = NSFullUserName()

    static func stamp(_ annotation: PDFAnnotation) -> PDFAnnotation {
        annotation.userName = authorName
        annotation.modificationDate = Date()
        return annotation
    }

    static func border(width: CGFloat, dashed: Bool = false) -> PDFBorder {
        let border = PDFBorder()
        border.lineWidth = width
        if dashed {
            border.style = .dashed
            border.dashPattern = [width * 3, width * 2]
        }
        return border
    }

    // MARK: Text markup

    public enum MarkupKind: String, CaseIterable {
        case highlight, underline, strikeOut

        var subtype: PDFAnnotationSubtype {
            switch self {
            case .highlight: return .highlight
            case .underline: return .underline
            case .strikeOut: return .strikeOut
            }
        }
    }

    /// One markup annotation per line of the selection.
    public static func markup(_ kind: MarkupKind, selection: PDFSelection, color: NSColor) -> [(PDFPage, PDFAnnotation)] {
        var result: [(PDFPage, PDFAnnotation)] = []
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let bounds = line.bounds(for: page)
                guard bounds.width > 0.5, bounds.height > 0.5 else { continue }
                let annotation = PDFAnnotation(bounds: bounds, forType: kind.subtype, withProperties: nil)
                annotation.color = color
                annotation.quadrilateralPoints = [
                    NSValue(point: CGPoint(x: 0, y: bounds.height)),
                    NSValue(point: CGPoint(x: bounds.width, y: bounds.height)),
                    NSValue(point: CGPoint(x: 0, y: 0)),
                    NSValue(point: CGPoint(x: bounds.width, y: 0)),
                ]
                annotation.contents = line.string
                result.append((page, stamp(annotation)))
            }
        }
        return result
    }

    // MARK: Ink

    /// A freehand drawing from strokes given in page space.
    public static func ink(strokes: [[CGPoint]], color: NSColor, lineWidth: CGFloat) -> PDFAnnotation? {
        let points = strokes.flatMap { $0 }
        guard !points.isEmpty else { return nil }
        var rect = CGRect(origin: points[0], size: .zero)
        for point in points { rect = rect.union(CGRect(origin: point, size: .zero)) }
        let bounds = rect.insetBy(dx: -lineWidth * 2 - 2, dy: -lineWidth * 2 - 2)

        let annotation = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
        annotation.color = color
        annotation.border = border(width: lineWidth)
        for stroke in strokes where !stroke.isEmpty {
            let path = NSBezierPath()
            path.lineWidth = lineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: CGPoint(x: stroke[0].x - bounds.minX, y: stroke[0].y - bounds.minY))
            if stroke.count == 1 {
                path.line(to: CGPoint(x: stroke[0].x - bounds.minX + 0.1, y: stroke[0].y - bounds.minY))
            }
            for point in stroke.dropFirst() {
                path.line(to: CGPoint(x: point.x - bounds.minX, y: point.y - bounds.minY))
            }
            annotation.add(path)
        }
        return stamp(annotation)
    }

    /// Reduces jitter in a freehand stroke (Ramer–Douglas–Peucker).
    public static func simplify(_ points: [CGPoint], tolerance: CGFloat = 0.6) -> [CGPoint] {
        guard points.count > 2 else { return points }
        func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            let dx = b.x - a.x, dy = b.y - a.y
            let length = hypot(dx, dy)
            guard length > 0 else { return hypot(p.x - a.x, p.y - a.y) }
            return abs(dy * p.x - dx * p.y + b.x * a.y - b.y * a.x) / length
        }
        var maxDistance: CGFloat = 0
        var index = 0
        for i in 1..<(points.count - 1) {
            let d = distance(points[i], points[0], points[points.count - 1])
            if d > maxDistance { maxDistance = d; index = i }
        }
        guard maxDistance > tolerance else { return [points[0], points[points.count - 1]] }
        let left = simplify(Array(points[...index]), tolerance: tolerance)
        let right = simplify(Array(points[index...]), tolerance: tolerance)
        return Array(left.dropLast()) + right
    }

    // MARK: Shapes

    public enum ShapeKind: String, CaseIterable { case rectangle, oval }

    public static func shape(_ kind: ShapeKind, rect: CGRect, style: AnnotationStyle) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: rect.standardized, forType: kind == .rectangle ? .square : .circle, withProperties: nil)
        annotation.color = style.strokeColor.withAlphaComponent(style.opacity)
        annotation.interiorColor = style.fillColor?.withAlphaComponent(style.opacity)
        annotation.border = border(width: style.lineWidth, dashed: style.dashed)
        return stamp(annotation)
    }

    /// A line or arrow between two page-space points.
    public static func line(from start: CGPoint, to end: CGPoint, style: AnnotationStyle, arrow: Bool, doubleArrow: Bool = false) -> PDFAnnotation {
        let padding = max(style.lineWidth * 4, 8)
        let bounds = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                            width: abs(end.x - start.x), height: abs(end.y - start.y))
            .insetBy(dx: -padding, dy: -padding)
        let annotation = PDFAnnotation(bounds: bounds, forType: .line, withProperties: nil)
        annotation.startPoint = CGPoint(x: start.x - bounds.minX, y: start.y - bounds.minY)
        annotation.endPoint = CGPoint(x: end.x - bounds.minX, y: end.y - bounds.minY)
        annotation.startLineStyle = doubleArrow ? .closedArrow : .none
        annotation.endLineStyle = arrow || doubleArrow ? .closedArrow : .none
        annotation.color = style.strokeColor.withAlphaComponent(style.opacity)
        annotation.interiorColor = style.strokeColor.withAlphaComponent(style.opacity)
        annotation.border = border(width: style.lineWidth, dashed: style.dashed)
        return stamp(annotation)
    }

    // MARK: Text

    public static func textBox(rect: CGRect, text: String, style: AnnotationStyle, bordered: Bool) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: rect.standardized, forType: .freeText, withProperties: nil)
        annotation.contents = text
        annotation.font = style.font
        annotation.fontColor = style.textColor.withAlphaComponent(style.opacity)
        annotation.alignment = .left
        annotation.color = style.fillColor ?? .clear
        annotation.border = bordered ? border(width: max(style.lineWidth, 1)) : border(width: 0)
        return stamp(annotation)
    }

    /// Size that fits `text` at the style's font, for auto-sizing text boxes.
    public static func fittingSize(for text: String, style: AnnotationStyle, maxWidth: CGFloat = 400) -> CGSize {
        let attributed = NSAttributedString(string: text.isEmpty ? " " : text, attributes: [.font: style.font])
        let rect = attributed.boundingRect(with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                                           options: [.usesLineFragmentOrigin, .usesFontLeading])
        return CGSize(width: ceil(rect.width) + 12, height: ceil(rect.height) + 8)
    }

    public static func note(at point: CGPoint, text: String, color: NSColor) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: CGRect(x: point.x - 10, y: point.y - 10, width: 20, height: 20), forType: .text, withProperties: nil)
        annotation.contents = text
        annotation.color = color
        annotation.iconType = .comment
        return stamp(annotation)
    }

    // MARK: Stamps

    /// Standard stamp names PDF viewers render without an appearance stream.
    public static let standardStamps = [
        "Approved", "Experimental", "NotApproved", "AsIs", "Expired", "NotForPublicRelease",
        "Confidential", "Final", "Sold", "Departmental", "ForComment", "TopSecret", "Draft", "ForPublicRelease",
    ]

    public static func standardStamp(_ name: String, center: CGPoint) -> PDFAnnotation {
        let size = CGSize(width: 180, height: 50)
        let annotation = PDFAnnotation(bounds: CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height),
                                       forType: .stamp, withProperties: nil)
        annotation.stampName = name
        return stamp(annotation)
    }

    /// A custom text stamp ("PAID 2026-01-31") drawn as a bordered text box.
    public static func textStamp(_ text: String, center: CGPoint, color: NSColor) -> PDFAnnotation {
        var style = AnnotationStyle()
        style.fontName = "Helvetica-Bold"
        style.fontSize = 20
        style.textColor = color
        style.lineWidth = 2.5
        let size = fittingSize(for: text, style: style)
        let rect = CGRect(x: center.x - size.width / 2 - 6, y: center.y - size.height / 2 - 2, width: size.width + 12, height: size.height + 4)
        let annotation = textBox(rect: rect, text: text, style: style, bordered: true)
        annotation.alignment = .center
        annotation.color = color.withAlphaComponent(0.06)
        annotation.fontColor = color
        return annotation
    }

    // MARK: Links

    public static func link(rect: CGRect, url: URL) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: rect.standardized, forType: .link, withProperties: nil)
        annotation.url = url
        annotation.border = border(width: 0)
        return stamp(annotation)
    }

    public static func link(rect: CGRect, to page: PDFPage) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: rect.standardized, forType: .link, withProperties: nil)
        let top = page.bounds(for: .cropBox).maxY
        annotation.destination = PDFDestination(page: page, at: CGPoint(x: 0, y: top))
        annotation.border = border(width: 0)
        return stamp(annotation)
    }

    // MARK: Measurement

    public enum MeasureUnit: String, CaseIterable, Identifiable {
        case points = "pt", inches = "in", centimeters = "cm", millimeters = "mm"
        public var id: String { rawValue }

        /// Points per unit.
        public var points: CGFloat {
            switch self {
            case .points: return 1
            case .inches: return 72
            case .centimeters: return 72 / 2.54
            case .millimeters: return 72 / 25.4
            }
        }
    }

    /// Distance between two page-space points as a label, applying a drawing
    /// `scale` (e.g. 100 for 1:100).
    public static func distanceLabel(from start: CGPoint, to end: CGPoint, unit: MeasureUnit, scale: CGFloat) -> String {
        let value = hypot(end.x - start.x, end.y - start.y) / unit.points * scale
        return String(format: "%.2f %@", value, unit.rawValue)
    }

    /// A dimension line with arrows at both ends and a label.
    public static func measurement(from start: CGPoint, to end: CGPoint, unit: MeasureUnit, scale: CGFloat, style: AnnotationStyle) -> [PDFAnnotation] {
        let label = distanceLabel(from: start, to: end, unit: unit, scale: scale)
        let lineAnnotation = line(from: start, to: end, style: style, arrow: false, doubleArrow: true)
        lineAnnotation.contents = label
        var textStyle = style
        textStyle.fontSize = 10
        textStyle.textColor = style.strokeColor
        textStyle.fillColor = NSColor.white.withAlphaComponent(0.85)
        let size = fittingSize(for: label, style: textStyle)
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let labelAnnotation = textBox(rect: CGRect(x: mid.x - size.width / 2, y: mid.y + 4, width: size.width, height: size.height),
                                      text: label, style: textStyle, bordered: false)
        return [lineAnnotation, labelAnnotation]
    }
}
