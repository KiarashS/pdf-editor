import AppKit
import PDFEditorCore
import PDFKit
import UniformTypeIdentifiers

extension EditorController {
    /// Indexes the page tools act on: the organizer selection in Pages mode,
    /// otherwise the current page.
    var targetPages: IndexSet {
        if mode == .pages, !organizerSelection.isEmpty { return IndexSet(organizerSelection) }
        return IndexSet(integer: currentPageIndex)
    }

    // MARK: Generic undo helpers

    /// Registers undo for operations that replaced pages (watermarks, OCR, flattening, ...).
    func registerPageReplacement(_ name: String, replaced: [Int: PDFPage]) {
        guard !replaced.isEmpty else {
            documentChanged()
            return
        }
        registerUndo(name) { controller in
            var redo: [Int: PDFPage] = [:]
            for (index, page) in replaced {
                if let current = controller.document.replacePage(at: index, with: page) { redo[index] = current }
            }
            controller.registerPageReplacement(name, replaced: redo)
        }
    }

    /// Rearranges the document so its pages appear in `order`.
    func reorder(to order: [PDFPage], actionName: String) {
        let previous = document.pages
        guard previous != order else { return }
        for (target, page) in order.enumerated() {
            let current = document.index(for: page)
            if current != NSNotFound, current != target {
                document.exchangePage(at: target, withPageAt: current)
            }
        }
        registerUndo(actionName) { $0.reorder(to: previous, actionName: actionName) }
    }

    func insert(_ pages: [PDFPage], at index: Int, actionName: String) {
        guard !pages.isEmpty else { return }
        var position = min(max(index, 0), document.pageCount)
        for page in pages {
            document.insert(page, at: position)
            position += 1
        }
        registerUndo(actionName) { controller in
            let indexes = IndexSet(pages.map { controller.document.index(for: $0) }.filter { $0 != NSNotFound })
            controller.deletePages(indexes, actionName: actionName)
        }
        organizerSelection = Set(index..<(index + pages.count))
    }

    // MARK: Page operations

    func deletePages(_ indexes: IndexSet, actionName: String = "Delete Pages") {
        guard !indexes.isEmpty else { return }
        guard indexes.count < document.pageCount else {
            alertMessage = "A document needs at least one page."
            return
        }
        let removed = indexes.sorted().compactMap { index in document.page(at: index).map { (index, $0) } }
        for (index, _) in removed.reversed() { document.removePage(at: index) }
        organizerSelection = []
        registerUndo(actionName) { controller in
            for (index, page) in removed { controller.document.insert(page, at: index) }
            controller.registerUndo(actionName) { $0.deletePages(IndexSet(removed.map(\.0)), actionName: actionName) }
        }
    }

    func rotatePages(_ indexes: IndexSet, by degrees: Int) {
        for index in indexes {
            guard let page = document.page(at: index) else { continue }
            page.rotation = ((page.rotation + degrees) % 360 + 360) % 360
        }
        registerUndo(degrees > 0 ? "Rotate Right" : "Rotate Left") { $0.rotatePages(indexes, by: -degrees) }
    }

    func duplicatePages(_ indexes: IndexSet) {
        let copies = indexes.compactMap { document.page(at: $0)?.copy() as? PDFPage }
        insert(copies, at: (indexes.last ?? currentPageIndex) + 1, actionName: "Duplicate Pages")
    }

    /// Moves pages so the first moved page lands before the page currently at `destination`.
    func movePages(_ indexes: IndexSet, to destination: Int) {
        var order = document.pages
        let moving = indexes.sorted().map { order[$0] }
        let adjusted = destination - indexes.filter { $0 < destination }.count
        order.removeAll { page in moving.contains { $0 === page } }
        order.insert(contentsOf: moving, at: min(max(adjusted, 0), order.count))
        reorder(to: order, actionName: "Move Pages")
        organizerSelection = Set(moving.map { document.index(for: $0) })
    }

    func reversePages(_ indexes: IndexSet) {
        var order = document.pages
        let sorted = indexes.sorted()
        let reversed = sorted.reversed().map { order[$0] }
        for (slot, page) in zip(sorted, reversed) { order[slot] = page }
        reorder(to: order, actionName: "Reverse Pages")
    }

    func insertBlankPage(at index: Int, size: CGSize, count: Int = 1) {
        let pages = (0..<max(count, 1)).compactMap { _ in PageCompositor.blankPage(size: size) }
        insert(pages, at: index, actionName: "Insert Blank Page")
    }

    /// Inserts pages from PDF, image or text files.
    func insertFiles(at index: Int) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .image, .rtf, .plainText, .html]
        panel.allowsMultipleSelection = true
        panel.message = "Choose files to insert"
        guard panel.runModal() == .OK else { return }
        insertFiles(panel.urls, at: index)
    }

    func insertFiles(_ urls: [URL], at index: Int) {
        var pages: [PDFPage] = []
        for url in urls {
            guard let source = openAsPDF(url) else { continue }
            pages += source.pages.compactMap { $0.copy() as? PDFPage }
        }
        insert(pages, at: index, actionName: "Insert Pages")
    }

    func openAsPDF(_ url: URL) -> PDFDocument? {
        let type = UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .pdf) == true {
            guard let source = PDFDocument(url: url) else { return nil }
            if source.isLocked {
                guard let password = promptForPassword(fileName: url.lastPathComponent), source.unlock(withPassword: password) else { return nil }
            }
            return source
        }
        if type?.conforms(to: .image) == true {
            return PDFConverter.pdf(fromImages: [url], paperSize: nil)
        }
        return try? PDFConverter.pdf(fromTextFile: url)
    }

    func promptForPassword(fileName: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "\"\(fileName)\" is password protected"
        alert.informativeText = "Enter its password to continue."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Unlock")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    /// Replaces the selected pages with pages from another file.
    func replacePages(_ indexes: IndexSet) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .image]
        panel.message = "Choose the replacement pages"
        guard panel.runModal() == .OK, let url = panel.url, let source = openAsPDF(url) else { return }
        var replaced: [Int: PDFPage] = [:]
        for (ordinal, index) in indexes.enumerated() {
            guard let newPage = source.page(at: ordinal)?.copy() as? PDFPage else { break }
            if let old = document.replacePage(at: index, with: newPage, transferAnnotations: false) { replaced[index] = old }
        }
        registerPageReplacement("Replace Pages", replaced: replaced)
    }

    func extractPages(_ indexes: IndexSet, deleteAfter: Bool = false) {
        guard !indexes.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(documentTitle) pages \(PageRange.format(indexes)).pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try DocumentExporter.export(document)
            guard let copy = PDFDocument(data: data) else { throw ExportError.serializationFailed }
            guard copy.extractDocument(pages: indexes).write(to: url) else { throw ExportError.serializationFailed }
            if deleteAfter { deletePages(indexes, actionName: "Extract Pages") }
        } catch {
            report(error)
        }
    }

    enum SplitMode: Hashable {
        case everyPages(Int)
        case ranges(String)
        case bookmarks
        case fileCount(Int)
    }

    /// Splits the document into files in a folder the user chooses.
    func split(_ mode: SplitMode) {
        let groups: [IndexSet]
        do {
            switch mode {
            case .everyPages(let size):
                groups = PageRange.chunks(pageCount: pageCount, size: max(size, 1))
            case .fileCount(let count):
                let size = Int((Double(pageCount) / Double(max(count, 1))).rounded(.up))
                groups = PageRange.chunks(pageCount: pageCount, size: max(size, 1))
            case .ranges(let text):
                groups = try text.split(separator: ";").map { try PageRange.parse(String($0), pageCount: pageCount) }
            case .bookmarks:
                groups = bookmarkGroups()
            }
        } catch {
            report(error)
            return
        }
        guard !groups.isEmpty else {
            alertMessage = "Nothing to split."
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Split Here"
        panel.message = "Choose a folder for the \(groups.count) new files"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            let data = try DocumentExporter.export(document)
            guard let copy = PDFDocument(data: data) else { throw ExportError.serializationFailed }
            for (number, group) in groups.enumerated() {
                let url = folder.appendingPathComponent("\(documentTitle) part \(number + 1).pdf")
                guard copy.extractDocument(pages: group).write(to: url) else { throw ExportError.serializationFailed }
            }
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } catch {
            report(error)
        }
    }

    /// Page ranges starting at each top-level bookmark.
    func bookmarkGroups() -> [IndexSet] {
        guard let root = document.outlineRoot else { return [] }
        var starts: [Int] = []
        for i in 0..<root.numberOfChildren {
            guard let page = root.child(at: i)?.destination?.page else { continue }
            let index = document.index(for: page)
            if index != NSNotFound { starts.append(index) }
        }
        starts = Array(Set(starts)).sorted()
        guard !starts.isEmpty else { return [] }
        if starts[0] != 0 { starts.insert(0, at: 0) }
        return starts.enumerated().map { offset, start in
            let end = offset + 1 < starts.count ? starts[offset + 1] : pageCount
            return IndexSet(integersIn: start..<end)
        }
    }

    // MARK: Cropping

    func cropPages(_ indexes: IndexSet, margins: NSEdgeInsets) {
        let previous = PageOperations.crop(document, pages: indexes, margins: margins)
        registerCropUndo(previous)
    }

    /// Crops pages to a rectangle drawn on one page (page space).
    func cropPages(_ indexes: IndexSet, to rect: CGRect) {
        var previous: [Int: CGRect] = [:]
        for index in indexes {
            guard let page = document.page(at: index) else { continue }
            previous[index] = page.bounds(for: .cropBox)
            page.setBounds(rect.intersection(page.bounds(for: .mediaBox)), for: .cropBox)
        }
        registerCropUndo(previous)
    }

    private func registerCropUndo(_ previous: [Int: CGRect]) {
        guard !previous.isEmpty else { return }
        registerUndo("Crop Pages") { controller in
            var redo: [Int: CGRect] = [:]
            for (index, rect) in previous {
                guard let page = controller.document.page(at: index) else { continue }
                redo[index] = page.bounds(for: .cropBox)
                page.setBounds(rect, for: .cropBox)
            }
            controller.registerCropUndo(redo)
        }
        pdfView?.layoutDocumentView()
    }

    // MARK: Page decorations

    func applyWatermark(_ options: WatermarkOptions, pages: IndexSet) {
        let replaced = PageDecorator.applyWatermark(options, to: document, pages: pages)
        registerPageReplacement("Add Watermark", replaced: replaced)
    }

    func applyHeaderFooter(_ options: HeaderFooterOptions, pages: IndexSet) {
        var options = options
        options.fileName = fileURL?.lastPathComponent ?? documentTitle
        options.title = documentTitle
        let replaced = PageDecorator.applyHeaderFooter(options, to: document, pages: pages)
        registerPageReplacement("Header & Footer", replaced: replaced)
    }

    func applyBackground(_ options: BackgroundOptions, pages: IndexSet) {
        let replaced = PageDecorator.applyBackground(options, to: document, pages: pages)
        registerPageReplacement("Add Background", replaced: replaced)
    }

    func flatten(pages: IndexSet) {
        let replaced = PageOperations.flatten(document, pages: pages)
        selectedAnnotation = nil
        registerPageReplacement("Flatten", replaced: replaced)
    }

    // MARK: Long-running work

    /// Runs OCR page by page; Vision runs off the main thread.
    func runOCR(pages: IndexSet, options: OCROptions) async {
        var replaced: [Int: PDFPage] = [:]
        let total = pages.count
        progress = ProgressState(title: "Recognizing text…", fraction: 0)
        defer { progress = nil }
        for (ordinal, index) in pages.enumerated() {
            progress?.fraction = Double(ordinal) / Double(max(total, 1))
            progress?.title = "Recognizing text on page \(index + 1)…"
            guard let page = document.page(at: index) else { continue }
            if options.skipPagesWithText, (page.string?.trimmingCharacters(in: .whitespacesAndNewlines).count ?? 0) > 20 { continue }
            guard let image = PageRenderer.cgImage(for: page, dpi: options.dpi, includeAnnotations: false) else { continue }
            do {
                let lines = try await Task.detached(priority: .userInitiated) {
                    try OCRService.recognize(image: image, options: options)
                }.value
                guard !lines.isEmpty,
                      let newPage = OCRService.searchablePage(from: page, lines: lines, imageSize: PageGeometry.displaySize(of: page)),
                      let old = document.replacePage(at: index, with: newPage) else { continue }
                replaced[index] = old
            } catch {
                report(error)
                break
            }
        }
        registerPageReplacement("Recognize Text", replaced: replaced)
        if replaced.isEmpty {
            alertMessage = "No pages needed OCR. Pages that already contain text are skipped unless you turn that option off."
        }
    }

    /// Saves a compressed copy chosen by the user.
    func saveCompressedCopy(level: PageOperations.CompressionLevel, keepSearchable: Bool) async {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = documentTitle + " compressed.pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        progress = ProgressState(title: "Compressing…", fraction: nil)
        defer { progress = nil }
        do {
            let base = try DocumentExporter.export(document)
            let security = fileDocument.exportOptions.security
            let data = try await Task.detached(priority: .userInitiated) { () -> Data in
                guard let copy = PDFDocument(data: base) else { throw ExportError.serializationFailed }
                return try PageOperations.compressedData(copy, level: level, security: security,
                                                         ocr: keepSearchable ? OCROptions() : nil)
            }.value
            try data.write(to: url)
            let before = ByteCountFormatter.string(fromByteCount: Int64(base.count), countStyle: .file)
            let after = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
            alertMessage = "Saved \(url.lastPathComponent): \(before) → \(after)."
        } catch {
            report(error)
        }
    }

    /// Estimated compressed size, for the compress sheet.
    func estimateCompressedSize(level: PageOperations.CompressionLevel) async -> (before: Int, after: Int)? {
        guard let base = try? DocumentExporter.export(document) else { return nil }
        let after = try? await Task.detached(priority: .utility) { () -> Int in
            guard let copy = PDFDocument(data: base) else { return base.count }
            return try PageOperations.compressedData(copy, level: level).count
        }.value
        guard let after else { return nil }
        return (base.count, after)
    }

    func convert(to format: ConversionFormat, options: ConversionOptions) async {
        let panel = NSSavePanel()
        if let type = UTType(filenameExtension: format == .image ? options.imageFormat.fileExtension : format.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        let ext = format == .image ? options.imageFormat.fileExtension : format.fileExtension
        panel.nameFieldStringValue = "\(documentTitle).\(ext)"
        if format == .image, (options.pages?.count ?? pageCount) > 1 {
            panel.message = "One image per page will be saved, numbered after this name."
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        progress = ProgressState(title: "Converting to \(format.title)…", fraction: nil)
        defer { progress = nil }
        do {
            let base = try DocumentExporter.export(document)
            let urls = try await Task.detached(priority: .userInitiated) { () -> [URL] in
                guard let copy = PDFDocument(data: base) else { throw ExportError.serializationFailed }
                return try PDFConverter.convert(copy, to: format, destination: url, options: options)
            }.value
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        } catch {
            report(error)
        }
    }

    /// Saves a copy with annotations burned in and optional encryption.
    func saveFlattenedCopy() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = documentTitle + " flattened.pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            var options = fileDocument.exportOptions
            options.flattenAnnotations = true
            try DocumentExporter.export(document, options: options).write(to: url)
        } catch {
            report(error)
        }
    }
}
