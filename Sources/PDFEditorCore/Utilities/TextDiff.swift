import Foundation

/// A word of text plus its UTF-16 range in the source string.
public struct TextToken: Equatable {
    public let text: String
    public let range: NSRange

    public init(text: String, range: NSRange) {
        self.text = text
        self.range = range
    }

    public static func == (lhs: TextToken, rhs: TextToken) -> Bool { lhs.text == rhs.text }
}

public enum DiffOperation: Equatable {
    case equal(old: Int, new: Int)
    case delete(old: Int)
    case insert(new: Int)
}

/// A run of consecutive inserted or deleted tokens.
public struct DiffHunk: Equatable {
    public enum Kind: Equatable { case inserted, deleted }
    public let kind: Kind
    /// Indexes into the old token list (deleted) or new token list (inserted).
    public let tokenIndexes: Range<Int>
}

public enum TextDiff {
    /// Splits text into whitespace-separated words, remembering their ranges.
    public static func tokenize(_ text: String) -> [TextToken] {
        let ns = text as NSString
        var tokens: [TextToken] = []
        var start: Int?
        for i in 0..<ns.length {
            let c = ns.character(at: i)
            let isSpace = c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 || c == 0x0C || c == 0xA0
            if isSpace {
                if let s = start {
                    let r = NSRange(location: s, length: i - s)
                    tokens.append(TextToken(text: ns.substring(with: r), range: r))
                    start = nil
                }
            } else if start == nil {
                start = i
            }
        }
        if let s = start {
            let r = NSRange(location: s, length: ns.length - s)
            tokens.append(TextToken(text: ns.substring(with: r), range: r))
        }
        return tokens
    }

    /// Myers' O(ND) difference algorithm. Returns `nil` when the edit distance
    /// exceeds `maxEdits`, so callers can fall back to a coarse comparison.
    public static func diff<T: Equatable>(_ a: [T], _ b: [T], maxEdits: Int = 4000) -> [DiffOperation]? {
        let n = a.count
        let m = b.count
        if n == 0 && m == 0 { return [] }
        let limit = min(n + m, maxEdits)
        let offset = limit + 1
        var v = [Int](repeating: 0, count: 2 * limit + 3)
        // trace[d] holds v[-d...d] as it was at the start of round d.
        var trace: [[Int]] = []

        var found = false
        outer: for d in 0...limit {
            trace.append(Array(v[(offset - d)...(offset + d)]))
            for k in stride(from: -d, through: d, by: 2) {
                var x: Int
                if k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) {
                    x = v[offset + k + 1]
                } else {
                    x = v[offset + k - 1] + 1
                }
                var y = x - k
                while x < n && y < m && a[x] == b[y] {
                    x += 1
                    y += 1
                }
                v[offset + k] = x
                if x >= n && y >= m {
                    found = true
                    break outer
                }
            }
        }
        guard found else { return nil }

        var operations: [DiffOperation] = []
        var x = n
        var y = m
        for d in stride(from: trace.count - 1, through: 0, by: -1) {
            if d == 0 {
                while x > 0 && y > 0 {
                    operations.append(.equal(old: x - 1, new: y - 1))
                    x -= 1
                    y -= 1
                }
                break
            }
            let row = trace[d]
            func value(_ k: Int) -> Int { row[k + d] }
            let k = x - y
            let previousK = (k == -d || (k != d && value(k - 1) < value(k + 1))) ? k + 1 : k - 1
            let previousX = value(previousK)
            let previousY = previousX - previousK
            while x > previousX && y > previousY {
                operations.append(.equal(old: x - 1, new: y - 1))
                x -= 1
                y -= 1
            }
            if x == previousX {
                operations.append(.insert(new: y - 1))
            } else {
                operations.append(.delete(old: x - 1))
            }
            x = previousX
            y = previousY
        }
        return operations.reversed()
    }

    /// Groups operations into hunks of consecutive insertions or deletions.
    public static func hunks(from operations: [DiffOperation]) -> [DiffHunk] {
        var hunks: [DiffHunk] = []
        var currentKind: DiffHunk.Kind?
        var start = 0
        var end = 0

        func flush() {
            if let kind = currentKind {
                hunks.append(DiffHunk(kind: kind, tokenIndexes: start..<end))
            }
            currentKind = nil
        }

        for operation in operations {
            switch operation {
            case .equal:
                flush()
            case .delete(let old):
                if currentKind == .deleted && old == end {
                    end += 1
                } else {
                    flush()
                    currentKind = .deleted
                    start = old
                    end = old + 1
                }
            case .insert(let new):
                if currentKind == .inserted && new == end {
                    end += 1
                } else {
                    flush()
                    currentKind = .inserted
                    start = new
                    end = new + 1
                }
            }
        }
        flush()
        return hunks
    }
}
