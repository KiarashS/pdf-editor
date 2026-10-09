import AppKit
import PDFEditorCore
import SwiftUI
import UniformTypeIdentifiers

/// Applies one operation to many files.
@MainActor
struct BatchView: View {
    enum Kind: String, CaseIterable, Identifiable {
        case convert, compress, encrypt, removePassword, watermark, ocr, flatten, pageNumbers, merge, print
        var id: String { rawValue }

        var title: String {
            switch self {
            case .convert: return "Convert"
            case .compress: return "Compress"
            case .encrypt: return "Add Password"
            case .removePassword: return "Remove Password"
            case .watermark: return "Watermark"
            case .ocr: return "OCR"
            case .flatten: return "Flatten"
            case .pageNumbers: return "Page Numbers"
            case .merge: return "Combine"
            case .print: return "Print"
            }
        }
    }

    @State private var files: [URL] = []
    @State private var selection = Set<URL>()
    @State private var kind: Kind = .convert
    @State private var format: ConversionFormat = .word
    @State private var level: PageOperations.CompressionLevel = .optimized
    @State private var password = ""
    @State private var watermarkText = "CONFIDENTIAL"
    @State private var outputFolder: URL?
    @State private var progress: Double?
    @State private var results: [BatchResult] = []

    private var operation: BatchOperation {
        switch kind {
        case .convert: return .convert(format)
        case .compress: return .compress(level)
        case .encrypt: return .encrypt(password: password)
        case .removePassword: return .removePassword(password: password)
        case .watermark: return .watermark(text: watermarkText)
        case .ocr: return .ocr
        case .flatten: return .flatten
        case .pageNumbers: return .pageNumbers
        case .merge: return .merge
        case .print: return .print
        }
    }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                List(selection: $selection) {
                    ForEach(files, id: \.self) { url in
                        Label(url.lastPathComponent, systemImage: "doc.richtext").tag(url)
                    }
                    .onMove { files.move(fromOffsets: $0, toOffset: $1) }
                }
                .overlay {
                    if files.isEmpty {
                        ContentUnavailableView("Add Files", systemImage: "tray.and.arrow.down",
                                               description: Text("Drop PDFs, images or documents here."))
                    }
                }
                .dropDestination(for: URL.self) { urls, _ in
                    add(urls)
                    return true
                }
                Divider()
                HStack {
                    Button("Add Files…", systemImage: "plus") { chooseFiles() }
                    Button("Remove", systemImage: "minus") {
                        files.removeAll { selection.contains($0) }
                        selection = []
                    }
                    .disabled(selection.isEmpty)
                    Spacer()
                    Text("\(files.count) files").foregroundStyle(.secondary)
                }
                .labelStyle(.iconOnly)
                .padding(8)
            }
            .frame(minWidth: 280)

            Form {
                Section("Operation") {
                    Picker("Action", selection: $kind) {
                        ForEach(Kind.allCases) { Text($0.title).tag($0) }
                    }
                    switch kind {
                    case .convert:
                        Picker("Format", selection: $format) {
                            ForEach(ConversionFormat.allCases) { Text($0.title).tag($0) }
                        }
                    case .compress:
                        Picker("Quality", selection: $level) {
                            ForEach(PageOperations.CompressionLevel.allCases) { Text($0.title).tag($0) }
                        }
                    case .encrypt, .removePassword:
                        SecureField("Password", text: $password)
                    case .watermark:
                        TextField("Watermark text", text: $watermarkText)
                    default:
                        EmptyView()
                    }
                }
                Section("Output") {
                    LabeledContent("Folder", value: outputFolder?.path ?? "Not chosen")
                    Button("Choose Folder…") { chooseFolder() }
                }
                Section {
                    if let progress {
                        ProgressView(value: progress)
                    }
                    Button("Run \(kind.title)") { run() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(files.isEmpty || (outputFolder == nil && kind != .print) || progress != nil
                                  || ([.encrypt, .removePassword].contains(kind) && password.isEmpty))
                }
                if !results.isEmpty {
                    Section("Results") {
                        ForEach(results) { result in
                            HStack {
                                Image(systemName: result.error == nil ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                    .foregroundStyle(result.error == nil ? .green : .red)
                                VStack(alignment: .leading) {
                                    Text(result.input.lastPathComponent)
                                    if let error = result.error {
                                        Text(error).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if !result.outputs.isEmpty {
                                    Button("Show") { NSWorkspace.shared.activateFileViewerSelecting(result.outputs) }
                                }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 380)
        }
    }

    private func add(_ urls: [URL]) {
        for url in urls where !files.contains(url) {
            files.append(url)
        }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .image, .rtf, .plainText, .html]
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { add(panel.urls) }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK { outputFolder = panel.url }
    }

    private func run() {
        let inputs = files
        let operation = operation
        let folder = outputFolder ?? FileManager.default.temporaryDirectory
        results = []
        progress = 0
        if operation == .print {
            // Printing has to happen on the main thread.
            results = BatchProcessor(operation: operation, outputFolder: folder).run(inputs)
            progress = nil
            return
        }
        Task {
            let processed = await Task.detached(priority: .userInitiated) { () -> [BatchResult] in
                BatchProcessor(operation: operation, outputFolder: folder).run(inputs) { done, total in
                    Task { @MainActor in progress = Double(done) / Double(max(total, 1)) }
                }
            }.value
            results = processed
            progress = nil
        }
    }
}
