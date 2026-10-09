import PDFEditorCore
import PDFKit
import SwiftUI

/// Root view of a document window; creates the controller once.
struct ContentView: View {
    @ObservedObject var document: PDFFileDocument
    let fileURL: URL?
    @Environment(\.undoManager) private var undoManager
    @State private var controller: EditorController?

    var body: some View {
        Group {
            if let controller {
                EditorView(controller: controller)
            } else {
                Color.clear
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .onAppear {
            if controller == nil {
                controller = EditorController(fileDocument: document, fileURL: fileURL)
            }
            controller?.undoManager = undoManager
        }
        .onChange(of: undoManager) { _, newValue in controller?.undoManager = newValue }
        .onChange(of: fileURL) { _, newValue in controller?.fileURL = newValue }
    }
}

@MainActor
struct EditorView: View {
    @Bindable var controller: EditorController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            SidebarView(controller: controller)
                .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 380)
        } detail: {
            VStack(spacing: 0) {
                if controller.mode != .pages {
                    ToolPaletteBar(controller: controller)
                    Divider()
                }
                ZStack {
                    PDFCanvas(controller: controller)
                        .opacity(controller.mode == .pages ? 0 : 1)
                        .allowsHitTesting(controller.mode != .pages)
                    if controller.mode == .pages {
                        PageOrganizerView(controller: controller)
                    }
                    if controller.isLocked {
                        UnlockView(controller: controller)
                    }
                }
                Divider()
                StatusBar(controller: controller)
            }
            .inspector(isPresented: $controller.showsInspector) {
                InspectorView(controller: controller)
                    .inspectorColumnWidth(min: 260, ideal: 300, max: 440)
            }
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
        ToolbarItem(placement: .principal) {
            Picker("Mode", selection: $controller.mode) {
                ForEach(EditorMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.systemImage).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.titleAndIcon)
            .fixedSize()
            .disabled(controller.isLocked)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button("Recognize Text (OCR)…", systemImage: "text.viewfinder") { controller.sheet = .ocr }
                Button("Convert…", systemImage: "arrow.triangle.2.circlepath") { controller.sheet = .convert }
                Button("Compress…", systemImage: "arrow.down.right.and.arrow.up.left") { controller.sheet = .compress }
                Divider()
                Button("Watermark…", systemImage: "drop") { controller.sheet = .watermark }
                Button("Header & Footer…", systemImage: "text.append") { controller.sheet = .headerFooter }
                Button("Background…", systemImage: "square.fill.on.square") { controller.sheet = .background }
                Button("Split…", systemImage: "scissors") { controller.sheet = .split }
                Divider()
                Button("Password & Permissions…", systemImage: "lock") { controller.sheet = .security }
                Button("Flatten All Annotations", systemImage: "square.3.layers.3d.down.right") {
                    controller.flatten(pages: PageRange.all(controller.pageCount))
                }
                Divider()
                Button("Batch Processing…", systemImage: "square.stack.3d.up") { openWindow(id: WindowID.batch) }
                Button("Compare Documents…", systemImage: "doc.on.doc") { openWindow(id: WindowID.compare) }
            } label: {
                Label("Tools", systemImage: "wrench.and.screwdriver")
            }
            .disabled(controller.isLocked)

            Button {
                controller.share()
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .help("Share")

            Button {
                controller.inspectorTab = .assistant
                controller.showsInspector = true
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

extension EditorController {
    func share() {
        guard let view = pdfView, let url = temporaryExport() else { return }
        let picker = NSSharingServicePicker(items: [url])
        let anchor = NSRect(x: view.bounds.maxX - 40, y: view.bounds.maxY - 10, width: 1, height: 1)
        picker.show(relativeTo: anchor, of: view, preferredEdge: .minY)
    }
}

/// Page navigation and zoom along the bottom edge.
@MainActor
struct StatusBar: View {
    @Bindable var controller: EditorController
    @State private var pageText = ""

    var body: some View {
        HStack(spacing: 10) {
            Button { controller.previousPage() } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(controller.currentPageIndex == 0)
            TextField("", text: $pageText)
                .frame(width: 44)
                .multilineTextAlignment(.center)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    if let number = Int(pageText) {
                        controller.go(toPage: min(max(number - 1, 0), controller.pageCount - 1))
                    }
                    pageText = "\(controller.currentPageIndex + 1)"
                }
            Text("of \(controller.pageCount)")
                .foregroundStyle(.secondary)
            Button { controller.nextPage() } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
                .disabled(controller.currentPageIndex >= controller.pageCount - 1)

            Spacer()

            if controller.isSpeaking {
                Button("Stop Reading", systemImage: "speaker.slash") { controller.toggleReadAloud() }
                    .buttonStyle(.borderless)
            }
            if controller.security.isEncrypted {
                Label("Encrypted", systemImage: "lock.fill")
                    .foregroundStyle(.secondary)
                    .help("The document will be saved with a password")
            }

            Picker("", selection: $controller.displayMode) {
                Image(systemName: "doc").tag(PDFDisplayMode.singlePage)
                Image(systemName: "doc.plaintext").tag(PDFDisplayMode.singlePageContinuous)
                Image(systemName: "book").tag(PDFDisplayMode.twoUp)
                Image(systemName: "book.pages").tag(PDFDisplayMode.twoUpContinuous)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .help("Page layout")

            Button { controller.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                .buttonStyle(.borderless)
            Menu("\(controller.zoomPercent)%") {
                ForEach([50, 75, 100, 125, 150, 200, 300, 400], id: \.self) { percent in
                    Button("\(percent)%") { controller.zoom(toPercent: percent) }
                }
                Divider()
                Button("Fit Page") { controller.zoomToFit() }
                Button("Fit Width") { controller.zoomToFitWidth() }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Button { controller.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
                .buttonStyle(.borderless)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
        .onAppear { pageText = "\(controller.currentPageIndex + 1)" }
        .onChange(of: controller.currentPageIndex) { _, index in pageText = "\(index + 1)" }
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
