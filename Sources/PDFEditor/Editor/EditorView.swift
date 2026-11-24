import AppKit
import PDFEditorCore
import PDFKit
import SwiftUI

/// Root view of a document window; creates the controller once.
struct ContentView: View {
    @ObservedObject var document: PDFFileDocument
    let fileURL: URL?
    @Environment(\.undoManager) private var undoManager
    @Environment(\.openWindow) private var openWindow
    @State private var controller: EditorController?

    var body: some View {
        Group {
            if let controller {
                EditorView(controller: controller)
            } else {
                Color.clear
            }
        }
        .frame(minWidth: 960, minHeight: 640)
        .background(WindowReader { window in AppRouter.shared.adoptWindow(window, isHome: false) })
        .tint(Brand.accent)
        .onAppear {
            AppRouter.shared.openWindow = openWindow
            if controller == nil {
                let editor = EditorController(fileDocument: document, fileURL: fileURL)
                controller = editor
                if let fileURL { LibraryStore.shared.noteOpened(fileURL, pageCount: editor.pageCount) }
                if let action = AppRouter.shared.takePendingAction(for: fileURL) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        MainActor.assumeIsolated { editor.perform(action) }
                    }
                }
            }
            controller?.undoManager = undoManager
        }
        .onChange(of: undoManager) { _, newValue in controller?.undoManager = newValue }
        .onChange(of: fileURL) { _, newValue in
            controller?.fileURL = newValue
            if let newValue, let controller { LibraryStore.shared.noteOpened(newValue, pageCount: controller.pageCount) }
        }
    }
}

/// The document window: icon rail, sidebar panel, and the page canvas with
/// floating glass toolbars over it.
@MainActor
struct EditorView: View {
    @Bindable var controller: EditorController

    var body: some View {
        HStack(spacing: 0) {
            IconRail(controller: controller)
            if controller.sidebarVisible {
                SidebarPanel(controller: controller)
                    .frame(width: 236)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            ZStack(alignment: .top) {
                Brand.canvas.ignoresSafeArea()
                PDFCanvas(controller: controller)
                    .opacity(controller.mode == .pages ? 0 : 1)
                    .allowsHitTesting(controller.mode != .pages)
                if controller.mode == .pages {
                    PageOrganizerView(controller: controller)
                }
                if controller.isLocked {
                    UnlockView(controller: controller)
                } else {
                    FloatingTopBar(controller: controller)
                        .padding(.top, 10)
                        .padding(.horizontal, 12)
                    VStack {
                        Spacer()
                        FloatingStatusBar(controller: controller)
                            .padding(.bottom, 12)
                    }
                }
            }
            .clipped()
        }
        .animation(.snappy(duration: 0.25), value: controller.sidebarVisible)
        .inspector(isPresented: $controller.showsInspector) {
            InspectorView(controller: controller)
                .inspectorColumnWidth(min: 270, ideal: 310, max: 440)
        }
        .navigationTitle(controller.documentTitle)
        .toolbar { toolbarContent }
        .sheet(item: $controller.sheet) { sheet in
            SheetHost(controller: controller, sheet: sheet)
        }
        .alert("PDF Editor", isPresented: Binding(
            get: { controller.alertMessage != nil },
            set: { if !$0 { controller.alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) { controller.alertMessage = nil }
        } message: {
            Text(controller.alertMessage ?? "")
        }
        .overlay {
            if let progress = controller.progress {
                ProgressHUD(progress: progress)
            }
        }
        .focusedSceneValue(\.editorController, controller)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                AppRouter.shared.showHome()
            } label: {
                Label("Home", systemImage: "house")
            }
            .help("Home")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                controller.share()
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .help("Share")

            Button {
                if controller.showsInspector && controller.inspectorTab == .assistant {
                    controller.showsInspector = false
                } else {
                    controller.inspectorTab = .assistant
                    controller.showsInspector = true
                }
            } label: {
                Label("AI Assistant", systemImage: "sparkles")
            }
            .help("Ask Claude about this document")

            Button {
                controller.showsInspector.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.right")
            }
            .help("Show or hide the inspector")
        }
    }
}

// MARK: Floating bars

/// Tools button, mode capsule and undo/redo/save, floating over the pages.
@MainActor
struct FloatingTopBar: View {
    @Bindable var controller: EditorController

    private static let modes: [EditorMode] = [.comment, .edit, .pages, .forms, .protect]

    var body: some View {
        GlassGroup(spacing: 10) {
            VStack(spacing: 8) {
                ZStack {
                    HStack {
                        toolsButton
                        Spacer()
                        historyBar
                    }
                    modeBar
                }
                if !controller.mode.tools.isEmpty {
                    ToolPaletteBar(controller: controller)
                        .transition(.move(edge: .top).combined(with: .opacity))
                } else if controller.mode == .pages {
                    OrganizerToolbar(controller: controller)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .animation(.snappy(duration: 0.25), value: controller.mode)
    }

    private var toolsButton: some View {
        Button {
            controller.showsToolsPanel.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "wrench.and.screwdriver.fill")
                Text("Tools").fontWeight(.medium)
            }
            .font(.system(size: 13))
            .foregroundStyle(controller.showsToolsPanel ? Brand.accent : Color.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassSurface(Capsule(), tint: controller.showsToolsPanel ? Brand.accent : nil, interactive: true)
        .popover(isPresented: $controller.showsToolsPanel, arrowEdge: .bottom) {
            ToolsPanel(controller: controller)
        }
        .help("All tools")
    }

    private var modeBar: some View {
        HStack(spacing: 2) {
            ForEach(Self.modes) { mode in
                CapsuleBarButton(title: mode.title, systemImage: mode.systemImage, isSelected: controller.mode == mode) {
                    controller.mode = controller.mode == mode ? .read : mode
                }
            }
        }
        .padding(4)
        .glassSurface(Capsule(), interactive: true)
    }

    private var historyBar: some View {
        let _ = controller.revision
        let undo = controller.undoManager
        return HStack(spacing: 2) {
            CapsuleBarButton(title: nil, systemImage: "arrow.uturn.backward") { undo?.undo() }
                .disabled(!(undo?.canUndo ?? false))
                .help(undo?.undoMenuItemTitle ?? "Undo")
            CapsuleBarButton(title: nil, systemImage: "arrow.uturn.forward") { undo?.redo() }
                .disabled(!(undo?.canRedo ?? false))
                .help(undo?.redoMenuItemTitle ?? "Redo")
            Divider().frame(height: 18).padding(.horizontal, 2)
            CapsuleBarButton(title: nil, systemImage: "square.and.arrow.down") {
                NSApp.sendAction(#selector(NSDocument.save(_:)), to: nil, from: nil)
            }
            .help("Save")
            CapsuleBarButton(title: nil, systemImage: "printer") { controller.printDocument() }
                .help("Print")
        }
        .padding(4)
        .glassSurface(Capsule(), interactive: true)
    }
}

/// Page navigation, zoom, layout and reading options along the bottom.
@MainActor
struct FloatingStatusBar: View {
    @Bindable var controller: EditorController
    @State private var pageText = ""

    var body: some View {
        HStack(spacing: 6) {
            CapsuleBarButton(title: nil, systemImage: "chevron.up") { controller.previousPage() }
                .disabled(controller.currentPageIndex == 0)
            HStack(spacing: 4) {
                TextField("", text: $pageText)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .frame(width: 34)
                    .onSubmit {
                        if let number = Int(pageText) {
                            controller.go(toPage: min(max(number - 1, 0), controller.pageCount - 1))
                        }
                        pageText = "\(controller.currentPageIndex + 1)"
                    }
                Text("/ \(controller.pageCount)").foregroundStyle(.secondary)
            }
            .font(.system(size: 13).monospacedDigit())
            CapsuleBarButton(title: nil, systemImage: "chevron.down") { controller.nextPage() }
                .disabled(controller.currentPageIndex >= controller.pageCount - 1)

            Divider().frame(height: 18)

            CapsuleBarButton(title: nil, systemImage: "minus.magnifyingglass") { controller.zoomOut() }
            Menu {
                ForEach([50, 75, 100, 125, 150, 200, 300, 400], id: \.self) { percent in
                    Button("\(percent)%") { controller.zoom(toPercent: percent) }
                }
                Divider()
                Button("Fit Page") { controller.zoomToFit() }
                Button("Fit Width") { controller.zoomToFitWidth() }
            } label: {
                Text("\(controller.zoomPercent)%").font(.system(size: 13).monospacedDigit())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            CapsuleBarButton(title: nil, systemImage: "plus.magnifyingglass") { controller.zoomIn() }

            Divider().frame(height: 18)

            Menu {
                Picker("Layout", selection: $controller.displayMode) {
                    Label("Single Page", systemImage: "doc").tag(PDFDisplayMode.singlePage)
                    Label("Continuous", systemImage: "doc.plaintext").tag(PDFDisplayMode.singlePageContinuous)
                    Label("Two Pages", systemImage: "book").tag(PDFDisplayMode.twoUp)
                    Label("Two Pages Continuous", systemImage: "book.pages").tag(PDFDisplayMode.twoUpContinuous)
                }
                .pickerStyle(.inline)
                Toggle("Book Layout", isOn: $controller.displaysAsBook)
                Divider()
                Picker("Theme", selection: $controller.readingTheme) {
                    ForEach(ReadingTheme.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "rectangle.split.2x1")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Page layout and reading theme")

            CapsuleBarButton(title: nil, systemImage: controller.isSpeaking ? "speaker.slash" : "speaker.wave.2") {
                controller.toggleReadAloud()
            }
            .help(controller.isSpeaking ? "Stop reading" : "Read aloud")
            CapsuleBarButton(title: nil, systemImage: "play.rectangle") { controller.startPresentation() }
                .help("Slideshow")
            if controller.security.isEncrypted {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .help("Saved with a password")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .glassSurface(Capsule(), interactive: true)
        .onAppear { pageText = "\(controller.currentPageIndex + 1)" }
        .onChange(of: controller.currentPageIndex) { _, index in pageText = "\(index + 1)" }
    }
}

extension EditorController {
    func share() {
        guard let view = pdfView, let url = temporaryExport() else { return }
        let picker = NSSharingServicePicker(items: [url])
        let anchor = NSRect(x: view.bounds.maxX - 40, y: view.bounds.maxY - 10, width: 1, height: 1)
        picker.show(relativeTo: anchor, of: view, preferredEdge: .minY)
    }
}

struct ProgressHUD: View {
    let progress: ProgressState

    var body: some View {
        ZStack {
            Color.black.opacity(0.15).ignoresSafeArea()
            VStack(spacing: 12) {
                if let fraction = progress.fraction {
                    ProgressView(value: fraction)
                        .frame(width: 220)
                } else {
                    ProgressView()
                }
                Text(progress.title)
                    .font(.callout)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

/// Shown over a password-protected document until it is unlocked.
@MainActor
struct UnlockView: View {
    let controller: EditorController
    @State private var password = ""
    @State private var failed = false

    var body: some View {
        ZStack {
            Rectangle().fill(.background)
            VStack(spacing: 14) {
                Image(systemName: "lock.doc")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("This document is password protected")
                    .font(.title3)
                SecureField("Password", text: $password)
                    .frame(width: 240)
                    .onSubmit(unlock)
                if failed {
                    Text("Incorrect password").foregroundStyle(.red).font(.callout)
                }
                Button("Unlock", action: unlock)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func unlock() {
        failed = !controller.unlock(password: password)
    }
}
