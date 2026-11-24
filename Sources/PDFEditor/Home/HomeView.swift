import AppKit
import PDFEditorCore
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// The start screen: recent and starred files, opening and creating PDFs,
/// and shortcuts to tools that work across files.
@MainActor
struct HomeView: View {
    enum Section: String, CaseIterable, Identifiable {
        case recent = "Recent", starred = "Starred"
        var id: String { rawValue }
    }

    enum SortOrder: String, CaseIterable, Identifiable {
        case lastOpened = "Last Opened", name = "Name", size = "Size"
        var id: String { rawValue }
    }

    @Environment(\.openWindow) private var openWindow
    @State private var library = LibraryStore.shared
    @AppStorage("home.section") private var section: Section = .recent
    @AppStorage("home.sort") private var sort: SortOrder = .lastOpened
    @AppStorage("home.grid") private var showsGrid = true
    @State private var query = ""
    @State private var showsTools = false
    @State private var dropTargeted = false

    private var items: [LibraryItem] {
        var list = section == .recent ? library.recents : library.starred
        if !query.isEmpty {
            list = list.filter { $0.title.localizedCaseInsensitiveContains(query) }
        }
        switch sort {
        case .lastOpened:
            break
        case .name:
            list.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .size:
            list.sort { fileSize($0) > fileSize($1) }
        }
        return list
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Brand.canvas.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 22) {
                header
                content
            }
            .padding(.horizontal, 32)
            .padding(.top, 24)
            .padding(.bottom, 24)
            dock
                .padding(.bottom, 22)
        }
        .onAppear { library.mergeSystemRecents() }
        .dropDestination(for: URL.self) { urls, _ in
            urls.filter { $0.pathExtension.lowercased() == "pdf" }.forEach { Workspace.shared.open($0) }
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Brand.accent, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $showsTools) { HomeToolsSheet() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            HStack(spacing: 4) {
                ForEach(Section.allCases) { item in
                    Button {
                        withAnimation(.snappy) { section = item }
                    } label: {
                        Text(item.rawValue)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(section == item ? Color.primary : Color.secondary)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 9)
                            .background {
                                if section == item {
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(Color.primary.opacity(0.08))
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer()
            Button {
                Workspace.shared.presentOpenPanel()
            } label: {
                Label("Open File", systemImage: "plus.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
            .glassButtonStyle(prominent: true)
            .tint(Brand.accent)
            .controlSize(.large)
            .keyboardShortcut("o")

            Menu {
                Button("Blank Page", systemImage: "doc") { DocumentCreator.newBlank(size: .letter) }
                Button("From Images…", systemImage: "photo.on.rectangle") { DocumentCreator.newFromImages() }
                Button("From Clipboard", systemImage: "doc.on.clipboard") { DocumentCreator.newFromClipboard() }
                Button("Combine Files…", systemImage: "square.stack.3d.down.right") { DocumentCreator.combineFiles() }
            } label: {
                Label("New PDF", systemImage: "doc.badge.plus")
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
            .menuIndicator(.hidden)
            .glassButtonStyle()
            .controlSize(.large)
            .fixedSize()

            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 15, weight: .medium))
                    .padding(6)
            }
            .glassButtonStyle()
            .controlSize(.large)
            .help("Settings")
        }
    }

    // MARK: Content

    private var content: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label("\(items.count) file\(items.count == 1 ? "" : "s")", systemImage: section == .recent ? "clock" : "star")
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .overlay(Capsule().stroke(Color.primary.opacity(0.15)))
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search files", text: $query)
                        .textFieldStyle(.plain)
                        .frame(width: 180)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
                Menu {
                    Picker("Sort By", selection: $sort) {
                        ForEach(SortOrder.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Sort")
                Picker("View", selection: $showsGrid) {
                    Image(systemName: "list.bullet").tag(false)
                    Image(systemName: "square.grid.2x2").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Menu {
                    Button("Clear Recent Files", role: .destructive) { library.clearRecents() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)

            if items.isEmpty {
                emptyState
            } else if showsGrid {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 196, maximum: 240), spacing: 22)], spacing: 22) {
                        ForEach(items) { item in
                            FileCard(item: item, library: library)
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 110)
                }
            } else {
                List {
                    ForEach(items) { item in
                        FileRow(item: item, library: library)
                    }
                }
                .scrollContentBackground(.hidden)
                .contentMargins(.bottom, 100, for: .scrollContent)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Brand.card.opacity(0.55))
        }
        .glassSurface(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: section == .recent ? "doc.text.magnifyingglass" : "star")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(.secondary)
            Text(section == .recent ? (query.isEmpty ? "No recent files" : "No matches") : "No starred files")
                .font(.title3.weight(.semibold))
            Text(section == .recent ? "Open a PDF or drop one here." : "Star a file from its card to keep it here.")
                .foregroundStyle(.secondary)
            if section == .recent {
                Button("Open File…") { Workspace.shared.presentOpenPanel() }
                    .glassButtonStyle(prominent: true)
                    .tint(Brand.accent)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Dock

    private var dock: some View {
        GlassGroup(spacing: 8) {
            HStack(spacing: 8) {
                DockButton(title: "Tools", systemImage: "wrench.and.screwdriver.fill", colors: [Color(red: 0.38, green: 0.55, blue: 1), Color(red: 0.36, green: 0.3, blue: 0.95)]) {
                    showsTools = true
                }
                DockButton(title: "AI", systemImage: "sparkles", colors: [Color(red: 0.55, green: 0.45, blue: 1), Color(red: 0.2, green: 0.6, blue: 1)]) {
                    AppRouter.shared.chooseAndOpen(message: "Choose a PDF to ask Claude about", then: .showAssistant)
                }
                DockButton(title: "Batch", systemImage: "square.stack.3d.up.fill", colors: [Color(red: 0.98, green: 0.6, blue: 0.3), Color(red: 0.92, green: 0.35, blue: 0.2)]) {
                    openWindow(id: WindowID.batch)
                }
                DockButton(title: "Compare", systemImage: "doc.on.doc.fill", colors: [Color(red: 0.3, green: 0.8, blue: 0.6), Color(red: 0.1, green: 0.6, blue: 0.45)]) {
                    openWindow(id: WindowID.compare)
                }
            }
            .padding(8)
            .glassSurface(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }

    private func fileSize(_ item: LibraryItem) -> Int64 {
        Int64((try? item.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
}

struct DockButton: View {
    let title: String
    let systemImage: String
    let colors: [Color]
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ToolTileIcon(systemImage: systemImage, colors: colors, size: 34)
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .frame(width: 74, height: 70)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.09 : 0.04))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: File cards

/// A recent file: title, last page / pages, size and a first-page preview.
@MainActor
struct FileCard: View {
    let item: LibraryItem
    let library: LibraryStore
    @State private var preview: FilePreview?
    @State private var hovering = false

    var body: some View {
        Button {
            library.open(item)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text(item.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, minHeight: 38, alignment: .topLeading)
                FileMetadataLine(item: item, preview: preview)
                ZStack {
                    Color.white
                    if let image = preview?.image {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(maxHeight: .infinity, alignment: .top)
                    } else if preview?.isLocked == true {
                        Image(systemName: "lock.doc.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(height: 170)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 6))
                .padding(.horizontal, -2)
            }
            .padding([.horizontal, .top], 16)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Brand.card)
                    .shadow(color: .black.opacity(hovering ? 0.18 : 0.06), radius: hovering ? 14 : 6, y: hovering ? 6 : 2)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if hovering || item.starred {
                    Button {
                        library.toggleStar(item)
                    } label: {
                        Image(systemName: item.starred ? "star.fill" : "star")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(item.starred ? Color.yellow : Color.secondary)
                            .padding(7)
                            .glassSurface(Circle(), interactive: true)
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                    .help(item.starred ? "Unstar" : "Star")
                }
            }
            .scaleEffect(hovering ? 1.02 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(.spring(duration: 0.25)) { self.hovering = hovering } }
        .contextMenu { FileContextMenu(item: item, library: library) }
        .task(id: item.path) {
            let url = library.resolvedURL(for: item)
            preview = await PreviewLoader.shared.preview(for: url)
        }
    }
}

struct FileMetadataLine: View {
    let item: LibraryItem
    let preview: FilePreview?

    var body: some View {
        HStack(spacing: 6) {
            if let pages = preview?.pageCount ?? item.pageCount {
                Text("\(min(item.lastPage + 1, pages))/\(pages)")
            }
            if let size = preview?.fileSize {
                Text("|").foregroundStyle(.tertiary)
                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
            }
            if preview?.isLocked == true {
                Image(systemName: "lock.fill")
            }
        }
        .font(.system(size: 12).monospacedDigit())
        .foregroundStyle(.secondary)
    }
}

@MainActor
struct FileRow: View {
    let item: LibraryItem
    let library: LibraryStore
    @State private var preview: FilePreview?

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if let image = preview?.image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: preview?.isLocked == true ? "lock.doc" : "doc").font(.title2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 34, height: 44)
            .background(Color.white.opacity(preview?.image == nil ? 0 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 3))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                FileMetadataLine(item: item, preview: preview)
            }
            Spacer()
            Text(item.lastOpened, format: .relative(presentation: .named))
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                library.toggleStar(item)
            } label: {
                Image(systemName: item.starred ? "star.fill" : "star")
                    .foregroundStyle(item.starred ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { library.open(item) }
        .onTapGesture { library.open(item) }
        .contextMenu { FileContextMenu(item: item, library: library) }
        .task(id: item.path) {
            preview = await PreviewLoader.shared.preview(for: library.resolvedURL(for: item))
        }
    }
}

@MainActor
struct FileContextMenu: View {
    let item: LibraryItem
    let library: LibraryStore

    var body: some View {
        Button("Open") { library.open(item) }
        Button(item.starred ? "Unstar" : "Star") { library.toggleStar(item) }
        Divider()
        Button("Ask AI About This File") { AppRouter.shared.openDocument(at: library.resolvedURL(for: item), then: .showAssistant) }
        Menu("Open With Tool") {
            ForEach([QuickTool.ocr, .compress, .toWord, .toExcel, .toImage, .protect, .watermark]) { tool in
                Button(tool.title) { AppRouter.shared.openDocument(at: library.resolvedURL(for: item), then: .tool(tool)) }
            }
        }
        Divider()
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.path, forType: .string)
        }
        Divider()
        Button("Remove from List", role: .destructive) { library.remove(item) }
    }
}

/// Tools reachable from Home: creating PDFs, batch work, and per-file tools.
@MainActor
struct HomeToolsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    private let columns = Array(repeating: GridItem(.fixed(92), spacing: 8), count: 5)

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Tools").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            group("Create") {
                tile("Blank PDF", "doc", [.gray, .secondary]) { DocumentCreator.newBlank(size: .letter) }
                tile("From Images", "photo.on.rectangle", QuickTool.toImage.colors) { DocumentCreator.newFromImages() }
                tile("From Clipboard", "doc.on.clipboard", QuickTool.insert.colors) { DocumentCreator.newFromClipboard() }
                tile("Combine Files", "square.stack.3d.down.right.fill", QuickTool.split.colors) { DocumentCreator.combineFiles() }
            }
            group("Many Files") {
                tile("Batch", "square.stack.3d.up.fill", QuickTool.compare.colors) { openWindow(id: WindowID.batch) }
                tile("Compare", "doc.on.doc.fill", QuickTool.toCSV.colors) { openWindow(id: WindowID.compare) }
            }
            group("Open a PDF With") {
                ForEach([QuickTool.ocr, .compress, .protect, .watermark, .organize, .toWord, .toExcel, .toPowerPoint, .toImage, .redact]) { tool in
                    tile(tool.title, tool.systemImage, tool.colors) {
                        AppRouter.shared.chooseAndOpen(message: "Choose a PDF for \(tool.title)", then: .tool(tool))
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 540)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) { content() }
        }
    }

    private func tile(_ title: String, _ image: String, _ colors: [Color], action: @escaping () -> Void) -> some View {
        ToolTile(title: title, systemImage: image, colors: colors) {
            dismiss()
            DispatchQueue.main.async { MainActor.assumeIsolated { action() } }
        }
    }
}
