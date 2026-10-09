import XCTest
@testable import PDFEditorCore

final class PageRangeTests: XCTestCase {
    func testParsesRangesAndKeywords() throws {
        XCTAssertEqual(Array(try PageRange.parse("1-3, 5, 8-", pageCount: 10)), [0, 1, 2, 4, 7, 8, 9])
        XCTAssertEqual(Array(try PageRange.parse("odd", pageCount: 5)), [0, 2, 4])
        XCTAssertEqual(Array(try PageRange.parse("even", pageCount: 5)), [1, 3])
        XCTAssertEqual(Array(try PageRange.parse("-2, last", pageCount: 5)), [0, 1, 4])
        XCTAssertEqual(Array(try PageRange.parse("all", pageCount: 3)), [0, 1, 2])
        XCTAssertEqual(Array(try PageRange.parse("4-2", pageCount: 5)), [1, 2, 3])
    }

    func testRejectsInvalidInput() {
        XCTAssertThrowsError(try PageRange.parse("0", pageCount: 3))
        XCTAssertThrowsError(try PageRange.parse("4", pageCount: 3))
        XCTAssertThrowsError(try PageRange.parse("abc", pageCount: 3))
        XCTAssertThrowsError(try PageRange.parse("", pageCount: 3))
    }

    func testFormatsCompactly() {
        XCTAssertEqual(PageRange.format(IndexSet([0, 1, 2, 4, 7, 8, 9])), "1-3, 5, 8-10")
    }

    func testChunks() {
        XCTAssertEqual(PageRange.chunks(pageCount: 5, size: 2).map(Array.init), [[0, 1], [2, 3], [4]])
    }
}

final class TextDiffTests: XCTestCase {
    func testReconstructsBothSides() throws {
        let old = TextDiff.tokenize("the quick brown fox jumps")
        let new = TextDiff.tokenize("the slow brown fox leaps high")
        let operations = try XCTUnwrap(TextDiff.diff(old, new))
        var rebuiltOld: [String] = []
        var rebuiltNew: [String] = []
        for operation in operations {
            switch operation {
            case .equal(let o, let n):
                rebuiltOld.append(old[o].text)
                rebuiltNew.append(new[n].text)
            case .delete(let o):
                rebuiltOld.append(old[o].text)
            case .insert(let n):
                rebuiltNew.append(new[n].text)
            }
        }
        XCTAssertEqual(rebuiltOld, old.map(\.text))
        XCTAssertEqual(rebuiltNew, new.map(\.text))
        let hunks = TextDiff.hunks(from: operations)
        XCTAssertTrue(hunks.contains { $0.kind == .deleted })
        XCTAssertTrue(hunks.contains { $0.kind == .inserted })
    }

    func testTokenRangesPointIntoSource() {
        let text = "alpha  beta\ngamma"
        let tokens = TextDiff.tokenize(text)
        XCTAssertEqual(tokens.map(\.text), ["alpha", "beta", "gamma"])
        XCTAssertEqual((text as NSString).substring(with: tokens[1].range), "beta")
    }

    func testComparatorReportsChange() {
        let changes = DocumentComparator.compare(oldText: "Total due: 100 dollars", oldPage: 0,
                                                 newText: "Total due: 250 dollars", newPage: 0)
        XCTAssertEqual(changes.filter { $0.kind == .deleted }.map(\.text), ["100"])
        XCTAssertEqual(changes.filter { $0.kind == .inserted }.map(\.text), ["250"])
    }
}

final class OfficeWriterTests: XCTestCase {
    func testCRC32() {
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926)
    }

    func testZipHasSignatures() {
        var zip = ZipWriter()
        zip.addFile(path: "a.txt", string: "hello")
        let data = zip.finalize()
        XCTAssertEqual(Array(data.prefix(4)), [0x50, 0x4B, 0x03, 0x04])
        XCTAssertTrue(data.range(of: Data([0x50, 0x4B, 0x05, 0x06])) != nil)
    }

    func testColumnNames() {
        XCTAssertEqual(XLSXWriter.columnName(0), "A")
        XCTAssertEqual(XLSXWriter.columnName(25), "Z")
        XCTAssertEqual(XLSXWriter.columnName(26), "AA")
        XCTAssertEqual(XLSXWriter.columnName(701), "ZZ")
    }

    func testWorksheetEscapesAndTypesCells() {
        let xml = XLSXWriter.worksheetXML(rows: [["A & B", "1,200.50", ""]])
        XCTAssertTrue(xml.contains("A &amp; B"))
        XCTAssertTrue(xml.contains("<v>1200.5</v>"))
    }

    func testSheetNamesAreUniqueAndValid() {
        var used = Set<String>()
        XCTAssertEqual(XLSXWriter.sanitizedSheetName("Page 1", used: &used), "Page 1")
        XCTAssertEqual(XLSXWriter.sanitizedSheetName("Page 1", used: &used), "Page 1 (2)")
        XCTAssertEqual(XLSXWriter.sanitizedSheetName("a/b:c", used: &used), "abc")
    }
}

final class ClaudeClientTests: XCTestCase {
    func testParsesTextDeltas() throws {
        let parser = ClaudeSSEParser()
        let line = #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}"#
        XCTAssertEqual(try parser.parse(line: line), .textDelta("Hello"))
        XCTAssertNil(try parser.parse(line: "event: content_block_delta"))
        XCTAssertNil(try parser.parse(line: #"data: {"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":""}}"#))
        XCTAssertEqual(try parser.parse(line: #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#), .stopped(reason: "end_turn"))
    }

    func testSurfacesErrorsAndRefusals() {
        let parser = ClaudeSSEParser()
        XCTAssertThrowsError(try parser.parse(line: #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#))
        XCTAssertThrowsError(try parser.parse(line: #"data: {"type":"message_delta","delta":{"stop_reason":"refusal"}}"#)) { error in
            guard case ClaudeError.refused = error else { return XCTFail("Expected refusal, got \(error)") }
        }
    }

    func testRequestShape() throws {
        let client = ClaudeClient(configuration: ClaudeConfiguration(apiKey: "test-key"))
        let request = try client.makeRequest(system: "sys", messages: [
            ClaudeMessage(role: .user, content: [.textDocument("doc", title: "T", cache: true), .text("Summarize")]),
        ])
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "test-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual((body["thinking"] as? [String: Any])?["type"] as? String, "adaptive")
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["type"] as? String, "document")
        XCTAssertNotNil(content.first?["cache_control"])
    }

    func testMissingKeyFails() {
        let client = ClaudeClient(configuration: ClaudeConfiguration(apiKey: " "))
        XCTAssertThrowsError(try client.makeRequest(system: nil, messages: [.user("hi")]))
    }

    func testChatSessionAttachesDocumentOnce() {
        let session = DocumentChatSession(documentBlock: .textDocument("doc", title: nil, cache: true))
        let first = session.messagesForNewTurn("Q1")
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first[0].content.count, 2)
        session.commit(userText: "Q1", reply: "A1")
        let second = session.messagesForNewTurn("Q2")
        XCTAssertEqual(second.count, 3)
        XCTAssertEqual(second[2].content, [.text("Q2")])
    }
}
