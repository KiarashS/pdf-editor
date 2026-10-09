import Foundation
import PDFKit

/// A text difference between two documents.
public struct TextChange: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case inserted, deleted, pageAdded, pageRemoved }

    public let id = UUID()
    public let kind: Kind
    public let text: String
    /// Page index in the old document (deleted / pageRemoved) or new document (inserted / pageAdded).
    public let pageIndex: Int
    /// Character range on that page, when the change is part of a page.
    public let range: NSRange?

    public static func == (lhs: TextChange, rhs: TextChange) -> Bool {
        lhs.kind == rhs.kind && lhs.text == rhs.text && lhs.pageIndex == rhs.pageIndex && lhs.range == rhs.range
    }
}

/// Compares the text of two documents page by page.
public enum DocumentComparator {
    public static func compare(_ old: PDFDocument, _ new: PDFDocument) -> [TextChange] {
        var changes: [TextChange] = []
        let shared = min(old.pageCount, new.pageCount)
        for index in 0..<shared {
            let oldText = old.page(at: index)?.string ?? ""
            let newText = new.page(at: index)?.string ?? ""
            changes += compare(oldText: oldText, oldPage: index, newText: newText, newPage: index)
        }
        if old.pageCount > shared {
            for index in shared..<old.pageCount {
                changes.append(TextChange(kind: .pageRemoved, text: String((old.page(at: index)?.string ?? "").prefix(200)), pageIndex: index, range: nil))
            }
        }
        if new.pageCount > shared {
            for index in shared..<new.pageCount {
                changes.append(TextChange(kind: .pageAdded, text: String((new.page(at: index)?.string ?? "").prefix(200)), pageIndex: index, range: nil))
            }
        }
        return changes
    }

    public static func compare(oldText: String, oldPage: Int, newText: String, newPage: Int) -> [TextChange] {
        if oldText == newText { return [] }
        let a = TextDiff.tokenize(oldText)
        let b = TextDiff.tokenize(newText)
        guard let operations = TextDiff.diff(a, b) else {
            // Too different to align: report the whole page as replaced.
            var result: [TextChange] = []
            if !a.isEmpty { result.append(TextChange(kind: .deleted, text: oldText, pageIndex: oldPage, range: NSRange(location: 0, length: (oldText as NSString).length))) }
            if !b.isEmpty { result.append(TextChange(kind: .inserted, text: newText, pageIndex: newPage, range: NSRange(location: 0, length: (newText as NSString).length))) }
            return result
        }
        return TextDiff.hunks(from: operations).map { hunk in
            let tokens = hunk.kind == .deleted ? a : b
            let slice = tokens[hunk.tokenIndexes]
            let first = slice.first!.range
            let last = slice.last!.range
            let range = NSRange(location: first.location, length: last.location + last.length - first.location)
            let source = (hunk.kind == .deleted ? oldText : newText) as NSString
            return TextChange(kind: hunk.kind == .deleted ? .deleted : .inserted,
                              text: source.substring(with: range),
                              pageIndex: hunk.kind == .deleted ? oldPage : newPage,
                              range: range)
        }
    }
}
