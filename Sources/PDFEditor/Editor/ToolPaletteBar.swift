import AppKit
import PDFEditorCore
import PDFKit
import SwiftUI

/// Tool buttons, style controls and actions for the current mode.
@MainActor
struct ToolPaletteBar: View {
    @Bindable var controller: EditorController

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(controller.mode.tools) { tool in
                    ToolButton(tool: tool, isSelected: controller.tool == tool) {
                        controller.tool = tool
                        if tool == .addImage { controller.pendingImage = controller.chooseImage() }
                        if tool == .signature, controller.signatureStore.signatures.isEmpty { controller.sheet = .newSignature }
                    }
                }
                if !controller.mode.tools.isEmpty {
                    Divider().frame(height: 22).padding(.horizontal, 6)
                }
                StyleControls(controller: controller)
                Spacer(minLength: 16)
                ModeActions(controller: controller)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(.bar)
        .controlSize(.small)
    }
}

struct ToolButton: View {
    let tool: Tool
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: tool.systemImage)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
        .help(tool.title)
        .accessibilityLabel(tool.title)
    }
}

/// Color, width and font controls for the active tool.
@MainActor
struct StyleControls: View {
    @Bindable var controller: EditorController

    private func colorBinding(_ member: WritableKeyPath<AnnotationStyle, NSColor>) -> Binding<Color> {
        let controller = controller
        return Binding(
            get: { Color(nsColor: controller.style[keyPath: member]) },
            set: { newValue in
                var style = controller.style
                style[keyPath: member] = NSColor(newValue)
                controller.style = style
            }
        )
    }

    var body: some View {
        let tool = controller.tool
        HStack(spacing: 8) {
            if tool.usesHighlightColor || tool == .highlighterPen {
                ColorPicker("Color", selection: colorBinding(\.highlightColor), supportsOpacity: false)
                    .labelsHidden()
                    .help("Highlight color")
                ForEach([NSColor.systemYellow, .systemGreen, .systemPink, .systemBlue, .systemOrange], id: \.self) { color in
                    Button {
                        controller.style.highlightColor = color
                    } label: {
                        Circle().fill(Color(nsColor: color)).frame(width: 14, height: 14)
                            .overlay(Circle().stroke(Color.primary.opacity(0.3)))
                    }
                    .buttonStyle(.plain)
                }
            }
            if tool.usesStroke && tool != .highlighterPen {
                ColorPicker("Stroke", selection: colorBinding(\.strokeColor), supportsOpacity: false)
                    .labelsHidden()
                    .help("Stroke color")
                HStack(spacing: 2) {
                    Image(systemName: "lineweight")
                    Slider(value: $controller.style.lineWidth, in: 0.5...12)
                        .frame(width: 70)
                    Text(String(format: "%.1f", controller.style.lineWidth))
                        .monospacedDigit()
                        .frame(width: 26)
                }
                .help("Line width")
            }
            if tool.usesFill {
                Toggle("Fill", isOn: Binding(
                    get: { controller.style.fillColor != nil },
                    set: { controller.style.fillColor = $0 ? NSColor.systemYellow.withAlphaComponent(0.3) : nil }
                ))
                .toggleStyle(.checkbox)
                if controller.style.fillColor != nil {
                    ColorPicker("Fill", selection: Binding(
                        get: { Color(nsColor: controller.style.fillColor ?? .clear) },
                        set: { controller.style.fillColor = NSColor($0) }
                    ))
                    .labelsHidden()
                }
            }
            if [.rectangle, .oval, .line, .arrow].contains(tool) {
                Toggle("Dashed", isOn: $controller.style.dashed).toggleStyle(.checkbox)
            }
            if tool.usesFont {
                Picker("Font", selection: $controller.style.fontName) {
                    ForEach(["Helvetica", "Helvetica-Bold", "Times-Roman", "Times-Bold", "Courier", "Georgia", "Avenir Next", "Menlo"], id: \.self) {
                        Text($0).tag($0)
                    }
                }
                .labelsHidden()
                .frame(width: 130)
                Stepper(value: $controller.style.fontSize, in: 6...96, step: 1) {
                    Text("\(Int(controller.style.fontSize)) pt").monospacedDigit()
                }
                ColorPicker("Text", selection: colorBinding(\.textColor), supportsOpacity: false)
                    .labelsHidden()
                    .help("Text color")
            }
            if [.pen, .rectangle, .oval, .line, .arrow, .textBox].contains(tool) {
                HStack(spacing: 2) {
                    Image(systemName: "circle.lefthalf.filled")
                    Slider(value: $controller.style.opacity, in: 0.1...1)
                        .frame(width: 60)
                }
                .help("Opacity")
            }
            if tool == .stamp {
                StampPicker(controller: controller)
            }
            if tool == .signature {
                SignaturePicker(controller: controller)
            }
            if tool == .measure {
                Picker("Unit", selection: $controller.measureUnit) {
                    ForEach(AnnotationFactory.MeasureUnit.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 60)
                TextField("Scale", value: Binding<Double>(get: { Double(controller.measureScale) }, set: { controller.measureScale = CGFloat($0) }),
                          format: .number)
                    .frame(width: 50)
                    .help("Drawing scale, e.g. 100 for 1:100")
            }
            if tool == .addImage {
                Button("Choose Image…") { controller.pendingImage = controller.chooseImage() }
            }
            if tool == .editText {
                Text("Click a line of text to edit it")
                    .foregroundStyle(.secondary)
            }
            if tool == .crop {
                Text("Drag over the area to keep")
                    .foregroundStyle(.secondary)
                Button("Crop Options…") { controller.sheet = .crop }
            }
        }
    }
}

@MainActor
struct StampPicker: View {
    @Bindable var controller: EditorController

    var body: some View {
        Menu {
            ForEach(AnnotationFactory.standardStamps, id: \.self) { name in
                Button(name) {
                    controller.selectedStampName = name
                    controller.customStampText = ""
                }
            }
            Divider()
            Button("Date Stamp") {
                controller.customStampText = "APPROVED " + Date().formatted(date: .abbreviated, time: .omitted)
            }
            Button("Paid") { controller.customStampText = "PAID" }
            Button("Received") { controller.customStampText = "RECEIVED " + Date().formatted(date: .numeric, time: .omitted) }
        } label: {
            Text(controller.customStampText.isEmpty ? controller.selectedStampName : controller.customStampText)
        }
        .frame(maxWidth: 180)
        TextField("Custom stamp text", text: $controller.customStampText)
            .frame(width: 140)
        ColorPicker("Stamp color", selection: Binding(
            get: { Color(nsColor: controller.style.strokeColor) },
            set: { controller.style.strokeColor = NSColor($0) }
        ))
        .labelsHidden()
    }
}

@MainActor
struct SignaturePicker: View {
    @Bindable var controller: EditorController

    var body: some View {
        let _ = controller.signaturesRevision
        let signatures = controller.signatureStore.signatures
        Menu {
            ForEach(signatures) { signature in
                Button {
                    controller.selectedSignatureID = signature.id
                } label: {
                    Label { Text(signature.name) } icon: { Image(nsImage: signature.previewImage(size: CGSize(width: 60, height: 20))) }
                }
            }
            if !signatures.isEmpty { Divider() }
            Button("New Signature…") { controller.sheet = .newSignature }
            if let selected = signatures.first(where: { $0.id == controller.selectedSignatureID }) {
                Button("Delete \"\(selected.name)\"", role: .destructive) {
                    controller.signatureStore.remove(id: selected.id)
                    controller.selectedSignatureID = nil
                    controller.signaturesRevision += 1
                }
            }
        } label: {
            if let selected = signatures.first(where: { $0.id == controller.selectedSignatureID }) ?? signatures.first {
                Image(nsImage: selected.previewImage(size: CGSize(width: 90, height: 22)))
            } else {
                Text("No Signature")
            }
        }
        .frame(maxWidth: 160)
        Text("Click on the page to sign")
            .foregroundStyle(.secondary)
    }
}

/// Buttons for whole-document actions in the current mode.
@MainActor
struct ModeActions: View {
    @Bindable var controller: EditorController

    var body: some View {
        HStack(spacing: 6) {
            switch controller.mode {
            case .read:
                Menu {
                    Picker("Theme", selection: $controller.readingTheme) {
                        ForEach(ReadingTheme.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Theme", systemImage: "circle.lefthalf.filled")
                }
                .fixedSize()
                Button("Read Aloud", systemImage: controller.isSpeaking ? "speaker.slash" : "speaker.wave.2") {
                    controller.toggleReadAloud()
                }
                Button("Slideshow", systemImage: "play.rectangle") { controller.startPresentation() }
                Button("Add Bookmark", systemImage: "bookmark") { controller.addBookmark() }
            case .comment:
                Button("Flatten", systemImage: "square.3.layers.3d.down.right") {
                    controller.flatten(pages: PageRange.all(controller.pageCount))
                }
                .help("Burn all annotations into the pages")
            case .edit:
                Button("Watermark", systemImage: "drop") { controller.sheet = .watermark }
                Button("Header & Footer", systemImage: "text.append") { controller.sheet = .headerFooter }
                Button("Background", systemImage: "square.fill.on.square") { controller.sheet = .background }
            case .pages:
                EmptyView()
            case .forms:
                Button("Detect Fields", systemImage: "wand.and.stars") { controller.detectFormFields() }
                Button("Reset", systemImage: "arrow.counterclockwise") { controller.resetForm() }
                Menu {
                    Button("Import Data (JSON)…") { controller.importFormData() }
                    Divider()
                    Button("Export as JSON…") { controller.exportFormData(asCSV: false) }
                    Button("Export as CSV…") { controller.exportFormData(asCSV: true) }
                } label: {
                    Label("Data", systemImage: "square.and.arrow.up.on.square")
                }
                .fixedSize()
            case .protect:
                Button("Find & Mark…", systemImage: "text.magnifyingglass") { controller.sheet = .redactSearch }
                Button("Apply Redactions", systemImage: "eye.slash.fill") { confirmRedaction() }
                Button("Password", systemImage: "lock") { controller.sheet = .security }
            }
        }
        .labelStyle(.titleAndIcon)
    }

    private func confirmRedaction() {
        let alert = NSAlert()
        alert.messageText = "Apply redactions?"
        alert.informativeText = "Marked areas are removed permanently. Affected pages are converted to images, and their remaining text is restored with OCR so it stays searchable. You can undo until you close the document."
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            controller.applyRedactions()
        }
    }
}
