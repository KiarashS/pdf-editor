import AppKit
import PDFEditorCore
import PDFKit
import SwiftUI

@MainActor
struct InspectorView: View {
    @Bindable var controller: EditorController

    var body: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: $controller.inspectorTab) {
                ForEach(InspectorTab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()
            switch controller.inspectorTab {
            case .properties:
                if let annotation = controller.selectedAnnotation {
                    AnnotationInspector(controller: controller, annotation: annotation)
                        .id(ObjectIdentifier(annotation))
                } else {
                    ToolDefaultsInspector(controller: controller)
                }
            case .document:
                DocumentInspector(controller: controller)
            case .assistant:
                AssistantPanel(controller: controller)
            }
        }
    }
}

/// Properties of the selected annotation. Every edit goes through the
/// controller so it can be undone.
@MainActor
struct AnnotationInspector: View {
    let controller: EditorController
    let annotation: PDFAnnotation
    @State private var contents = ""
    @State private var urlText = ""
    @State private var fieldName = ""
    @State private var choicesText = ""

    var body: some View {
        let _ = controller.revision
        Form {
            Section {
                LabeledContent("Type", value: annotation.displayName)
                if let page = annotation.page {
                    LabeledContent("Page", value: "\(controller.document.index(for: page) + 1)")
                }
                if let author = annotation.userName, !author.isEmpty {
                    LabeledContent("Author", value: author)
                }
            }

            if let text = annotation as? TextReplacementAnnotation {
                Section("Edited Text") {
                    Text(text.text).lineLimit(4)
                    Button("Edit Text…") {
                        controller.beginTextEdit(at: CGPoint(x: text.bounds.midX, y: text.bounds.midY), on: text.page!)
                    }
                }
            } else if let image = annotation as? ImageOverlayAnnotation {
                Section("Image") {
                    slider("Opacity", value: image.imageOpacity, range: 0.05...1) { value in
                        controller.modify(image, actionName: "Opacity") { ($0 as? ImageOverlayAnnotation)?.imageOpacity = value }
                    }
                    Stepper("Rotation \(Int(image.imageRotation))°", value: Binding(
                        get: { image.imageRotation },
                        set: { value in controller.modify(image, actionName: "Rotate Image") { ($0 as? ImageOverlayAnnotation)?.imageRotation = value } }
                    ), in: -180...180, step: 15)
                    Button("Replace Image…") {
                        if let newImage = controller.chooseImage() {
                            let old = image.image
                            image.image = newImage
                            controller.refresh(image)
                            controller.registerUndo("Replace Image") { c in image.image = old; c.refresh(image) }
                        }
                    }
                    Text("Images are merged into the page when the document is saved.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if annotation.isSubtype(.widget) {
                widgetSection
            } else if annotation.isSubtype(.link) {
                Section("Link") {
                    TextField("URL", text: $urlText)
                        .onSubmit {
                            guard let url = URL(string: urlText) else { return }
                            controller.modify(annotation, actionName: "Edit Link") { $0.url = url }
                        }
                    if let page = annotation.destination?.page {
                        LabeledContent("Goes to page", value: "\(controller.document.index(for: page) + 1)")
                    }
                }
            } else {
                appearanceSection
                if annotation.isSubtype(.freeText) || annotation.isSubtype(.text) || annotation.isSubtype(.highlight)
                    || annotation.isSubtype(.square) || annotation.isSubtype(.circle) || annotation.isSubtype(.ink)
                    || annotation.isSubtype(.underline) || annotation.isSubtype(.strikeOut) || annotation.isSubtype(.line) {
                    Section(annotation.isSubtype(.freeText) ? "Text" : "Comment") {
                        TextEditor(text: $contents)
                            .font(.body)
                            .frame(minHeight: 90)
                        Button("Apply") {
                            controller.modify(annotation, actionName: "Edit Text") { $0.contents = contents }
                        }
                        .disabled(contents == (annotation.contents ?? ""))
                    }
                }
            }

            Section {
                HStack {
                    Button("Duplicate") { controller.duplicateSelectedAnnotation() }
                    Spacer()
                    Button("Delete", role: .destructive) { controller.remove([annotation]) }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            contents = annotation.contents ?? ""
            urlText = annotation.url?.absoluteString ?? ""
            fieldName = annotation.fieldName ?? ""
            choicesText = (annotation.choices ?? []).joined(separator: "\n")
        }
    }

    @ViewBuilder
    private var appearanceSection: some View {
        Section("Appearance") {
            ColorPicker("Color", selection: Binding(
                get: { Color(nsColor: annotation.color) },
                set: { color in controller.modify(annotation, actionName: "Color") { $0.color = NSColor(color) } }
            ))
            if annotation.isSubtype(.square) || annotation.isSubtype(.circle) || annotation.isSubtype(.line) {
                ColorPicker("Fill", selection: Binding(
                    get: { Color(nsColor: annotation.interiorColor ?? .clear) },
                    set: { color in controller.modify(annotation, actionName: "Fill") { $0.interiorColor = NSColor(color) } }
                ))
            }
            if annotation.isSubtype(.square) || annotation.isSubtype(.circle) || annotation.isSubtype(.line)
                || annotation.isSubtype(.ink) || annotation.isSubtype(.freeText) {
                slider("Line width", value: annotation.border?.lineWidth ?? 1, range: 0...12) { value in
                    controller.modify(annotation, actionName: "Line Width") { annotation in
                        let border = annotation.border ?? PDFBorder()
                        border.lineWidth = value
                        annotation.border = border
                    }
                }
            }
            if annotation.isSubtype(.freeText) {
                ColorPicker("Text color", selection: Binding(
                    get: { Color(nsColor: annotation.fontColor ?? .black) },
                    set: { color in controller.modify(annotation, actionName: "Text Color") { $0.fontColor = NSColor(color) } }
                ))
                Stepper("Font size \(Int(annotation.font?.pointSize ?? 12)) pt", value: Binding(
                    get: { annotation.font?.pointSize ?? 12 },
                    set: { size in
                        controller.modify(annotation, actionName: "Font Size") { annotation in
                            annotation.font = NSFont(name: annotation.font?.fontName ?? "Helvetica", size: size) ?? .systemFont(ofSize: size)
                        }
                    }
                ), in: 6...96)
                Picker("Alignment", selection: Binding(
                    get: { annotation.alignment },
                    set: { value in controller.modify(annotation, actionName: "Alignment") { $0.alignment = value } }
                )) {
                    Text("Left").tag(NSTextAlignment.left)
                    Text("Center").tag(NSTextAlignment.center)
                    Text("Right").tag(NSTextAlignment.right)
                }
                Button("Fit Box to Text") {
                    var style = AnnotationStyle()
                    if let font = annotation.font {
                        style.fontName = font.fontName
                        style.fontSize = font.pointSize
                    }
                    let size = AnnotationFactory.fittingSize(for: annotation.contents ?? "", style: style)
                    controller.modify(annotation, actionName: "Resize") {
                        $0.bounds = CGRect(x: $0.bounds.minX, y: $0.bounds.maxY - size.height, width: size.width, height: size.height)
                    }
                }
            }
            if annotation.isSubtype(.text) {
                Picker("Icon", selection: Binding(
                    get: { annotation.iconType },
                    set: { value in controller.modify(annotation, actionName: "Note Icon") { $0.iconType = value } }
                )) {
                    Text("Comment").tag(PDFTextAnnotationIconType.comment)
                    Text("Note").tag(PDFTextAnnotationIconType.note)
                    Text("Key").tag(PDFTextAnnotationIconType.key)
                    Text("Help").tag(PDFTextAnnotationIconType.help)
                    Text("Paragraph").tag(PDFTextAnnotationIconType.paragraph)
                    Text("Insert").tag(PDFTextAnnotationIconType.insert)
                }
            }
        }
    }

    @ViewBuilder
    private var widgetSection: some View {
        Section("Form Field") {
            TextField("Name", text: $fieldName)
                .onSubmit { controller.modify(annotation, actionName: "Rename Field") { $0.fieldName = fieldName } }
            Toggle("Read only", isOn: Binding(
                get: { annotation.isReadOnly },
                set: { value in controller.modify(annotation, actionName: "Read Only") { $0.isReadOnly = value } }
            ))
            if annotation.widgetFieldType == .text {
                Toggle("Multiple lines", isOn: Binding(
                    get: { annotation.isMultiline },
                    set: { value in controller.modify(annotation, actionName: "Multiline") { $0.isMultiline = value } }
                ))
                LabeledContent("Value", value: annotation.widgetStringValue ?? "")
            }
            if annotation.widgetFieldType == .choice {
                VStack(alignment: .leading) {
                    Text("Options (one per line)").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $choicesText).frame(minHeight: 80)
                    Button("Update Options") {
                        let options = choicesText.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        controller.modify(annotation, actionName: "Field Options") { $0.choices = options }
                    }
                }
            }
            if annotation.widgetControlType == .radioButtonControl {
                Text("Radio buttons with the same name form a group.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ColorPicker("Background", selection: Binding(
                get: { Color(nsColor: annotation.backgroundColor ?? .clear) },
                set: { color in controller.modify(annotation, actionName: "Field Background") { $0.backgroundColor = NSColor(color) } }
            ))
        }
    }

    private func slider(_ title: String, value: CGFloat, range: ClosedRange<CGFloat>, onCommit: @escaping (CGFloat) -> Void) -> some View {
        SliderRow(title: title, initial: value, range: range, onCommit: onCommit)
    }
}

/// A slider that applies its value when the drag ends, producing one undo step.
struct SliderRow: View {
    let title: String
    let initial: CGFloat
    let range: ClosedRange<CGFloat>
    let onCommit: (CGFloat) -> Void
    @State private var value: CGFloat = 0

    var body: some View {
        LabeledContent(title) {
            Slider(value: $value, in: range) { editing in
                if !editing { onCommit(value) }
            }
        }
        .onAppear { value = initial }
    }
}

/// Defaults used for new annotations when nothing is selected.
@MainActor
struct ToolDefaultsInspector: View {
    @Bindable var controller: EditorController

    var body: some View {
        Form {
            Section("New annotations") {
                ColorPicker("Stroke", selection: Binding(
                    get: { Color(nsColor: controller.style.strokeColor) },
                    set: { controller.style.strokeColor = NSColor($0) }
                ))
                ColorPicker("Highlight", selection: Binding(
                    get: { Color(nsColor: controller.style.highlightColor) },
                    set: { controller.style.highlightColor = NSColor($0) }
                ))
                LabeledContent("Line width") {
                    Slider(value: $controller.style.lineWidth, in: 0.5...12)
                }
                LabeledContent("Opacity") {
                    Slider(value: $controller.style.opacity, in: 0.1...1)
                }
                Stepper("Font size \(Int(controller.style.fontSize)) pt", value: $controller.style.fontSize, in: 6...96)
            }
            Section {
                Text("Select an annotation to edit its properties. Use the arrow keys to nudge it and Delete to remove it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Metadata, page information and security.
@MainActor
struct DocumentInspector: View {
    @Bindable var controller: EditorController
    @State private var metadata = DocumentMetadata()

    var body: some View {
        let _ = controller.revision
        let document = controller.document
        Form {
            Section("Properties") {
                TextField("Title", text: $metadata.title)
                TextField("Author", text: $metadata.author)
                TextField("Subject", text: $metadata.subject)
                TextField("Keywords", text: $metadata.keywords)
                TextField("Creator", text: $metadata.creator)
                Button("Save Properties") { controller.updateMetadata(metadata) }
                    .disabled(metadata == DocumentMetadata(document: document))
            }
            Section("Information") {
                LabeledContent("Pages", value: "\(document.pageCount)")
                if let page = controller.currentPage {
                    let size = PageGeometry.displaySize(of: page)
                    LabeledContent("Page size", value: String(format: "%.0f × %.0f pt (%.1f × %.1f in)", size.width, size.height, size.width / 72, size.height / 72))
                    LabeledContent("Rotation", value: "\(page.rotation)°")
                }
                LabeledContent("PDF version", value: "\(document.majorVersion).\(document.minorVersion)")
                if let url = controller.fileURL,
                   let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    LabeledContent("File size", value: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                }
                if let producer = document.documentAttributes?[PDFDocumentAttribute.producerAttribute] as? String {
                    LabeledContent("Producer", value: producer)
                }
                if let created = document.documentAttributes?[PDFDocumentAttribute.creationDateAttribute] as? Date {
                    LabeledContent("Created", value: created.formatted(date: .abbreviated, time: .shortened))
                }
                LabeledContent("Form fields", value: "\(FormFields.widgets(in: document).count)")
                LabeledContent("Annotations", value: "\(document.allAnnotations().count)")
            }
            Section("Security") {
                LabeledContent("Open password", value: controller.security.openPassword.isEmpty ? "None" : "Set")
                LabeledContent("Printing", value: controller.security.allowsPrinting ? "Allowed" : "Not allowed")
                LabeledContent("Copying", value: controller.security.allowsCopying ? "Allowed" : "Not allowed")
                Button("Change…") { controller.sheet = .security }
            }
        }
        .formStyle(.grouped)
        .onAppear { metadata = DocumentMetadata(document: document) }
        .onChange(of: controller.revision) { metadata = DocumentMetadata(document: controller.document) }
    }
}
