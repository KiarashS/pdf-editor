import Foundation

/// Errors produced while parsing a page range expression.
public enum PageRangeError: Error, LocalizedError, Equatable {
    case invalidToken(String)
    case outOfBounds(Int)
    case empty

    public var errorDescription: String? {
        switch self {
        case .invalidToken(let token):
            return "\"\(token)\" is not a valid page or page range."
        case .outOfBounds(let page):
            return "Page \(page) does not exist in this document."
        case .empty:
            return "The page range does not contain any pages."
        }
    }
}

/// Parses and formats human page range expressions such as `1-3, 5, 8-`.
///
/// Pages are 1-based in the text form and 0-based in the returned `IndexSet`.
/// Supported tokens: `n`, `a-b`, `a-` (to the end), `-b` (from the start),
/// `last`, `all`, `odd` and `even`.
public enum PageRange {
    public static func parse(_ text: String, pageCount: Int) throws -> IndexSet {
        var result = IndexSet()
        let tokens = text
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }

        for token in tokens {
            switch token {
            case "all", "*":
                result.formUnion(all(pageCount))
            case "odd":
                result.formUnion(IndexSet(stride(from: 0, to: pageCount, by: 2)))
            case "even":
                result.formUnion(IndexSet(stride(from: 1, to: pageCount, by: 2)))
            case "last":
                guard pageCount > 0 else { throw PageRangeError.outOfBounds(1) }
                result.insert(pageCount - 1)
            default:
                result.formUnion(try parseRangeToken(token, pageCount: pageCount))
            }
        }
        guard !result.isEmpty else { throw PageRangeError.empty }
        return result
    }

    private static func parseRangeToken(_ token: String, pageCount: Int) throws -> IndexSet {
        func page(_ string: Substring) throws -> Int {
            if string == "last" { return pageCount }
            guard let value = Int(string), value > 0 else { throw PageRangeError.invalidToken(token) }
            guard value <= pageCount else { throw PageRangeError.outOfBounds(value) }
            return value
        }

        if let dash = token.firstIndex(of: "-") {
            let lowerText = token[token.startIndex..<dash]
            let upperText = token[token.index(after: dash)...]
            let lower = lowerText.isEmpty ? 1 : try page(lowerText)
            let upper = upperText.isEmpty ? pageCount : try page(upperText)
            guard pageCount > 0 else { throw PageRangeError.outOfBounds(lower) }
            let (a, b) = lower <= upper ? (lower, upper) : (upper, lower)
            return IndexSet(integersIn: (a - 1)...(b - 1))
        }
        return IndexSet(integer: try page(Substring(token)) - 1)
    }

    /// All pages of a document with `pageCount` pages.
    public static func all(_ pageCount: Int) -> IndexSet {
        pageCount > 0 ? IndexSet(integersIn: 0..<pageCount) : IndexSet()
    }

    /// Formats 0-based indexes as a compact 1-based expression, e.g. `1-3, 5`.
    public static func format(_ indexes: IndexSet) -> String {
        indexes.rangeView.map { range -> String in
            let first = range.lowerBound + 1
            let last = range.upperBound
            return first == last ? "\(first)" : "\(first)-\(last)"
        }
        .joined(separator: ", ")
    }

    /// Splits `pageCount` pages into consecutive chunks of `size` pages.
    public static func chunks(pageCount: Int, size: Int) -> [IndexSet] {
        guard size > 0, pageCount > 0 else { return [] }
        return stride(from: 0, to: pageCount, by: size).map { start in
            IndexSet(integersIn: start..<min(start + size, pageCount))
        }
    }
}
