import AppKit
import PDFEditorCore
import SwiftUI

/// The single main window: a tab strip in the title bar with Home and the
/// open documents, and the selected tab's content below.
@MainActor
struct WorkspaceView: View {
    @State private var workspace = Workspace.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            TabStrip(workspace: workspace)
            ZStack {
                if let document = workspace.selected {
                    EditorView(controller: document)
                        .id(document.id)
                } else {
                    HomeView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 1000, minHeight: 660)
        .tint(Brand.accent)
        .navigationTitle(workspace.selected?.tabTitle ?? "KPDF")
        .background(WindowReader { window in
            AppRouter.shared.mainWindow = window
            window.tabbingMode = .disallowed
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = false
        })
        .onAppear { AppRouter.shared.openWindow = openWindow }
        .dropDestination(for: URL.self) { urls, _ in
            let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
            pdfs.forEach { workspace.open($0) }
            return !pdfs.isEmpty
        }
    }
}

extension EditorController {
    /// The file name, as UPDF shows it on tabs.
    var tabTitle: String {
        fileURL?.deletingPathExtension().lastPathComponent ?? untitledName
    }
}

/// Home button, document tabs and the add button, drawn in the title bar.
@MainActor
struct TabStrip: View {
    @Bindable var workspace: Workspace

    var body: some View {
        HStack(spacing: 6) {
            // Room for the window's close, minimize and zoom buttons.
            Color.clear.frame(width: 70)

            Button {
                workspace.showHome()
            } label: {
                Image(systemName: workspace.isShowingHome ? "house.fill" : "house")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(workspace.isShowingHome ? Brand.accent : Color.primary)
                    .frame(width: 34, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background {
                if workspace.isShowingHome {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Brand.accentSoft)
                }
            }
            .help("Home (⇧⌘H)")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(workspace.documents) { document in
                        DocumentTab(document: document, workspace: workspace,
                                    isSelected: workspace.selectedID == document.id)
                    }
                    Button {
                        workspace.presentOpenPanel()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Open a PDF in a new tab (⌘O)")
                }
                .padding(.vertical, 2)
            }
            .scrollBounceBehavior(.basedOnSize)

            Spacer(minLength: 12)

            if let document = workspace.selected {
                DocumentActions(controller: document)
            }
        }
        .padding(.trailing, 12)
        .frame(height: 40)
        .background {
            // Dragging the empty strip moves the window; double-clicking zooms it.
            Color.clear
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
                .onTapGesture(count: 2) { AppRouter.shared.mainWindow?.performZoom(nil) }
        }
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// One document tab: icon, file name, unsaved-changes dot and close button.
@MainActor
struct DocumentTab: View {
    let document: EditorController
    let workspace: Workspace
    let isSelected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: document.isLocked ? "lock.doc" : "doc.richtext")
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? Brand.accent : Color.secondary)
            Text(document.tabTitle)
                .font(.system(size: 12.5, weight: isSelected ? .medium : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            Spacer(minLength: 0)
            ZStack {
                if hovering || (isSelected && !document.isEdited) {
                    Button {
                        workspace.close(document)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: 16, height: 16)
                            .background(Circle().fill(Color.primary.opacity(hovering ? 0.1 : 0)))
                    }
                    .buttonStyle(.plain)
                    .help("Close Tab (⌘W)")
                } else if document.isEdited {
                    Circle().fill(Color.secondary).frame(width: 7, height: 7)
                        .help("Unsaved changes")
                }
            }
            .frame(width: 16)
        }
        .padding(.leading, 11)
        .padding(.trailing, 7)
        .frame(width: 210, height: 30)
        .background {
            if isSelected {
                Color.clear.glassSurface(RoundedRectangle(cornerRadius: 9, style: .continuous))
            } else if hovering {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.06))
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .onTapGesture { workspace.select(document) }
        .onHover { hovering = $0 }
        .help(document.fileURL?.path ?? document.tabTitle)
        .contextMenu {
            Button("Close Tab") { workspace.close(document) }
            Button("Close Other Tabs") { workspace.closeOthers(than: document) }
                .disabled(workspace.documents.count < 2)
            Divider()
            Button("Save") { workspace.save(document) }
            Button("Save As…") { workspace.saveAs(document) }
            if let url = document.fileURL {
                Divider()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.path, forType: .string)
                }
            }
        }
    }
}

/// Share, AI and inspector buttons for the current document, at the right of the tab strip.
@MainActor
struct DocumentActions: View {
    @Bindable var controller: EditorController

    var body: some View {
        HStack(spacing: 2) {
            CapsuleBarButton(title: nil, systemImage: "square.and.arrow.up") { controller.share() }
                .help("Share")
            CapsuleBarButton(title: nil, systemImage: "sparkles",
                             isSelected: controller.showsInspector && controller.inspectorTab == .assistant) {
                if controller.showsInspector && controller.inspectorTab == .assistant {
                    controller.showsInspector = false
                } else {
                    controller.inspectorTab = .assistant
                    controller.showsInspector = true
                }
            }
            .help("Ask Claude about this document")
            CapsuleBarButton(title: nil, systemImage: "sidebar.right", isSelected: controller.showsInspector) {
                controller.showsInspector.toggle()
            }
            .help("Inspector")
        }
    }
}
