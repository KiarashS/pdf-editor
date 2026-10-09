import AppKit
import PDFEditorCore
import PDFKit
import SwiftUI

struct ChatEntry: Identifiable, Equatable {
    enum Role { case user, assistant, error }
    let id = UUID()
    let role: Role
    var text: String
}

/// Chat state for one document window.
@MainActor
@Observable
final class AssistantModel {
    var entries: [ChatEntry] = []
    var input = ""
    var isStreaming = false
    var translationLanguage = "English"
    @ObservationIgnored private var session: DocumentChatSession?
    @ObservationIgnored private var task: Task<Void, Never>?

    func reset() {
        task?.cancel()
        entries.removeAll()
        session = nil
        isStreaming = false
    }

    func stop() {
        task?.cancel()
        isStreaming = false
    }

    /// Sends `prompt` (shown to the user as `display`) with the document attached.
    func send(prompt: String, display: String, controller: EditorController) {
        guard !isStreaming else { return }
        guard let apiKey = APIKeyStore.load(), !apiKey.isEmpty else {
            entries.append(ChatEntry(role: .error, text: ClaudeError.missingAPIKey.localizedDescription))
            return
        }
        if session == nil {
            // Attach the document as it would be saved, so overlays and edits are included.
            let exported = (try? DocumentExporter.export(controller.document)).flatMap { PDFDocument(data: $0) } ?? controller.document
            session = DocumentChatSession(document: exported, title: controller.documentTitle)
        }
        guard let session else { return }

        let defaults = UserDefaults.standard
        let configuration = ClaudeConfiguration(
            apiKey: apiKey,
            model: defaults.string(forKey: SettingsKeys.model) ?? ClaudeConfiguration.defaultModel,
            effort: defaults.string(forKey: SettingsKeys.effort) ?? "medium"
        )
        let client = ClaudeClient(configuration: configuration)
        let messages = session.messagesForNewTurn(prompt)

        entries.append(ChatEntry(role: .user, text: display))
        entries.append(ChatEntry(role: .assistant, text: ""))
        let replyID = entries[entries.count - 1].id
        isStreaming = true

        task = Task { [weak self] in
            var reply = ""
            do {
                for try await event in client.stream(system: DocumentAssistant.systemPrompt, messages: messages) {
                    if case .textDelta(let delta) = event {
                        reply += delta
                        self?.update(replyID, text: reply)
                    }
                }
                session.commit(userText: prompt, reply: reply)
            } catch is CancellationError {
                // Stopped by the user.
            } catch {
                self?.update(replyID, text: reply.isEmpty ? error.localizedDescription : reply + "\n\n" + error.localizedDescription, role: .error)
            }
            self?.isStreaming = false
        }
    }

    private func update(_ id: UUID, text: String, role: ChatEntry.Role? = nil) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].text = text
        if let role { entries[index] = ChatEntry(role: role, text: text) }
    }
}

/// The AI assistant: summarize, translate, explain and chat about the PDF.
@MainActor
struct AssistantPanel: View {
    let controller: EditorController
    @Bindable var model: AssistantModel

    init(controller: EditorController) {
        self.controller = controller
        self.model = controller.assistant
    }

    private static let languages = ["English", "Spanish", "French", "German", "Italian", "Portuguese", "Chinese (Simplified)",
                                    "Japanese", "Korean", "Arabic", "Persian", "Hindi", "Russian", "Turkish", "Dutch"]

    var body: some View {
        VStack(spacing: 0) {
            quickActions
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if model.entries.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Label("Ask Claude about this PDF", systemImage: "sparkles").font(.headline)
                                Text("Summaries, translations and answers cite page numbers. Select text in the document to ask about just that passage.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, 8)
                        }
                        ForEach(model.entries) { entry in
                            ChatBubble(entry: entry, controller: controller)
                                .id(entry.id)
                        }
                    }
                    .padding(10)
                }
                .onChange(of: model.entries.last?.text) {
                    if let last = model.entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            Divider()
            inputBar
        }
    }

    private var selectionText: String? {
        let text = controller.pdfView?.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty ?? true) ? nil : text
    }

    private func run(_ action: DocumentAssistant.Action, label: String) {
        let selection = selectionText
        let prompt = DocumentAssistant.prompt(for: action, selection: selection)
        model.send(prompt: prompt, display: selection == nil ? label : "\(label) (selection)", controller: controller)
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Summarize") { run(.summarize, label: "Summarize") }
                Button("Key Points") { run(.keyPoints, label: "Key points") }
                Button("Explain") { run(.explain, label: "Explain") }
            }
            HStack {
                Picker("Translate to", selection: $model.translationLanguage) {
                    ForEach(Self.languages, id: \.self) { Text($0).tag($0) }
                }
                .frame(maxWidth: 220)
                Button("Translate") {
                    run(.translate(language: model.translationLanguage), label: "Translate to \(model.translationLanguage)")
                }
            }
            HStack {
                Spacer()
                if model.isStreaming {
                    Button("Stop", systemImage: "stop.circle") { model.stop() }
                }
                Button("New Chat", systemImage: "arrow.counterclockwise") { model.reset() }
                    .disabled(model.entries.isEmpty)
            }
        }
        .controlSize(.small)
        .disabled(model.isStreaming)
        .padding(8)
    }

    private var inputBar: some View {
        HStack(alignment: .bottom) {
            TextField("Ask a question about this document…", text: $model.input, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
                .onSubmit(sendInput)
            Button(action: sendInput) {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .buttonStyle(.borderless)
            .disabled(model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isStreaming)
        }
        .padding(8)
    }

    private func sendInput() {
        let question = model.input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        model.input = ""
        let selection = selectionText
        model.send(prompt: DocumentAssistant.prompt(for: .ask(question), selection: selection), display: question, controller: controller)
    }
}

struct ChatBubble: View {
    let entry: ChatEntry
    let controller: EditorController

    var body: some View {
        VStack(alignment: entry.role == .user ? .trailing : .leading, spacing: 4) {
            Group {
                if entry.role == .assistant && entry.text.isEmpty {
                    ProgressView().controlSize(.small)
                } else {
                    Text(rendered)
                        .textSelection(.enabled)
                }
            }
            .padding(8)
            .background(background, in: RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: .infinity, alignment: entry.role == .user ? .trailing : .leading)

            if entry.role == .assistant && !entry.text.isEmpty {
                HStack(spacing: 10) {
                    Button("Copy", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(entry.text, forType: .string)
                    }
                    Button("Add as Note", systemImage: "note.text.badge.plus") { addAsNote() }
                }
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
                .controlSize(.small)
            }
        }
    }

    private var background: Color {
        switch entry.role {
        case .user: return Color.accentColor.opacity(0.18)
        case .assistant: return Color.secondary.opacity(0.1)
        case .error: return Color.red.opacity(0.15)
        }
    }

    private var rendered: AttributedString {
        (try? AttributedString(markdown: entry.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(entry.text)
    }

    @MainActor
    private func addAsNote() {
        guard let page = controller.currentPage else { return }
        let box = page.bounds(for: .cropBox)
        let note = AnnotationFactory.note(at: CGPoint(x: box.maxX - 30, y: box.maxY - 30), text: entry.text, color: .systemPurple)
        note.userName = "Claude"
        controller.add([note], to: page, actionName: "Add AI Note")
    }
}
