import AppKit
import PDFEditorCore
import PDFKit
import SwiftUI

/// Presents the sheet for an `EditorSheet`.
@MainActor
struct SheetHost: View {
    let controller: EditorController
    let sheet: EditorSheet

    var body: some View {
        switch sheet {
        case .watermark: WatermarkSheet(controller: controller)
        case .headerFooter: HeaderFooterSheet(controller: controller)
        case .background: BackgroundSheet(controller: controller)
        case .security: SecuritySheet(controller: controller)
        case .compress: CompressSheet(controller: controller)
        case .convert: ConvertSheet(controller: controller)
        case .ocr: OCRSheet(controller: controller)
        case .crop: CropSheet(controller: controller)
        case .split: SplitSheet(controller: controller)
        case .insertBlank: InsertBlankSheet(controller: controller)
        case .link(let page, let rect): LinkSheet(controller: controller, page: page, rect: rect)
        case .textEdit(let request): TextEditSheet(controller: controller, request: request)
        case .newSignature: SignatureCreatorSheet(controller: controller)
        case .redactSearch: RedactSearchSheet(controller: controller)
        case .measureSettings: EmptyView()
        }
    }
}

/// Common sheet chrome: title, content and Cancel / confirm buttons.
struct SheetContainer<Content: View>: View {
    let title: String
    let confirmTitle: String
    var confirmDisabled = false
    let onConfirm: () -> Void
    @ViewBuilder let content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.headline)
                .padding([.horizontal, .top], 20)
                .padding(.bottom, 8)
            Form { content }
                .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle) {
                    onConfirm()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(confirmDisabled)
            }
            .padding(16)
        }
        .frame(minWidth: 480)
    }
}

/// "All pages / current page / custom range" chooser.
struct PageRangePicker: View {
    enum Choice: String, CaseIterable, Identifiable {
        case all, current, selection, custom
        var id: String { rawValue }
    }

    @Binding var choice: Choice
    @Binding var custom: String
    let pageCount: Int
    let hasSelection: Bool

    var body: some View {
        Picker("Pages", selection: $choice) {
            Text("All pages").tag(Choice.all)
            Text("Current page").tag(Choice.current)
            if hasSelection { Text("Selected pages").tag(Choice.selection) }
            Text("Custom").tag(Choice.custom)
        }
        if choice == .custom {
            TextField("Range, e.g. 1-3, 5, 8-", text: $custom)
            if (try? PageRange.parse(custom, pageCount: pageCount)) == nil, !custom.isEmpty {
                Text("Enter page numbers between 1 and \(pageCount).").font(.caption).foregroundStyle(.red)
            }
        }
    }

    static func resolve(_ choice: Choice, custom: String, controller: EditorController) -> IndexSet? {
        switch choice {
        case .all: return PageRange.all(controller.pageCount)
        case .current: return IndexSet(integer: controller.currentPageIndex)
        case .selection: return IndexSet(controller.organizerSelection)
        case .custom: return try? PageRange.parse(custom, pageCount: controller.pageCount)
        }
    }
}

extension EditorController {
    var defaultRangeChoice: PageRangePicker.Choice {
        mode == .pages && organizerSelection.count > 1 ? .selection : .all
    }
}

// MARK: Watermark

@MainActor
struct WatermarkSheet: View {
    let controller: EditorController
    @State private var options = WatermarkOptions()
    @State private var text = "CONFIDENTIAL"
    @State private var useImage = false
    @State private var image: NSImage?
    @State private var color = Color.red
    @State private var range: PageRangePicker.Choice = .all
    @State private var custom = ""

    var body: some View {
        SheetContainer(title: "Add Watermark", confirmTitle: "Apply", confirmDisabled: useImage && image == nil, onConfirm: apply) {
            Section {
                Picker("Type", selection: $useImage) {
                    Text("Text").tag(false)
                    Text("Image").tag(true)
                }
                .pickerStyle(.segmented)
                if useImage {
                    HStack {
                        Button("Choose Image…") { image = controller.chooseImage() }
                        if let image {
                            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(height: 40)
                        }
                    }
                    LabeledContent("Size") { Slider(value: $options.imageScale, in: 0.05...1) }
                } else {
                    TextField("Text", text: $text)
                    Picker("Font", selection: $options.fontName) {
                        ForEach(["Helvetica-Bold", "Helvetica", "Times-Bold", "Georgia-Bold", "Courier-Bold", "AvenirNext-Heavy"], id: \.self) { Text($0).tag($0) }
                    }
                    Stepper("Size \(Int(options.fontSize)) pt", value: $options.fontSize, in: 8...200, step: 4)
                    ColorPicker("Color", selection: $color, supportsOpacity: false)
                }
            }
            Section {
                LabeledContent("Opacity \(Int(options.opacity * 100))%") { Slider(value: $options.opacity, in: 0.05...1) }
                LabeledContent("Rotation \(Int(options.rotation))°") { Slider(value: $options.rotation, in: -90...90, step: 5) }
                Toggle("Tile across the page", isOn: $options.tiled)
                if !options.tiled {
                    Picker("Position", selection: $options.anchor) {
                        ForEach(PageGeometry.Anchor.allCases) { anchor in
                            Text(anchor.id.replacingOccurrences(of: "-", with: " ").capitalized).tag(anchor)
                        }
                    }
                }
                Toggle("Place behind page content", isOn: $options.behindContent)
            }
            Section {
                PageRangePicker(choice: $range, custom: $custom, pageCount: controller.pageCount, hasSelection: controller.organizerSelection.count > 1)
            }
        }
        .onAppear { range = controller.defaultRangeChoice }
    }

    private func apply() {
        guard let pages = PageRangePicker.resolve(range, custom: custom, controller: controller) else { return }
        var options = options
        options.color = NSColor(color)
        options.content = useImage ? .image(image ?? NSImage()) : .text(text)
        controller.applyWatermark(options, pages: pages)
    }
}

// MARK: Header & footer

@MainActor
struct HeaderFooterSheet: View {
    let controller: EditorController
    @State private var options = HeaderFooterOptions()
    @State private var color = Color.black
    @State private var range: PageRangePicker.Choice = .all
    @State private var custom = ""

    var body: some View {
        SheetContainer(title: "Header, Footer & Bates Numbering", confirmTitle: "Apply", confirmDisabled: options.isEmpty, onConfirm: apply) {
            Section("Header") {
                TextField("Left", text: $options.headerLeft)
                TextField("Center", text: $options.headerCenter)
                TextField("Right", text: $options.headerRight)
            }
            Section("Footer") {
                TextField("Left", text: $options.footerLeft)
                TextField("Center", text: $options.footerCenter)
                TextField("Right", text: $options.footerRight)
                Text("Tokens: {page} {pages} {date} {bates} {filename} {title}")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Page X of Y") { options.footerCenter = "Page {page} of {pages}" }
                    Button("Bates Number") { options.footerRight = "{bates}" }
                    Button("Date") { options.headerRight = "{date}" }
                }
                .controlSize(.small)
            }
            Section("Format") {
                Stepper("Font size \(Int(options.fontSize)) pt", value: $options.fontSize, in: 6...36)
                ColorPicker("Color", selection: $color, supportsOpacity: false)
                Stepper("Start numbering at \(options.startNumber)", value: $options.startNumber, in: 0...100_000)
                LabeledContent("Margin") { Slider(value: $options.verticalMargin, in: 8...72) }
            }
            Section("Bates") {
                TextField("Prefix", text: $options.batesPrefix)
                TextField("Suffix", text: $options.batesSuffix)
                Stepper("First number \(options.batesStart)", value: $options.batesStart, in: 0...10_000_000)
                Stepper("Digits \(options.batesDigits)", value: $options.batesDigits, in: 1...12)
                Text("Example: " + options.expand("{bates}", ordinal: 0, totalPages: controller.pageCount))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                PageRangePicker(choice: $range, custom: $custom, pageCount: controller.pageCount, hasSelection: controller.organizerSelection.count > 1)
            }
        }
        .frame(minHeight: 620)
        .onAppear { range = controller.defaultRangeChoice }
    }

    private func apply() {
        guard let pages = PageRangePicker.resolve(range, custom: custom, controller: controller) else { return }
        var options = options
        options.color = NSColor(color)
        controller.applyHeaderFooter(options, pages: pages)
    }
}

// MARK: Background

@MainActor
struct BackgroundSheet: View {
    let controller: EditorController
    @State private var options = BackgroundOptions()
    @State private var color = Color(red: 1, green: 0.98, blue: 0.9)
    @State private var useImage = false
    @State private var range: PageRangePicker.Choice = .all
    @State private var custom = ""

    var body: some View {
        SheetContainer(title: "Page Background", confirmTitle: "Apply", confirmDisabled: useImage && options.image == nil, onConfirm: apply) {
            Section {
                Picker("Type", selection: $useImage) {
                    Text("Color").tag(false)
                    Text("Image").tag(true)
                }
                .pickerStyle(.segmented)
                if useImage {
                    Button("Choose Image…") { options.image = controller.chooseImage() }
                    Toggle("Fill the page", isOn: $options.imageFillsPage)
                } else {
                    ColorPicker("Color", selection: $color, supportsOpacity: false)
                }
                LabeledContent("Opacity") { Slider(value: $options.opacity, in: 0.05...1) }
                Text("Backgrounds are drawn under the page content. Pages that paint their own white background will hide it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                PageRangePicker(choice: $range, custom: $custom, pageCount: controller.pageCount, hasSelection: controller.organizerSelection.count > 1)
            }
        }
        .onAppear { range = controller.defaultRangeChoice }
    }

    private func apply() {
        guard let pages = PageRangePicker.resolve(range, custom: custom, controller: controller) else { return }
        var options = options
        options.color = NSColor(color)
        if !useImage { options.image = nil }
        controller.applyBackground(options, pages: pages)
    }
}

// MARK: Security

@MainActor
struct SecuritySheet: View {
    let controller: EditorController
    @State private var settings = SecuritySettings()
    @State private var requireOpenPassword = false
    @State private var confirmOpen = ""
    @State private var restrict = false

    private var mismatch: Bool { requireOpenPassword && settings.openPassword != confirmOpen }
    private var restrictWithoutPassword: Bool { restrict && settings.permissionsPassword.isEmpty && settings.openPassword.isEmpty }

    var body: some View {
        SheetContainer(title: "Password & Permissions", confirmTitle: "Save Settings",
                       confirmDisabled: mismatch || (requireOpenPassword && settings.openPassword.isEmpty) || restrictWithoutPassword,
                       onConfirm: apply) {
            Section {
                Toggle("Require a password to open", isOn: $requireOpenPassword)
                if requireOpenPassword {
                    SecureField("Password", text: $settings.openPassword)
                    SecureField("Confirm", text: $confirmOpen)
                    if mismatch, !confirmOpen.isEmpty {
                        Text("Passwords do not match").font(.caption).foregroundStyle(.red)
                    }
                }
            }
            Section {
                Toggle("Restrict printing and copying", isOn: $restrict)
                if restrict {
                    SecureField("Permissions password", text: $settings.permissionsPassword)
                    Toggle("Allow printing", isOn: $settings.allowsPrinting)
                    Toggle("Allow copying text and images", isOn: $settings.allowsCopying)
                }
            }
            Section {
                Text("Settings apply when the document is saved. Files are encrypted with AES by macOS. Turn both options off to remove protection.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            settings = controller.security
            requireOpenPassword = !settings.openPassword.isEmpty
            confirmOpen = settings.openPassword
            restrict = settings.restrictsPermissions || !settings.permissionsPassword.isEmpty
        }
    }

    private func apply() {
        var result = settings
        if !requireOpenPassword { result.openPassword = "" }
        if !restrict {
            result.permissionsPassword = ""
            result.allowsPrinting = true
            result.allowsCopying = true
        }
        controller.setSecurity(result)
    }
}

// MARK: Compress

@MainActor
struct CompressSheet: View {
    let controller: EditorController
    @State private var level: PageOperations.CompressionLevel = .optimized
    @State private var keepSearchable = true
    @State private var estimate: (before: Int, after: Int)?
    @State private var estimating = false

    var body: some View {
        SheetContainer(title: "Compress PDF", confirmTitle: "Save Compressed Copy…", onConfirm: {
            let level = level
            let keep = keepSearchable
            Task { await controller.saveCompressedCopy(level: level, keepSearchable: keep) }
        }) {
            Section {
                Picker("Quality", selection: $level) {
                    ForEach(PageOperations.CompressionLevel.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                if level != .optimized {
                    Toggle("Keep text searchable (OCR)", isOn: $keepSearchable)
                }
            }
            Section {
                if estimating {
                    ProgressView("Estimating…").controlSize(.small)
                } else if let estimate {
                    LabeledContent("Current size", value: ByteCountFormatter.string(fromByteCount: Int64(estimate.before), countStyle: .file))
                    LabeledContent("Estimated size", value: ByteCountFormatter.string(fromByteCount: Int64(estimate.after), countStyle: .file))
                } else {
                    Button("Estimate Size") { runEstimate() }
                }
            }
        }
        .onChange(of: level) { estimate = nil }
    }

    private func runEstimate() {
        estimating = true
        let level = level
        Task {
            estimate = await controller.estimateCompressedSize(level: level)
            estimating = false
        }
    }
}

// MARK: Convert

@MainActor
struct ConvertSheet: View {
    let controller: EditorController
    @State private var format: ConversionFormat = .word
    @State private var options = ConversionOptions()
    @State private var range: PageRangePicker.Choice = .all
    @State private var custom = ""

    var body: some View {
        SheetContainer(title: "Convert PDF", confirmTitle: "Convert…", onConfirm: convert) {
            Section {
                Picker("Format", selection: $format) {
                    ForEach(ConversionFormat.allCases) { format in
                        Label(format.title, systemImage: format.systemImage).tag(format)
                    }
                }
                if format == .image || format == .pdfImageOnly {
                    if format == .image {
                        Picker("Image type", selection: $options.imageFormat) {
                            ForEach(PageRenderer.ImageFormat.allCases) { Text($0.rawValue.uppercased()).tag($0) }
                        }
                    }
                    Picker("Resolution", selection: $options.dpi) {
                        Text("72 dpi").tag(CGFloat(72))
                        Text("150 dpi").tag(CGFloat(150))
                        Text("300 dpi").tag(CGFloat(300))
                        Text("600 dpi").tag(CGFloat(600))
                    }
                }
                Toggle("Recognize text in scanned pages first (OCR)", isOn: $options.ocrScannedPages)
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                PageRangePicker(choice: $range, custom: $custom, pageCount: controller.pageCount, hasSelection: controller.organizerSelection.count > 1)
            }
        }
        .onAppear { range = controller.defaultRangeChoice }
    }

    private var note: String {
        switch format {
        case .word, .rtf, .openDocument, .html:
            return "Text, fonts and line breaks are kept. Complex layouts are reflowed."
        case .excel, .csv:
            return "Table rows and columns are rebuilt from text positions; each page becomes a sheet."
        case .powerpoint:
            return "Each page becomes a slide image. The page text is stored as the slide's alt text."
        case .markdown:
            return "Headings are detected from font sizes."
        case .image:
            return "One image per page."
        case .text:
            return "Plain text, pages separated by form feeds."
        case .pdfImageOnly:
            return "Every page is flattened into a single image."
        }
    }

    private func convert() {
        var options = options
        options.pages = PageRangePicker.resolve(range, custom: custom, controller: controller)
        let format = format
        Task { await controller.convert(to: format, options: options) }
    }
}

// MARK: OCR

@MainActor
struct OCRSheet: View {
    let controller: EditorController
    @State private var options = OCROptions()
    @State private var language = "auto"
    @State private var range: PageRangePicker.Choice = .all
    @State private var custom = ""
    private let languages = OCRService.supportedLanguages()

    var body: some View {
        SheetContainer(title: "Recognize Text (OCR)", confirmTitle: "Recognize", onConfirm: run) {
            Section {
                Picker("Language", selection: $language) {
                    Text("Automatic").tag("auto")
                    ForEach(languages, id: \.self) { code in
                        Text(Locale.current.localizedString(forIdentifier: code) ?? code).tag(code)
                    }
                }
                Picker("Accuracy", selection: $options.accurate) {
                    Text("Accurate").tag(true)
                    Text("Fast").tag(false)
                }
                .pickerStyle(.segmented)
                Toggle("Skip pages that already have text", isOn: $options.skipPagesWithText)
                Toggle("Language correction", isOn: $options.usesLanguageCorrection)
                Text("Adds an invisible text layer so scanned pages can be searched, selected and copied. The page image is unchanged.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                PageRangePicker(choice: $range, custom: $custom, pageCount: controller.pageCount, hasSelection: controller.organizerSelection.count > 1)
            }
        }
        .onAppear { range = controller.defaultRangeChoice }
    }

    private func run() {
        guard let pages = PageRangePicker.resolve(range, custom: custom, controller: controller) else { return }
        var options = options
        options.languages = language == "auto" ? [] : [language]
        Task { await controller.runOCR(pages: pages, options: options) }
    }
}

// MARK: Crop

@MainActor
struct CropSheet: View {
    let controller: EditorController
    @State private var top: CGFloat = 36
    @State private var left: CGFloat = 36
    @State private var bottom: CGFloat = 36
    @State private var right: CGFloat = 36
    @State private var range: PageRangePicker.Choice = .all
    @State private var custom = ""

    var body: some View {
        SheetContainer(title: "Crop Pages", confirmTitle: "Crop", onConfirm: apply) {
            Section("Margins to remove (points, 72 per inch)") {
                marginRow("Top", $top)
                marginRow("Left", $left)
                marginRow("Bottom", $bottom)
                marginRow("Right", $right)
                Button("Detect Content Margins") {
                    guard let page = controller.currentPage, let margins = PageOperations.contentMargins(of: page) else { return }
                    top = margins.top
                    left = margins.left
                    bottom = margins.bottom
                    right = margins.right
                }
                Button("Reset Crop (show full page)") {
                    top = 0; left = 0; bottom = 0; right = 0
                }
            }
            Section {
                PageRangePicker(choice: $range, custom: $custom, pageCount: controller.pageCount, hasSelection: controller.organizerSelection.count > 1)
            }
        }
        .onAppear { range = controller.defaultRangeChoice }
    }

    private func marginRow(_ title: String, _ value: Binding<CGFloat>) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: 0...300)
                TextField("", value: Binding<Double>(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = CGFloat($0) }),
                          format: .number.precision(.fractionLength(0)))
                    .frame(width: 56)
            }
        }
    }

    private func apply() {
        guard let pages = PageRangePicker.resolve(range, custom: custom, controller: controller) else { return }
        controller.cropPages(pages, margins: NSEdgeInsets(top: top, left: left, bottom: bottom, right: right))
    }
}

// MARK: Split

@MainActor
struct SplitSheet: View {
    enum Method: String, CaseIterable, Identifiable {
        case everyPages, fileCount, ranges, bookmarks
        var id: String { rawValue }
    }

    let controller: EditorController
    @State private var method: Method = .everyPages
    @State private var pagesPerFile = 1
    @State private var fileCount = 2
    @State private var ranges = "1-3; 4-6"

    var body: some View {
        SheetContainer(title: "Split Document", confirmTitle: "Choose Folder…", onConfirm: apply) {
            Section {
                Picker("Split by", selection: $method) {
                    Text("Every N pages").tag(Method.everyPages)
                    Text("Number of files").tag(Method.fileCount)
                    Text("Page ranges").tag(Method.ranges)
                    Text("Top-level bookmarks").tag(Method.bookmarks)
                }
                .pickerStyle(.radioGroup)
                switch method {
                case .everyPages:
                    Stepper("\(pagesPerFile) page(s) per file", value: $pagesPerFile, in: 1...max(controller.pageCount, 1))
                case .fileCount:
                    Stepper("\(fileCount) files", value: $fileCount, in: 2...max(controller.pageCount, 2))
                case .ranges:
                    TextField("Ranges separated by semicolons", text: $ranges)
                case .bookmarks:
                    Text("\(controller.bookmarkGroups().count) files from the document outline")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func apply() {
        let mode: EditorController.SplitMode
        switch method {
        case .everyPages: mode = .everyPages(pagesPerFile)
        case .fileCount: mode = .fileCount(fileCount)
        case .ranges: mode = .ranges(ranges)
        case .bookmarks: mode = .bookmarks
        }
        // Let the sheet close before the folder panel opens.
        DispatchQueue.main.async { MainActor.assumeIsolated { controller.split(mode) } }
    }
}

// MARK: Insert blank pages

@MainActor
struct InsertBlankSheet: View {
    let controller: EditorController
    @State private var paper: PaperSize? = nil
    @State private var count = 1
    @State private var position = 1

    var body: some View {
        SheetContainer(title: "Insert Blank Pages", confirmTitle: "Insert", onConfirm: apply) {
            Section {
                Picker("Size", selection: $paper) {
                    Text("Same as current page").tag(PaperSize?.none)
                    ForEach(PaperSize.allCases) { Text($0.title).tag(PaperSize?.some($0)) }
                }
                Stepper("\(count) page(s)", value: $count, in: 1...100)
                Stepper("Insert before page \(position)", value: $position, in: 1...(controller.pageCount + 1))
            }
        }
        .onAppear {
            position = (controller.organizerSelection.max() ?? controller.currentPageIndex) + 2
            position = min(position, controller.pageCount + 1)
        }
    }

    private func apply() {
        let size = paper?.size ?? controller.currentPage?.bounds(for: .mediaBox).size ?? PaperSize.letter.size
        controller.insertBlankPage(at: position - 1, size: size, count: count)
    }
}

// MARK: Link

@MainActor
struct LinkSheet: View {
    let controller: EditorController
    let page: PDFPage
    let rect: CGRect
    @State private var toWeb = true
    @State private var urlText = "https://"
    @State private var pageNumber = 1

    var body: some View {
        SheetContainer(title: "Add Link", confirmTitle: "Add",
                       confirmDisabled: toWeb && URL(string: urlText)?.scheme == nil, onConfirm: apply) {
            Section {
                Picker("Link to", selection: $toWeb) {
                    Text("Web page or email").tag(true)
                    Text("Page in this document").tag(false)
                }
                .pickerStyle(.segmented)
                if toWeb {
                    TextField("URL (https://… or mailto:…)", text: $urlText)
                } else {
                    Stepper("Page \(pageNumber)", value: $pageNumber, in: 1...max(controller.pageCount, 1))
                }
            }
        }
    }

    private func apply() {
        if toWeb {
            controller.addLink(on: page, rect: rect, url: URL(string: urlText), pageIndex: nil)
        } else {
            controller.addLink(on: page, rect: rect, url: nil, pageIndex: pageNumber - 1)
        }
    }
}

// MARK: Text edit

@MainActor
struct TextEditSheet: View {
    let controller: EditorController
    let request: TextEditRequest
    @State private var text = ""
    @State private var fontName = "Helvetica"
    @State private var fontSize: CGFloat = 12
    @State private var color = Color.black
    @State private var coverColor = Color.white

    private var fontNames: [String] {
        var names = ["Helvetica", "Helvetica-Bold", "Times-Roman", "Times-Bold", "Arial", "Arial-BoldMT", "Georgia", "Courier", "Menlo-Regular"]
        if !names.contains(request.font.fontName) { names.insert(request.font.fontName, at: 0) }
        return names
    }

    var body: some View {
        SheetContainer(title: "Edit Text", confirmTitle: "Replace", onConfirm: apply) {
            Section {
                TextEditor(text: $text)
                    .font(.system(size: 13))
                    .frame(minHeight: 90)
                Picker("Font", selection: $fontName) {
                    ForEach(fontNames, id: \.self) { Text($0).tag($0) }
                }
                Stepper("Size \(String(format: "%.1f", fontSize)) pt", value: $fontSize, in: 4...144, step: 0.5)
                ColorPicker("Text color", selection: $color, supportsOpacity: false)
                ColorPicker("Cover color", selection: $coverColor, supportsOpacity: false)
                Text("The original text is covered with the cover color and the new text is drawn on top. When the document is saved, both are merged into the page.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            text = request.text
            fontName = request.font.fontName
            fontSize = request.font.pointSize
            color = Color(nsColor: request.color)
            if let existing = request.existing {
                coverColor = Color(nsColor: existing.coverColor)
            } else {
                coverColor = Color(nsColor: controller.backgroundColor(around: request.rect, on: request.page))
            }
        }
    }

    private func apply() {
        let font = NSFont(name: fontName, size: fontSize) ?? .systemFont(ofSize: fontSize)
        controller.commitTextEdit(request, text: text, font: font, color: NSColor(color), coverColor: NSColor(coverColor))
    }
}

// MARK: Redaction search

@MainActor
struct RedactSearchSheet: View {
    let controller: EditorController
    @State private var text = ""
    @State private var caseSensitive = false
    @State private var preset = ""

    private let presets: [(String, String)] = [
        ("Email addresses", "[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}"),
        ("Phone numbers", "\\+?[0-9][0-9 ()\\-]{7,}[0-9]"),
        ("US SSNs", "\\b[0-9]{3}-[0-9]{2}-[0-9]{4}\\b"),
        ("Credit card numbers", "\\b(?:[0-9][ -]?){13,16}\\b"),
    ]

    var body: some View {
        SheetContainer(title: "Find & Mark for Redaction", confirmTitle: "Mark All",
                       confirmDisabled: text.isEmpty && preset.isEmpty, onConfirm: apply) {
            Section {
                TextField("Word or phrase", text: $text)
                Toggle("Match case", isOn: $caseSensitive)
            }
            Section("Or find a pattern") {
                Picker("Pattern", selection: $preset) {
                    Text("None").tag("")
                    ForEach(presets, id: \.1) { Text($0.0).tag($0.1) }
                }
            }
            Section {
                Text("Matches are marked, not removed. Review them, then click Apply Redactions.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func apply() {
        var count = 0
        if !text.isEmpty {
            count += controller.markForRedaction(text, caseSensitive: caseSensitive)
        }
        if !preset.isEmpty, let regex = try? NSRegularExpression(pattern: preset, options: [.caseInsensitive]) {
            var matches = Set<String>()
            for page in controller.document.pages {
                guard let string = page.string else { continue }
                for match in regex.matches(in: string, range: NSRange(location: 0, length: (string as NSString).length)) {
                    matches.insert((string as NSString).substring(with: match.range))
                }
            }
            for match in matches { count += controller.markForRedaction(match, caseSensitive: true) }
        }
        controller.alertMessage = count == 0 ? "No matches found." : "Marked \(count) area(s) for redaction."
    }
}
