import AppKit
import PDFKit
import XCTest
@testable import PDFEditorCore

/// Builds small text PDFs for tests.
enum Fixtures {
    static func document(pages texts: [String], fontSize: CGFloat = 24) -> PDFDocument {
        let result = PDFDocument()
        for text in texts {
            let attributed = NSAttributedString(string: text, attributes: [.font: NSFont(name: "Helvetica", size: fontSize)!])
            let single = PDFConverter.pdf(fromAttributedString: attributed)
            if let page = single.page(at: 0) { result.insert(page, at: result.pageCount) }
        }
        return result
    }

    static func temporaryURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
    }
}

final class PDFOperationTests: XCTestCase {
    func testFixtureHasText() {
        let document = Fixtures.document(pages: ["Hello World", "Second page"])
        XCTAssertEqual(document.pageCount, 2)
        XCTAssertTrue(document.page(at: 0)?.string?.contains("Hello World") ?? false)
    }

    func testReplacePageMovesAnnotationsAndBookmarks() throws {
        let document = Fixtures.document(pages: ["One", "Two"])
        let page = try XCTUnwrap(document.page(at: 1))
        let note = AnnotationFactory.note(at: CGPoint(x: 100, y: 100), text: "hi", color: .yellow)
        page.addAnnotation(note)
        let root = PDFOutline()
        document.outlineRoot = root
        let item = PDFOutline()
        item.destination = PDFDestination(page: page, at: .zero)
        root.insertChild(item, at: 0)

        let replacement = try XCTUnwrap(PageCompositor.compose(page))
        let old = document.replacePage(at: 1, with: replacement)
        XCTAssertTrue(old === page)
        XCTAssertTrue(document.page(at: 1) === replacement)
        XCTAssertEqual(replacement.annotations.filter { !$0.isSubtype(.popup) }.count, 1)
        XCTAssertTrue(document.outlineRoot?.child(at: 0)?.destination?.page === replacement)
        XCTAssertTrue(replacement.string?.contains("Two") ?? false, "Composed page keeps its text")
    }

    func testWatermarkKeepsTextAndAddsWatermark() {
        let document = Fixtures.document(pages: ["Body text"])
        var options = WatermarkOptions()
        options.content = .text("DRAFTMARK")
        let replaced = PageDecorator.applyWatermark(options, to: document, pages: IndexSet(integer: 0))
        XCTAssertEqual(replaced.count, 1)
        let text = document.page(at: 0)?.string ?? ""
        XCTAssertTrue(text.contains("Body text"))
        XCTAssertTrue(text.contains("DRAFTMARK"))
    }

    func testHeaderFooterAndBates() {
        let document = Fixtures.document(pages: ["A", "B", "C"])
        var options = HeaderFooterOptions()
        options.footerCenter = "Page {page} of {pages}"
        options.footerRight = "{bates}"
        options.batesPrefix = "ABC"
        options.batesDigits = 4
        PageDecorator.applyHeaderFooter(options, to: document, pages: PageRange.all(3))
        XCTAssertTrue(document.page(at: 1)?.string?.contains("Page 2 of 3") ?? false)
        XCTAssertTrue(document.page(at: 2)?.string?.contains("ABC0003") ?? false)
    }

    func testPasswordRoundTrip() throws {
        let document = Fixtures.document(pages: ["Secret"])
        var options = ExportOptions()
        options.security.openPassword = "s3cret"
        let data = try DocumentExporter.export(document, options: options)
        let reopened = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertTrue(reopened.isEncrypted)
        XCTAssertTrue(reopened.isLocked)
        XCTAssertFalse(reopened.unlock(withPassword: "wrong"))
        XCTAssertTrue(reopened.unlock(withPassword: "s3cret"))
        XCTAssertTrue(reopened.page(at: 0)?.string?.contains("Secret") ?? false)
    }

    func testOverlaysAreBurnedInOnExport() throws {
        let document = Fixtures.document(pages: ["Original words here"])
        let page = try XCTUnwrap(document.page(at: 0))
        // Placed in an empty area: where it overlaps old glyphs, text extraction mixes both.
        let rect = CGRect(x: 72, y: 200, width: 200, height: 30)
        let replacement = TextReplacementAnnotation(bounds: rect, text: "Edited",
                                                    font: .systemFont(ofSize: 20), textColor: .black, coverColor: .white)
        page.addAnnotation(replacement)
        let image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        page.addAnnotation(ImageOverlayAnnotation(image: image, bounds: CGRect(x: 50, y: 50, width: 40, height: 40)))

        let data = try DocumentExporter.export(document)
        // The live document is untouched.
        XCTAssertEqual(page.overlayAnnotations.count, 2)
        let saved = try XCTUnwrap(PDFDocument(data: data)?.page(at: 0))
        XCTAssertTrue(saved.annotations.isEmpty)
        XCTAssertTrue(saved.string?.contains("Edited") ?? false)
    }

    func testRedactionRemovesText() throws {
        let document = Fixtures.document(pages: ["Public part. TOPSECRET value."])
        let marks = PageOperations.occurrences(of: "TOPSECRET", in: document)
        XCTAssertEqual(marks[0]?.count, 1)
        let replaced = PageOperations.redact(document, marks: marks, ocr: nil)
        XCTAssertEqual(replaced.count, 1)
        let text = document.page(at: 0)?.string ?? ""
        XCTAssertFalse(text.contains("TOPSECRET"))
        let data = try DocumentExporter.export(document)
        let reopened = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertFalse(reopened.string?.contains("TOPSECRET") ?? false)
    }

    func testFlattenRemovesAnnotations() throws {
        let document = Fixtures.document(pages: ["Flatten me"])
        let page = try XCTUnwrap(document.page(at: 0))
        var style = AnnotationStyle()
        style.strokeColor = .blue
        page.addAnnotation(AnnotationFactory.shape(.rectangle, rect: CGRect(x: 20, y: 20, width: 100, height: 60), style: style))
        page.addAnnotation(AnnotationFactory.link(rect: CGRect(x: 10, y: 10, width: 30, height: 10), url: URL(string: "https://example.com")!))
        PageOperations.flatten(document, pages: IndexSet(integer: 0))
        let flattened = try XCTUnwrap(document.page(at: 0))
        XCTAssertEqual(flattened.annotations.count, 1, "Only the link survives")
        XCTAssertTrue(flattened.annotations[0].isSubtype(.link))
    }

    func testCropUsesDisplayMargins() throws {
        let document = Fixtures.document(pages: ["Crop"])
        let page = try XCTUnwrap(document.page(at: 0))
        let media = page.bounds(for: .mediaBox)
        PageOperations.crop(document, pages: IndexSet(integer: 0), margins: NSEdgeInsets(top: 10, left: 20, bottom: 30, right: 40))
        let crop = page.bounds(for: .cropBox)
        XCTAssertEqual(crop.minX, media.minX + 20, accuracy: 0.01)
        XCTAssertEqual(crop.minY, media.minY + 30, accuracy: 0.01)
        XCTAssertEqual(crop.maxX, media.maxX - 40, accuracy: 0.01)
        XCTAssertEqual(crop.maxY, media.maxY - 10, accuracy: 0.01)

        page.rotation = 90
        page.setBounds(media, for: .cropBox)
        PageOperations.crop(document, pages: IndexSet(integer: 0), margins: NSEdgeInsets(top: 10, left: 0, bottom: 0, right: 0))
        // The top edge of a page rotated 90° clockwise is its left edge in page space.
        XCTAssertEqual(page.bounds(for: .cropBox).minX, media.minX + 10, accuracy: 0.01)
    }

    func testDisplayTransformRoundTrip() throws {
        let page = try XCTUnwrap(Fixtures.document(pages: ["x"]).page(at: 0))
        for rotation in [0, 90, 180, 270] {
            page.rotation = rotation
            let rect = CGRect(x: 30, y: 40, width: 50, height: 20)
            let back = PageGeometry.pageRect(for: PageGeometry.displayRect(for: rect, on: page), on: page)
            XCTAssertEqual(back.minX, rect.minX, accuracy: 0.01)
            XCTAssertEqual(back.minY, rect.minY, accuracy: 0.01)
            XCTAssertEqual(back.width, rect.width, accuracy: 0.01)
        }
    }

    func testMarkupAnnotationsPerLine() throws {
        let document = Fixtures.document(pages: ["First line\nSecond line"])
        let selection = try XCTUnwrap(document.findString("line\nSecond", withOptions: []).first
                                      ?? document.page(at: 0)?.selection(for: NSRange(location: 0, length: 20)))
        let created = AnnotationFactory.markup(.highlight, selection: selection, color: .yellow)
        XCTAssertGreaterThanOrEqual(created.count, 1)
        XCTAssertTrue(created.allSatisfy { $0.1.isSubtype(.highlight) })
    }

    func testInkPathsAreRelativeToBounds() throws {
        let ink = try XCTUnwrap(AnnotationFactory.ink(strokes: [[CGPoint(x: 100, y: 100), CGPoint(x: 150, y: 120)]], color: .black, lineWidth: 2))
        let path = try XCTUnwrap(ink.paths?.first)
        XCTAssertLessThan(path.bounds.minX, 20, "Path coordinates start near the annotation origin")
        XCTAssertTrue(ink.bounds.contains(CGPoint(x: 100, y: 100)))
    }

    func testFormFieldValuesRoundTrip() throws {
        let document = Fixtures.document(pages: ["Form"])
        let page = try XCTUnwrap(document.page(at: 0))
        let text = FormFields.make(.textField, rect: CGRect(x: 50, y: 50, width: 150, height: 22), name: "Name")
        let check = FormFields.make(.checkbox, rect: CGRect(x: 50, y: 90, width: 16, height: 16), name: "Agree")
        page.addAnnotation(text)
        page.addAnnotation(check)
        FormFields.apply(["Name": "Ada", "Agree": "Yes"], to: document)
        let values = FormFields.values(in: document)
        let diagnostics = FormFields.widgets(in: document).map { item in
            "\(item.annotation.type ?? "nil") field=\(item.annotation.widgetFieldType.rawValue) control=\(item.annotation.widgetControlType.rawValue) name=\(item.annotation.fieldName ?? "nil")"
        }
        XCTAssertEqual(FormFields.widgets(in: document).count, 2, "\(page.annotations.map { $0.type ?? "nil" }) \(diagnostics)")
        XCTAssertEqual(values["Name"], "Ada")
        XCTAssertEqual(values["Agree"], "Yes")
        FormFields.reset(document)
        XCTAssertEqual(FormFields.values(in: document)["Agree"], "Off")
        XCTAssertEqual(FormFields.uniqueName(for: .textField, in: document), "Text Field 1")
    }

    func testMetadataRoundTrip() {
        let document = Fixtures.document(pages: ["Meta"])
        var metadata = DocumentMetadata()
        metadata.title = "Report"
        metadata.author = "Ada"
        metadata.keywords = "alpha, beta"
        metadata.apply(to: document)
        let read = DocumentMetadata(document: document)
        XCTAssertEqual(read.title, "Report")
        XCTAssertEqual(read.author, "Ada")
        XCTAssertEqual(read.keywords, "alpha, beta")
    }

    func testOptimizedCompressionProducesValidPDF() throws {
        let document = Fixtures.document(pages: ["Compress", "Me"])
        let data = try PageOperations.compressedData(document, level: .optimized)
        XCTAssertEqual(PDFDocument(data: data)?.pageCount, 2)
        let small = try PageOperations.compressedData(document, level: .small)
        XCTAssertEqual(PDFDocument(data: small)?.pageCount, 2)
    }

    func testExtractAndInsertPages() {
        let document = Fixtures.document(pages: ["1", "2", "3"])
        let extracted = document.extractDocument(pages: IndexSet([0, 2]))
        XCTAssertEqual(extracted.pageCount, 2)
        XCTAssertEqual(document.pageCount, 3)
        let inserted = document.insertPages(from: extracted, at: 1)
        XCTAssertEqual(inserted.count, 2)
        XCTAssertEqual(document.pageCount, 5)
    }
}

final class ConversionTests: XCTestCase {
    func testConvertsToEveryFormat() throws {
        let document = Fixtures.document(pages: ["Name    Qty    Price\nApple    3    1.50\nPear    5    2.00", "Second page"])
        for format in ConversionFormat.allCases {
            let url = Fixtures.temporaryURL(format.fileExtension)
            let written = try PDFConverter.convert(document, to: format, destination: url)
            XCTAssertFalse(written.isEmpty, "\(format)")
            for file in written {
                let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
                XCTAssertGreaterThan(size, 0, "\(format) wrote an empty file")
            }
        }
    }

    func testWordOutputIsZipWithText() throws {
        let document = Fixtures.document(pages: ["Convert me to Word"])
        let url = Fixtures.temporaryURL("docx")
        try PDFConverter.convert(document, to: .word, destination: url)
        let data = try Data(contentsOf: url)
        XCTAssertEqual(Array(data.prefix(2)), [0x50, 0x4B])
        let roundTrip = try NSAttributedString(url: url, options: [:], documentAttributes: nil)
        XCTAssertTrue(roundTrip.string.contains("Convert me to Word"))
    }

    func testTableExtractionFindsColumns() throws {
        let document = Fixtures.document(pages: ["Name          Qty\nApple          3\nPear          5"], fontSize: 14)
        let rows = TableExtractor.rows(on: document.page(at: 0))
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.first?.first, "Name")
        XCTAssertEqual(rows.last?.last, "5")
    }

    func testImagesToPDF() throws {
        let image = NSImage(size: NSSize(width: 200, height: 100), flipped: false) { rect in
            NSColor.blue.setFill()
            rect.fill()
            return true
        }
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let url = Fixtures.temporaryURL("tiff")
        try tiff.write(to: url)
        let document = PDFConverter.pdf(fromImages: [url, url], paperSize: .a4, margin: 36)
        XCTAssertEqual(document.pageCount, 2)
        let size = try XCTUnwrap(document.page(at: 0)).bounds(for: .mediaBox).size
        XCTAssertEqual(size.width, PaperSize.a4.size.height, accuracy: 1, "Landscape image gets a landscape page")
    }

    func testOCRMakesRasterPageSearchable() throws {
        let document = Fixtures.document(pages: ["Recognize this sentence please"], fontSize: 36)
        // Rasterize first so the page has no text layer.
        let page = try XCTUnwrap(document.page(at: 0))
        let image = try XCTUnwrap(PageRenderer.cgImage(for: page, dpi: 200, includeAnnotations: false))
        let raster = try XCTUnwrap(PageCompositor.imagePage(image, like: page))
        document.replacePage(at: 0, with: raster)
        XCTAssertTrue((document.page(at: 0)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        let replaced = try OCRService.makeSearchable(document, pages: IndexSet(integer: 0), options: OCROptions())
        XCTAssertEqual(replaced.count, 1)
        let text = document.page(at: 0)?.string ?? ""
        XCTAssertTrue(text.localizedCaseInsensitiveContains("sentence"), "OCR text: \(text)")
    }

    func testBatchMergeAndConvert() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let a = folder.appendingPathComponent("a.pdf")
        let b = folder.appendingPathComponent("b.pdf")
        XCTAssertTrue(Fixtures.document(pages: ["A1", "A2"]).write(to: a))
        XCTAssertTrue(Fixtures.document(pages: ["B1"]).write(to: b))

        let merged = BatchProcessor(operation: .merge, outputFolder: folder).run([a, b])
        let output = try XCTUnwrap(merged.first?.outputs.first)
        XCTAssertEqual(PDFDocument(url: output)?.pageCount, 3)

        let converted = BatchProcessor(operation: .convert(.text), outputFolder: folder).run([a])
        XCTAssertNil(converted.first?.error)
        let text = try String(contentsOf: XCTUnwrap(converted.first?.outputs.first), encoding: .utf8)
        XCTAssertTrue(text.contains("A2"))
    }
}
