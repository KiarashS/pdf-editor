import AppKit
import PDFEditorCore
import SwiftUI
import UniformTypeIdentifiers

/// Creates a signature by drawing, typing or importing an image.
@MainActor
struct SignatureCreatorSheet: View {
    enum Method: String, CaseIterable, Identifiable {
        case draw, type, image
        var id: String { rawValue }
    }

    let controller: EditorController
    @State private var method: Method = .draw
    @State private var name = "My Signature"
    @State private var strokes: [[CGPoint]] = []
    @State private var typed = NSFullUserName()
    @State private var fontName = SignatureStore.scriptFonts[0]
    @State private var imageData: Data?
    @State private var color = Color(red: 0.1, green: 0.1, blue: 0.55)
    @Environment(\.dismiss) private var dismiss

    private var canSave: Bool {
        switch method {
        case .draw: return !strokes.isEmpty
        case .type: return !typed.trimmingCharacters(in: .whitespaces).isEmpty
        case .image: return imageData != nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Signature").font(.headline)
            Picker("Method", selection: $method) {
                Text("Draw").tag(Method.draw)
                Text("Type").tag(Method.type)
                Text("Image").tag(Method.image)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch method {
                case .draw:
                    SignaturePad(strokes: $strokes, color: NSColor(color))
                        .frame(height: 170)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.4)))
                        .overlay(alignment: .bottomTrailing) {
                            Button("Clear") { strokes = [] }.padding(8)
                        }
                case .type:
                    VStack(alignment: .leading) {
                        TextField("Your name", text: $typed)
                        Picker("Style", selection: $fontName) {
                            ForEach(SignatureStore.scriptFonts.filter { NSFont(name: $0, size: 12) != nil }, id: \.self) { font in
                                Text(typed.isEmpty ? font : typed).font(.custom(font, size: 18)).tag(font)
                            }
                        }
                        Text(typed)
                            .font(.custom(fontName, size: 40))
                            .foregroundStyle(color)
                            .frame(maxWidth: .infinity, minHeight: 90)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                    }
                case .image:
                    VStack {
                        if let imageData, let image = NSImage(data: imageData) {
                            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(height: 120)
                        }
                        Button("Choose Image…") { chooseImage() }
                        Text("Use a PNG with a transparent background for best results.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 170)
                }
            }

            HStack {
                TextField("Name", text: $name).frame(width: 200)
                if method != .image {
                    ColorPicker("Ink", selection: $color, supportsOpacity: false)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url),
              let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
        imageData = rep.representation(using: .png, properties: [:])
    }

    private func save() {
        let kind: Signature.Kind
        switch method {
        case .draw:
            guard let normalized = Signature.normalized(strokes: strokes) else { return }
            kind = .drawn(strokes: normalized.strokes, aspectRatio: normalized.aspectRatio)
        case .type:
            kind = .typed(text: typed, fontName: fontName)
        case .image:
            guard let imageData else { return }
            kind = .image(imageData)
        }
        let signature = Signature(name: name.isEmpty ? "Signature" : name, kind: kind, colorHex: NSColor(color).hexString)
        controller.signatureStore.add(signature)
        controller.selectedSignatureID = signature.id
        controller.signaturesRevision += 1
        controller.mode = .comment
        controller.tool = .signature
        dismiss()
    }
}

/// Captures freehand strokes. Points use a bottom-left origin to match PDF space.
struct SignaturePad: NSViewRepresentable {
    @Binding var strokes: [[CGPoint]]
    let color: NSColor

    func makeNSView(context: Context) -> SignaturePadView {
        let view = SignaturePadView()
        view.onChange = { strokes = $0 }
        return view
    }

    func updateNSView(_ view: SignaturePadView, context: Context) {
        view.inkColor = color
        if view.strokes != strokes {
            view.strokes = strokes
            view.needsDisplay = true
        }
        view.onChange = { strokes = $0 }
    }
}

final class SignaturePadView: NSView {
    var strokes: [[CGPoint]] = []
    var inkColor: NSColor = .black {
        didSet { needsDisplay = true }
    }
    var onChange: (([[CGPoint]]) -> Void)?

    override var isFlipped: Bool { false }

    override func mouseDown(with event: NSEvent) {
        strokes.append([convert(event.locationInWindow, from: nil)])
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !strokes.isEmpty else { return }
        strokes[strokes.count - 1].append(convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        onChange?(strokes)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.secondaryLabelColor.withAlphaComponent(0.4).setStroke()
        let baseline = NSBezierPath()
        baseline.move(to: NSPoint(x: 24, y: 40))
        baseline.line(to: NSPoint(x: bounds.maxX - 24, y: 40))
        baseline.lineWidth = 1
        baseline.stroke()

        inkColor.setStroke()
        for stroke in strokes where !stroke.isEmpty {
            let path = NSBezierPath()
            path.lineWidth = 2.5
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: stroke[0])
            if stroke.count == 1 { path.line(to: NSPoint(x: stroke[0].x + 0.5, y: stroke[0].y)) }
            for point in stroke.dropFirst() { path.line(to: point) }
            path.stroke()
        }
    }
}
