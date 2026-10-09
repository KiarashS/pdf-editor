import AppKit
import CoreImage
import PDFEditorCore
import PDFKit

/// PDFView with editing tools. Mouse input for tools is captured by a
/// transparent overlay; plain clicks fall through to PDFView so text
/// selection, links and form filling keep working.
final class EditorPDFView: PDFView {
    weak var controller: EditorController?
    let overlay = InteractionOverlay()
    private(set) var drag: DragState?
    private var eventMonitor: Any?
    private var observers: [NSObjectProtocol] = []

    enum Handle: CaseIterable {
        case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight
    }

    enum DragState {
        case panning(last: NSPoint)
        case moving(PDFAnnotation, page: PDFPage, original: CGRect, start: CGPoint)
        case resizing(PDFAnnotation, page: PDFPage, handle: Handle, original: CGRect, startView: NSPoint)
        case inking(page: PDFPage, strokes: [[CGPoint]])
        case rect(page: PDFPage, start: CGPoint, current: CGPoint)
        case line(page: PDFPage, start: CGPoint, current: CGPoint)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        autoScales = true
        displayMode = .singlePageContinuous
        displaysPageBreaks = true
        pageShadowsEnabled = true
        backgroundColor = .underPageBackgroundColor
        overlay.pdfView = self
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)

        let center = NotificationCenter.default
        for name in [Notification.Name.PDFViewPageChanged, .PDFViewScaleChanged, .PDFViewDisplayModeChanged, .PDFViewDocumentChanged] {
            observers.append(center.addObserver(forName: name, object: self, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.overlay.needsDisplay = true
                    self?.controller?.canvasDidScroll()
                    self?.observeScrolling()
                }
            })
        }
        observers.append(center.addObserver(forName: .PDFViewAnnotationHit, object: self, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let annotation = notification.userInfo?["PDFAnnotationHit"] as? PDFAnnotation,
                      annotation.isSubtype(.widget) else { return }
                // Typing into a field does not go through the undo manager; mark the document edited.
                self?.controller?.formFieldWasEdited()
            }
        })
    }

    private var observedClipView: NSClipView?

    private func observeScrolling() {
        guard let clip = documentView?.enclosingScrollView?.contentView, clip !== observedClipView else { return }
        observedClipView = clip
        clip.postsBoundsChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.overlay.needsDisplay = true
                self?.controller?.canvasDidScroll()
            }
        })
    }

    override func layout() {
        super.layout()
        overlay.frame = bounds
        if subviews.last !== overlay {
            overlay.removeFromSuperview()
            addSubview(overlay, positioned: .above, relativeTo: nil)
        }
        observeScrolling()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        guard newWindow != nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .keyDown]) { [weak self] event in
            guard let self else { return event }
            let consumed = MainActor.assumeIsolated { self.monitor(event) }
            return consumed ? nil : event
        }
    }

    // MARK: Appearance

    func apply(theme: ReadingTheme) {
        wantsLayer = true
        layerUsesCoreImageFilters = true
        switch theme {
        case .normal:
            contentFilters = []
        case .dark:
            let invert = CIFilter(name: "CIColorInvert")
            let hue = CIFilter(name: "CIHueAdjust", parameters: [kCIInputAngleKey: Double.pi])
            contentFilters = [invert, hue].compactMap { $0 }
        case .sepia:
            contentFilters = [CIFilter(name: "CISepiaTone", parameters: [kCIInputIntensityKey: 0.45])].compactMap { $0 }
        case .mint:
            let tint = CIFilter(name: "CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.86, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0.96, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0.84, w: 0),
            ])
            contentFilters = [tint].compactMap { $0 }
        }
    }

    func toolDidChange() {
        drag = nil
        overlay.needsDisplay = true
        window?.invalidateCursorRects(for: overlay)
    }

    // MARK: Hit testing

    /// Whether the overlay should take the mouse at `point` (in this view's coordinates).
    func capturesMouse(at point: NSPoint) -> Bool {
        guard let controller, !controller.isLocked else { return false }
        switch controller.tool.interaction {
        case .textMarkup:
            return false
        case .select:
            if let annotation = controller.selectedAnnotation, handle(at: point, for: annotation) != nil { return true }
            return selectableAnnotation(at: point) != nil
        case .pan:
            return true
        case .ink, .rect, .line, .click:
            return page(for: point, nearest: false) != nil
        }
    }

    /// The annotation under `point` that the select tool can pick up.
    func selectableAnnotation(at point: NSPoint) -> PDFAnnotation? {
        guard let controller, controller.mode != .read,
              let page = page(for: point, nearest: false) else { return nil }
        let pagePoint = convert(point, to: page)
        // Search topmost first.
        for annotation in page.annotations.reversed() where annotation.bounds.insetBy(dx: -3, dy: -3).contains(pagePoint) {
            if annotation.isSubtype(.popup) { continue }
            if annotation.isSubtype(.widget) && controller.mode != .forms { continue }
            if annotation.isSubtype(.link) && controller.mode != .edit { continue }
            return annotation
        }
        return nil
    }

    func viewRect(for annotation: PDFAnnotation) -> NSRect? {
        guard let page = annotation.page, document?.index(for: page) != NSNotFound else { return nil }
        return convert(annotation.bounds, from: page)
    }

    func canResize(_ annotation: PDFAnnotation) -> Bool {
        !(annotation.isSubtype(.ink) || annotation.isSubtype(.line) || annotation.isSubtype(.text) || annotation.isSubtype(.popup))
    }

    func handleRects(for rect: NSRect) -> [(Handle, NSRect)] {
        let size: CGFloat = 8
        func box(_ x: CGFloat, _ y: CGFloat) -> NSRect { NSRect(x: x - size / 2, y: y - size / 2, width: size, height: size) }
        return [
            (.topLeft, box(rect.minX, rect.maxY)), (.top, box(rect.midX, rect.maxY)), (.topRight, box(rect.maxX, rect.maxY)),
            (.left, box(rect.minX, rect.midY)), (.right, box(rect.maxX, rect.midY)),
            (.bottomLeft, box(rect.minX, rect.minY)), (.bottom, box(rect.midX, rect.minY)), (.bottomRight, box(rect.maxX, rect.minY)),
        ]
    }

    func handle(at point: NSPoint, for annotation: PDFAnnotation) -> Handle? {
        guard canResize(annotation), let rect = viewRect(for: annotation) else { return nil }
        return handleRects(for: rect).first { $0.1.insetBy(dx: -3, dy: -3).contains(point) }?.0
    }

    // MARK: Mouse (forwarded from the overlay)

    func handleMouseDown(_ event: NSEvent) {
        guard let controller else { return }
        window?.makeFirstResponder(self)
        let viewPoint = convert(event.locationInWindow, from: nil)

        if controller.tool.interaction == .pan {
            drag = .panning(last: event.locationInWindow)
            NSCursor.closedHand.set()
            return
        }
        guard let page = page(for: viewPoint, nearest: true) else { return }
        let point = convert(viewPoint, to: page)

        switch controller.tool.interaction {
        case .select:
            if let annotation = controller.selectedAnnotation, let handle = handle(at: viewPoint, for: annotation),
               let annotationPage = annotation.page {
                drag = .resizing(annotation, page: annotationPage, handle: handle, original: annotation.bounds, startView: viewPoint)
            } else if let annotation = selectableAnnotation(at: viewPoint), let annotationPage = annotation.page {
                controller.selectedAnnotation = annotation
                if event.clickCount >= 2 {
                    if let replacement = annotation as? TextReplacementAnnotation {
                        controller.beginTextEdit(at: CGPoint(x: replacement.bounds.midX, y: replacement.bounds.midY), on: annotationPage)
                    } else {
                        controller.beginEditing(annotation)
                    }
                    return
                }
                drag = .moving(annotation, page: annotationPage, original: annotation.bounds, start: point)
            }
        case .ink:
            drag = .inking(page: page, strokes: [[point]])
        case .rect:
            drag = .rect(page: page, start: point, current: point)
        case .line:
            drag = .line(page: page, start: point, current: point)
        case .click:
            controller.handleClick(at: point, on: page)
        case .pan, .textMarkup:
            break
        }
        overlay.needsDisplay = true
    }

    func handleMouseDragged(_ event: NSEvent) {
        guard let drag else { return }
        let viewPoint = convert(event.locationInWindow, from: nil)
        autoscroll(with: event)

        switch drag {
        case .panning(let last):
            scroll(by: CGPoint(x: event.locationInWindow.x - last.x, y: event.locationInWindow.y - last.y))
            self.drag = .panning(last: event.locationInWindow)
        case .moving(let annotation, let page, let original, let start):
            let point = convert(viewPoint, to: page)
            annotation.bounds = original.offsetBy(dx: point.x - start.x, dy: point.y - start.y)
            annotationsChanged(on: page)
        case .resizing(let annotation, let page, let handle, let original, let startView):
            let originalView = convert(original, from: page)
            let resized = resize(originalView, handle: handle, dx: viewPoint.x - startView.x, dy: viewPoint.y - startView.y,
                                 keepAspect: event.modifierFlags.contains(.shift) || annotation is ImageOverlayAnnotation)
            annotation.bounds = convert(resized, to: page).standardized
            annotationsChanged(on: page)
        case .inking(let page, var strokes):
            strokes[strokes.count - 1].append(convert(viewPoint, to: page))
            self.drag = .inking(page: page, strokes: strokes)
        case .rect(let page, let start, _):
            self.drag = .rect(page: page, start: start, current: convert(viewPoint, to: page))
        case .line(let page, let start, _):
            var end = convert(viewPoint, to: page)
            if event.modifierFlags.contains(.shift) { end = snapped(end, from: start) }
            self.drag = .line(page: page, start: start, current: end)
        }
        overlay.needsDisplay = true
    }

    func handleMouseUp(_ event: NSEvent) {
        guard let controller, let drag else { return }
        self.drag = nil
        switch drag {
        case .panning:
            NSCursor.openHand.set()
        case .moving(let annotation, _, let original, _), .resizing(let annotation, _, _, let original, _):
            controller.didChangeBounds(of: annotation, from: original)
        case .inking(let page, let strokes):
            controller.addInk(strokes: strokes, on: page)
        case .rect(let page, let start, let current):
            let rect = CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                              width: abs(current.x - start.x), height: abs(current.y - start.y))
            controller.createFromRect(rect.width < 4 && rect.height < 4 ? nil : rect, at: start, on: page)
        case .line(let page, let start, let current):
            controller.createLine(from: start, to: current, on: page)
        }
        overlay.needsDisplay = true
    }

    private func snapped(_ point: CGPoint, from start: CGPoint) -> CGPoint {
        let dx = point.x - start.x, dy = point.y - start.y
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        let length = hypot(dx, dy)
        return CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
    }

    private func resize(_ rect: NSRect, handle: Handle, dx: CGFloat, dy: CGFloat, keepAspect: Bool) -> NSRect {
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        switch handle {
        case .topLeft: minX += dx; maxY += dy
        case .top: maxY += dy
        case .topRight: maxX += dx; maxY += dy
        case .left: minX += dx
        case .right: maxX += dx
        case .bottomLeft: minX += dx; minY += dy
        case .bottom: minY += dy
        case .bottomRight: maxX += dx; minY += dy
        }
        var result = NSRect(x: min(minX, maxX), y: min(minY, maxY), width: max(abs(maxX - minX), 6), height: max(abs(maxY - minY), 6))
        if keepAspect, rect.height > 0, [.topLeft, .topRight, .bottomLeft, .bottomRight].contains(handle) {
            let aspect = rect.width / rect.height
            result.size.height = result.width / aspect
            if handle == .topLeft || handle == .topRight {
                result.origin.y = rect.minY
            } else {
                result.origin.y = rect.maxY - result.height
            }
        }
        return result
    }

    private func scroll(by delta: CGPoint) {
        guard let clip = documentView?.enclosingScrollView?.contentView else { return }
        var origin = clip.bounds.origin
        origin.x -= delta.x
        origin.y += clip.isFlipped ? delta.y : -delta.y
        clip.scroll(to: origin)
        clip.enclosingScrollView?.reflectScrolledClipView(clip)
    }

    // MARK: Event monitor

    /// Returns true when the event was handled and should not be dispatched.
    private func monitor(_ event: NSEvent) -> Bool {
        guard let controller, event.window === window, window?.isKeyWindow == true else { return false }
        switch event.type {
        case .leftMouseDown:
            let point = convert(event.locationInWindow, from: nil)
            if bounds.contains(point), controller.tool == .select, !capturesMouse(at: point) {
                controller.selectedAnnotation = nil
            }
        case .leftMouseUp:
            let point = convert(event.locationInWindow, from: nil)
            if bounds.contains(point), controller.tool.interaction == .textMarkup {
                DispatchQueue.main.async { [weak controller] in
                    MainActor.assumeIsolated { controller?.applyMarkupToSelection() }
                }
            }
        case .keyDown:
            return handleKey(event, controller: controller)
        default:
            break
        }
        return false
    }

    /// Keyboard shortcuts for the selected annotation. Returns true when handled.
    private func handleKey(_ event: NSEvent, controller: EditorController) -> Bool {
        // Leave typing in text fields alone.
        if window?.firstResponder is NSText { return false }
        guard controller.selectedAnnotation != nil else {
            if event.keyCode == 53, controller.tool != .select { // escape
                controller.tool = .select
                return true
            }
            return false
        }
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 51, 117: controller.deleteSelectedAnnotation()          // delete, forward delete
        case 53: controller.selectedAnnotation = nil                 // escape
        case 123: controller.nudgeSelectedAnnotation(dx: -step, dy: 0)
        case 124: controller.nudgeSelectedAnnotation(dx: step, dy: 0)
        case 125: controller.nudgeSelectedAnnotation(dx: 0, dy: -step)
        case 126: controller.nudgeSelectedAnnotation(dx: 0, dy: step)
        default: return false
        }
        return true
    }
}
