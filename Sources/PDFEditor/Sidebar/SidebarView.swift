import PDFEditorCore
import PDFKit
import SwiftUI

/// The narrow column of icons on the left edge of a document window.
@MainActor
struct IconRail: View {
    @Bindable var controller: EditorController

    var body: some View {
        VStack(spacing: 6) {
            railButton(systemImage: "square.grid.2x2", help: "Organize Pages", selected: controller.mode == .pages) {
                controller.mode = controller.mode == .pages ? .read : .pages
            }
            Divider().frame(width: 24).padding(.vertical, 4)
            ForEach([SidebarTab.search, .thumbnails, .outline, .annotations]) { tab in
                railButton(systemImage: tab.railImage, help: tab.title,
                           selected: controller.sidebarVisible && controller.sidebarTab == tab) {
                    if controller.sidebarVisible && controller.sidebarTab == tab {
                        controller.sidebarVisible = false
                    } else {
                        controller.sidebarTab = tab
                        controller.sidebarVisible = true
                    }
                }
            }
            railButton(systemImage: "info.circle", help: "Document Properties",
                       selected: controller.showsInspector && controller.inspectorTab == .document) {
                controller.inspectorTab = .document
                controller.showsInspector.toggle()
            }
            Spacer()
            railButton(systemImage: "sidebar.left", help: controller.sidebarVisible ? "Hide Sidebar" : "Show Sidebar", selected: false) {
                controller.sidebarVisible.toggle()
            }
        }
        .padding(.vertical, 12)
        .frame(width: 54)
        .frame(maxHeight: .infinity)
        .background(.bar)
        .overlay(alignment: .trailing) { Divider() }
    }

    private func railButton(systemImage: String, help: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 36, height: 36)
                .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.8))
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Brand.accent.gradient)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

extension SidebarTab {
    var railImage: String {
        switch self {
        case .thumbnails: return "doc.on.doc"
        case .outline: return "bookmark"
        case .annotations: return "text.bubble"
        case .search: return "magnifyingglass"
        }
    }
}

/// Sidebar content with a title, next to the icon rail.
@MainActor
struct SidebarPanel: View {
    @Bindable var controller: EditorController

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(controller.sidebarTab == .thumbnails ? "Thumbnails" : controller.sidebarTab.title)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                if controller.sidebarTab == .thumbnails {
                    Text("\(controller.currentPageIndex + 1) / \(controller.pageCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            switch controller.sidebarTab {
            case .thumbnails:
                ThumbnailList(controller: controller)
            case .outline:
                OutlineSidebar(controller: controller)
            case .annotations:
                AnnotationSidebar(controller: controller)
            case .search:
                SearchSidebar(controller: controller)
            }
        }
        .background(.background)
        .overlay(alignment: .trailing) { Divider() }
    }
}

/// Page thumbnails with page numbers; the current page is highlighted.
@MainActor
struct ThumbnailList: View {
    @Bindable var controller: EditorController

    var body: some View {
        let revision = controller.revision
        let pages = controller.document.pages
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(Array(pages.enumerated()), id: \.element) { index, page in
                        let selected = index == controller.currentPageIndex
                        Button {
                            controller.go(toPage: index)
                        } label: {
                            VStack(spacing: 6) {
                                Image(nsImage: ThumbnailCache.shared.image(for: page, width: 150, revision: revision))
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 150)
                                    .background(Color.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                                    .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                                    .padding(7)
                                    .background {
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(selected ? Brand.accentSoft : Color.clear)
                                    }
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .stroke(selected ? Brand.accent : Color.clear, lineWidth: 2)
                                    }
                                Text("\(index + 1)")
                                    .font(.system(size: 12, weight: selected ? .semibold : .regular).monospacedDigit())
                                    .foregroundStyle(selected ? Brand.accent : Color.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(index)
                        .contextMenu {
                            Button("Rotate Left") { controller.rotatePages(IndexSet(integer: index), by: -90) }
                            Button("Rotate Right") { controller.rotatePages(IndexSet(integer: index), by: 90) }
                            Divider()
                            Button("Insert Blank Page After") {
                                controller.insertBlankPage(at: index + 1, size: page.bounds(for: .mediaBox).size)
                            }
                            Button("Duplicate") { controller.duplicatePages(IndexSet(integer: index)) }
                            Button("Extract…") { controller.extractPages(IndexSet(integer: index)) }
                            Divider()
                            Button("Delete", role: .destructive) { controller.deletePages(IndexSet(integer: index)) }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
            }
            .onAppear { proxy.scrollTo(controller.currentPageIndex, anchor: .center) }
            .onChange(of: controller.currentPageIndex) { _, index in
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(index, anchor: .center) }
            }
        }
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
