import Foundation
import PDFKit

/// Builds Claude requests for document-level AI features: summarize,
/// translate, explain and free-form chat about the open PDF.
public struct DocumentAssistant {
    public enum Action: Equatable {
        case summarize
        case keyPoints
        case translate(language: String)
        case explain
        case rewrite(style: String)
        case ask(String)
    }

    /// The Messages API accepts PDFs up to 32 MB and 600 pages.
    public static let maxPDFBytes = 30 * 1024 * 1024
    public static let maxPDFPages = 600

    public static let systemPrompt = """
    You are the assistant inside a macOS PDF editor. The user is looking at the attached PDF. \
    Answer from the document's content; when you cite something, give the page number. \
    If the document does not contain the answer, say so plainly. Format answers in Markdown.
    """

    public init() {}

    /// The document block sent with the first user turn. Falls back to the
    /// extracted text when the PDF exceeds the API's PDF limits.
    public static func documentBlock(for document: PDFDocument, title: String?) -> ClaudeContentBlock {
        if document.pageCount <= maxPDFPages,
           let data = document.dataRepresentation(),
           data.count <= maxPDFBytes {
            return .pdf(data, title: title, cache: true)
        }
        return .textDocument(extractText(from: document), title: title, cache: true)
    }

    /// Plain text with page markers, used for large documents and selections.
    public static func extractText(from document: PDFDocument, pages: IndexSet? = nil) -> String {
        let indexes = pages ?? PageRange.all(document.pageCount)
        var parts: [String] = []
        for index in indexes {
            guard let page = document.page(at: index) else { continue }
            parts.append("[Page \(index + 1)]\n" + (page.string ?? ""))
        }
        return parts.joined(separator: "\n\n")
    }

    /// The user prompt for a one-shot task. `selection` is the text the user
    /// highlighted, when the task applies to a selection instead of the whole document.
    public static func prompt(for action: Action, selection: String?) -> String {
        let target: String
        if let selection, !selection.isEmpty {
            target = "the following passage from the document:\n\n<passage>\n\(selection)\n</passage>"
        } else {
            target = "the attached document"
        }
        switch action {
        case .summarize:
            return "Summarize \(target). Start with a two-sentence overview, then list the main sections or arguments with page references."
        case .keyPoints:
            return "List the key points, figures, dates and action items in \(target) as a bulleted list with page references."
        case .translate(let language):
            return "Translate \(target) into \(language). Keep the structure (headings, lists, paragraphs). Output only the translation."
        case .explain:
            return "Explain \(target) in plain language for someone new to the subject. Define any jargon."
        case .rewrite(let style):
            return "Rewrite \(target) in a \(style) style. Output only the rewritten text."
        case .ask(let question):
            if let selection, !selection.isEmpty {
                return "Regarding this passage:\n\n<passage>\n\(selection)\n</passage>\n\n\(question)"
            }
            return question
        }
    }
}

/// A multi-turn chat about one document. The document is attached to the
/// first user turn with a cache breakpoint so follow-up turns reuse it.
public final class DocumentChatSession {
    public private(set) var messages: [ClaudeMessage] = []
    private let documentBlock: ClaudeContentBlock

    public init(document: PDFDocument, title: String?) {
        documentBlock = DocumentAssistant.documentBlock(for: document, title: title)
    }

    public init(documentBlock: ClaudeContentBlock) {
        self.documentBlock = documentBlock
    }

    /// Messages to send for a new user turn, including the document on the first turn.
    public func messagesForNewTurn(_ text: String) -> [ClaudeMessage] {
        var pending = messages
        if pending.isEmpty {
            pending.append(ClaudeMessage(role: .user, content: [documentBlock, .text(text)]))
        } else {
            pending.append(.user(text))
        }
        return pending
    }

    /// Records a completed exchange.
    public func commit(userText: String, reply: String) {
        messages = messagesForNewTurn(userText)
        messages.append(.assistant(reply))
    }

    public func reset() { messages.removeAll() }
}
