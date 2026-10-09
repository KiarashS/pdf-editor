import AppKit
import PDFEditorCore
import PDFKit
import SwiftUI

/// Transparent view above the PDF that draws selection handles and tool
/// previews, and takes the mouse when a drawing tool is active.
final class InteractionOverlay: NSView {
    weak var pdfView: EditorPDFView?

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let pdfView, !isHidden else { return nil }
        // `point` is in the superview's (the PDF view's) coordinates.
        return pdfView.capturesMouse(at: point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) { pdfView?.handleMouseDown(event) }
    override func mouseDragged(with event: NSEvent) { pdfView?.handleMouseDragged(event) }
    override func mouseUp(with event: NSEvent) { pdfView?.handleMouseUp(event) }

    override func scrollWheel(with event: NSEvent) {
        if let scrollView = pdfView?.documentView?.enclosingScrollView {
            scrollView.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    override func magnify(with event: NSEvent) { pdfView?.magnify(with: event) }

    override func resetCursorRects() {
        guard let tool = pdfView?.controller?.tool else { return }
        switch tool.interaction {
        case .pan: addCursorRect(bounds, cursor: .openHand)
        case .ink, .rect, .line: addCursorRect(bounds, cursor: .crosshair)
        case .click: addCursorRect(bounds, cursor: tool == .editText ? .iBeam : .pointingHand)
        case .select, .textMarkup: break
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let pdfView, let controller = pdfView.controller else { return }

        if let annotation = controller.selectedAnnotation, let rect = pdfView.viewRect(for: annotation) {
            let frame = convert(rect, from: pdfView)
            NSColor.controlAccentColor.setStroke()
            let outline = NSBezierPath(rect: frame.insetBy(dx: -2, dy: -2))
            outline.lineWidth = 1
            outline.setLineDash([4, 3], count: 2, phase: 0)
            outline.stroke()
            if pdfView.canResize(annotation) {
                for (_, handleRect) in pdfView.handleRects(for: rect) {
                    let box = convert(handleRect, from: pdfView)
                    NSColor.white.setFill()
                    NSBezierPath(rect: box).fill()
                    NSColor.controlAccentColor.setStroke()
                    let border = NSBezierPath(rect: box)
                    border.lineWidth = 1
                    border.stroke()
                }
            }
        }

        guard let drag = pdfView.drag else { return }
        let style = controller.style
        switch drag {
        case .inking(let page, let strokes):
            let isMarker = controller.tool == .highlighterPen
            let color = isMarker ? style.highlightColor.withAlphaComponent(0.45) : style.strokeColor
            color.setStroke()
            for stroke in strokes where !stroke.isEmpty {
                let path = NSBezierPath()
                path.lineWidth = (isMarker ? max(style.lineWidth * 5, 10) : style.lineWidth) * pdfView.scaleFactor
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.move(to: point(stroke[0], on: page))
                for p in stroke.dropFirst() { path.line(to: point(p, on: page)) }
                path.stroke()
            }
        case .rect(let page, let start, let current):
            let a = point(start, on: page), b = point(current, on: page)
            let rect = NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            let path: NSBezierPath = controller.tool == .oval ? NSBezierPath(ovalIn: rect) : NSBezierPath(rect: rect)
            path.lineWidth = 1.5
            let tint: NSColor = controller.tool == .redactArea ? .systemRed : .controlAccentColor
            tint.withAlphaComponent(0.12).setFill()
            path.fill()
            tint.setStroke()
            path.setLineDash([5, 3], count: 2, phase: 0)
            path.stroke()
        case .line(let page, let start, let current):
            let path = NSBezierPath()
            path.move(to: point(start, on: page))
            path.line(to: point(current, on: page))
            path.lineWidth = max(style.lineWidth * pdfView.scaleFactor, 1)
            style.strokeColor.setStroke()
            path.stroke()
            if controller.tool == .measure {
                let label = AnnotationFactory.distanceLabel(from: start, to: current, unit: controller.measureUnit, scale: controller.measureScale)
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: NSColor.white,
                    .backgroundColor: NSColor.black.withAlphaComponent(0.7),
                ]
                let end = point(current, on: page)
                NSAttributedString(string: " \(label) ", attributes: attributes).draw(at: NSPoint(x: end.x + 8, y: end.y + 8))
            }
        case .panning, .moving, .resizing:
            break
        }
    }

    private func point(_ pagePoint: CGPoint, on page: PDFPage) -> NSPoint {
        guard let pdfView else { return pagePoint }
        return convert(pdfView.convert(pagePoint, from: page), from: pdfView)
    }
}

/// SwiftUI wrapper for the editor canvas.
struct PDFCanvas: NSViewRepresentable {
    let controller: EditorController

    func makeNSView(context: Context) -> EditorPDFView {
        let view = EditorPDFView(frame: .zero)
        view.controller = controller
        view.document = controller.document
        // Attaching updates observed state, which must not happen during a view update.
        DispatchQueue.main.async {
            MainActor.assumeIsolated { controller.attach(view) }
        }
        return view
    }

    func updateNSView(_ view: EditorPDFView, context: Context) {
        if view.document !== controller.document {
            view.document = controller.document
        }
    }
}
