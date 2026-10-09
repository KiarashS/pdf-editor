import AppKit
import PDFEditorCore
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Side-by-side comparison of two PDFs with a list of text changes.
@MainActor
struct CompareView: View {
    @State private var oldURL: URL?
    @State private var newURL: URL?
    @State private var oldDocument: PDFDocument?
    @State private var newDocument: PDFDocument?
    @State private var changes: [TextChange] = []
    @State private var selected: TextChange.ID?
    @State private var oldView = PDFView()
    @State private var newView = PDFView()
    @State private var comparing = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                fileButton(title: "Original", url: oldURL) { url in
                    oldURL = url
                    oldDocument = PDFDocument(url: url)
                }
                Image(systemName: "arrow.right")
                fileButton(title: "Revised", url: newURL) { url in
                    newURL = url
                    newDocument = PDFDocument(url: url)
                }
                Spacer()
                if comparing { ProgressView().controlSize(.small) }
                Button("Compare") { compare() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(oldDocument == nil || newDocument == nil || comparing)
            }
            .padding(10)
            Divider()
            HSplitView {
                List(selection: $selected) {
                    Section("\(changes.count) changes") {
                        ForEach(changes) { change in
                            ChangeRow(change: change).tag(change.id)
                        }
                    }
                }
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 380)
                ComparePane(view: oldView, document: oldDocument)
                ComparePane(view: newView, document: newDocument)
            }
        }
        .onChange(of: selected) { reveal(selected) }
    }

    private func fileButton(title: String, url: URL?, onPick: @escaping (URL) -> Void) -> some View {
        Button {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.pdf]
            if panel.runModal() == .OK, let url = panel.url { onPick(url) }
        } label: {
            Label(url?.lastPathComponent ?? "Choose \(title)…", systemImage: "doc")
        }
    }

    private func compare() {
        guard let oldDocument, let newDocument,
              let oldData = oldDocument.dataRepresentation(), let newData = newDocument.dataRepresentation() else { return }
        comparing = true
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> [TextChange] in
                guard let a = PDFDocument(data: oldData), let b = PDFDocument(data: newData) else { return [] }
                return DocumentComparator.compare(a, b)
            }.value
            changes = result
            comparing = false
            highlightAll()
        }
    }

    private func selections(for change: TextChange, in document: PDFDocument?) -> PDFSelection? {
        guard let document, let page = document.page(at: change.pageIndex) else { return nil }
        let selection: PDFSelection?
        if let range = change.range {
            selection = page.selection(for: range)
        } else {
            selection = page.selection(for: page.bounds(for: .cropBox))
        }
        selection?.color = change.kind == .inserted || change.kind == .pageAdded
            ? NSColor.systemGreen.withAlphaComponent(0.45)
            : NSColor.systemRed.withAlphaComponent(0.45)
        return selection
    }

    private func highlightAll() {
        oldView.highlightedSelections = changes.filter { $0.kind == .deleted || $0.kind == .pageRemoved }.compactMap { selections(for: $0, in: oldDocument) }
        newView.highlightedSelections = changes.filter { $0.kind == .inserted || $0.kind == .pageAdded }.compactMap { selections(for: $0, in: newDocument) }
    }

    private func reveal(_ id: TextChange.ID?) {
        guard let change = changes.first(where: { $0.id == id }) else { return }
        let deleted = change.kind == .deleted || change.kind == .pageRemoved
        let view = deleted ? oldView : newView
        let other = deleted ? newView : oldView
        if let selection = selections(for: change, in: deleted ? oldDocument : newDocument) {
            view.go(to: selection)
            view.setCurrentSelection(selection, animate: true)
        }
        // Keep the other side on the matching page.
        if let page = other.document?.page(at: min(change.pageIndex, (other.document?.pageCount ?? 1) - 1)) {
            other.go(to: page)
        }
    }
}

struct ChangeRow: View {
    let change: TextChange

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)
                Spacer()
                Text("p. \(change.pageIndex + 1)").font(.caption).foregroundStyle(.secondary)
            }
            Text(change.text.replacingOccurrences(of: "\n", with: " "))
                .lineLimit(3)
                .font(.callout)
                .strikethrough(change.kind == .deleted)
        }
    }

    private var label: String {
        switch change.kind {
        case .inserted: return "Added"
        case .deleted: return "Removed"
        case .pageAdded: return "Page added"
        case .pageRemoved: return "Page removed"
        }
    }

    private var color: Color {
        switch change.kind {
        case .inserted, .pageAdded: return .green
        case .deleted, .pageRemoved: return .red
        }
    }
}

struct ComparePane: NSViewRepresentable {
    let view: PDFView
    let document: PDFDocument?

    func makeNSView(context: Context) -> PDFView {
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .underPageBackgroundColor
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document !== document { nsView.document = document }
    }
}
