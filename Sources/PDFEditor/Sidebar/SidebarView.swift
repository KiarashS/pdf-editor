import PDFEditorCore
import PDFKit
import SwiftUI

@MainActor
struct SidebarView: View {
    @Bindable var controller: EditorController

    var body: some View {
        VStack(spacing: 0) {
            Picker("Sidebar", selection: $controller.sidebarTab) {
                ForEach(SidebarTab.allCases) { tab in
                    Image(systemName: tab.systemImage)
                        .help(tab.title)
                        .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()
            switch controller.sidebarTab {
            case .thumbnails:
                ThumbnailSidebar(pdfView: controller.pdfView)
                    .id(controller.canvasGeneration)
            case .outline:
                OutlineSidebar(controller: controller)
            case .annotations:
                AnnotationSidebar(controller: controller)
            case .search:
                SearchSidebar(controller: controller)
            }
        }
    }
}

/// PDFKit's thumbnail strip, bound to the canvas.
struct ThumbnailSidebar: NSViewRepresentable {
    let pdfView: PDFView?

    func makeNSView(context: Context) -> PDFThumbnailView {
        let view = PDFThumbnailView()
        view.backgroundColor = .clear
        view.thumbnailSize = CGSize(width: 120, height: 160)
        view.allowsDragging = false
        view.allowsMultipleSelection = false
        view.pdfView = pdfView
        return view
    }

    func updateNSView(_ view: PDFThumbnailView, context: Context) {
        if view.pdfView !== pdfView { view.pdfView = pdfView }
    }
}

// MARK: Outline

struct OutlineNode: Identifiable {
    let id: ObjectIdentifier
    let outline: PDFOutline
    let title: String
    let pageLabel: String?
    var children: [OutlineNode]?

    static func nodes(for outline: PDFOutline?, in document: PDFDocument) -> [OutlineNode] {
        guard let outline else { return [] }
        return (0..<outline.numberOfChildren).compactMap { index in
            guard let child = outline.child(at: index) else { return nil }
            let kids = nodes(for: child, in: document)
            var pageLabel: String?
            if let page = child.destination?.page {
                let pageIndex = document.index(for: page)
                if pageIndex != NSNotFound { pageLabel = "\(pageIndex + 1)" }
            }
            return OutlineNode(id: ObjectIdentifier(child), outline: child, title: child.label ?? "Untitled",
                               pageLabel: pageLabel, children: kids.isEmpty ? nil : kids)
        }
    }
}

@MainActor
struct OutlineSidebar: View {
    @Bindable var controller: EditorController
    @State private var renaming: OutlineNode?
    @State private var newTitle = ""

    var body: some View {
        let _ = controller.revision
        let nodes = OutlineNode.nodes(for: controller.document.outlineRoot, in: controller.document)
        VStack(spacing: 0) {
            if nodes.isEmpty {
                ContentUnavailableView("No Bookmarks", systemImage: "bookmark",
                                       description: Text("Add a bookmark for the current page with ⇧⌘B."))
            } else {
                List(nodes, children: \.children) { node in
                    HStack {
                        Text(node.title).lineLimit(2)
                        Spacer()
                        if let page = node.pageLabel {
                            Text(page).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { controller.go(to: node.outline) }
                    .contextMenu {
                        Button("Rename…") {
                            newTitle = node.title
                            renaming = node
                        }
                        Button("Delete", role: .destructive) { controller.removeBookmark(node.outline) }
                    }
                }
                .listStyle(.sidebar)
            }
            Divider()
            HStack {
                Button {
                    controller.addBookmark()
                } label: {
                    Label("Add Bookmark", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Spacer()
            }
            .padding(8)
        }
        .alert("Rename Bookmark", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $newTitle)
            Button("Rename") {
                if let node = renaming { controller.renameBookmark(node.outline, to: newTitle) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }
}

// MARK: Annotations

struct AnnotationRow: Identifiable {
    let id: ObjectIdentifier
    let pageIndex: Int
    let annotation: PDFAnnotation
}

@MainActor
struct AnnotationSidebar: View {
    @Bindable var controller: EditorController
    @State private var filter = ""

    var body: some View {
        let _ = controller.revision
        let rows = controller.document.allAnnotations()
            .filter { !$0.annotation.isSubtype(.popup) && !$0.annotation.isSubtype(.link) && !$0.annotation.isSubtype(.widget) }
            .filter { filter.isEmpty || $0.annotation.displayName.localizedCaseInsensitiveContains(filter) || ($0.annotation.contents ?? "").localizedCaseInsensitiveContains(filter) }
            .map { AnnotationRow(id: ObjectIdentifier($0.annotation), pageIndex: $0.pageIndex, annotation: $0.annotation) }
        let pages = Dictionary(grouping: rows, by: \.pageIndex).sorted { $0.key < $1.key }

        VStack(spacing: 0) {
            TextField("Filter", text: $filter)
                .textFieldStyle(.roundedBorder)
                .padding(8)
            if rows.isEmpty {
                ContentUnavailableView("No Comments", systemImage: "text.bubble",
                                       description: Text("Highlights, notes, drawings and stamps appear here."))
            } else {
                List(selection: Binding<ObjectIdentifier?>(
                    get: { controller.selectedAnnotation.map(ObjectIdentifier.init) },
                    set: { id in
                        if let row = rows.first(where: { $0.id == id }) { controller.go(to: row.annotation) }
                    }
                )) {
                    ForEach(pages, id: \.key) { page, items in
                        Section("Page \(page + 1)") {
                            ForEach(items) { row in
                                AnnotationRowView(annotation: row.annotation)
                                    .tag(row.id)
                                    .contextMenu {
                                        Button("Delete", role: .destructive) { controller.remove([row.annotation]) }
                                    }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
            Divider()
            Text("\(rows.count) comments")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(6)
        }
    }
}

struct AnnotationRowView: View {
    let annotation: PDFAnnotation

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(Color(nsColor: annotation.color))
                .frame(width: 9, height: 9)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(annotation.displayName).font(.callout.weight(.medium))
                if let contents = annotation.contents, !contents.isEmpty {
                    Text(contents).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
                if let author = annotation.userName, !author.isEmpty {
                    Text(author + (annotation.modificationDate.map { " · " + $0.formatted(date: .abbreviated, time: .shortened) } ?? ""))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: Search

@MainActor
struct SearchSidebar: View {
    @Bindable var controller: EditorController
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Search document", text: $controller.searchText)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { controller.search() }
                HStack {
                    Toggle("Match case", isOn: $controller.searchCaseSensitive)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                    Spacer()
                    if !controller.searchResults.isEmpty {
                        Text("\(controller.searchIndex + 1) of \(controller.searchResults.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button { controller.previousSearchResult() } label: { Image(systemName: "chevron.up") }
                            .buttonStyle(.borderless)
                        Button { controller.nextSearchResult() } label: { Image(systemName: "chevron.down") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            .padding(8)
            Divider()
            if controller.searchResults.isEmpty {
                ContentUnavailableView(controller.searchText.isEmpty ? "Search" : "No Results",
                                       systemImage: "magnifyingglass",
                                       description: Text(controller.searchText.isEmpty ? "Type a word or phrase and press Return." : "Try a different spelling."))
            } else {
                List(selection: Binding<Int?>(
                    get: { controller.searchIndex },
                    set: { if let index = $0 { controller.showSearchResult(index) } }
                )) {
                    ForEach(Array(controller.searchResults.enumerated()), id: \.offset) { index, selection in
                        SearchResultRow(selection: selection, document: controller.document)
                            .tag(index)
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .onAppear { focused = true }
        .onChange(of: controller.searchCaseSensitive) { controller.search() }
    }
}

struct SearchResultRow: View {
    let selection: PDFSelection
    let document: PDFDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let page = selection.pages.first {
                Text("Page \(document.index(for: page) + 1)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(context)
                .font(.callout)
                .lineLimit(3)
        }
    }

    private var context: AttributedString {
        let match = selection.string ?? ""
        guard let extended = selection.copy() as? PDFSelection else { return AttributedString(match) }
        extended.extendForLineBoundaries()
        let line = (extended.string ?? match).replacingOccurrences(of: "\n", with: " ")
        var result = AttributedString(line)
        if let range = result.range(of: match, options: .caseInsensitive) {
            result[range].font = .callout.bold()
            result[range].backgroundColor = .yellow.opacity(0.35)
        }
        return result
    }
}
