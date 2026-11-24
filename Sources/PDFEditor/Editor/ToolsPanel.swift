import PDFEditorCore
import SwiftUI

/// The Tools popover: modes, page organizing, editing tools and converters.
@MainActor
struct ToolsPanel: View {
    let controller: EditorController
    @State private var showsMoreEdit = false
    @State private var showsMoreConvert = false

    private let columns = Array(repeating: GridItem(.fixed(88), spacing: 6), count: 4)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                section("Mode") {
                    HStack(spacing: 8) {
                        ForEach([EditorMode.comment, .edit, .forms, .protect], id: \.self) { mode in
                            Button {
                                controller.mode = controller.mode == mode ? .read : mode
                                controller.showsToolsPanel = false
                            } label: {
                                Text(mode.title)
                                    .font(.system(size: 13, weight: controller.mode == mode ? .semibold : .regular))
                                    .frame(minWidth: 62)
                            }
                            .glassButtonStyle(prominent: controller.mode == mode)
                            .tint(controller.mode == mode ? Brand.accent : nil)
                        }
                    }
                }
                Divider()
                section("Organize Pages", more: ("More", { controller.perform(.organize) })) {
                    grid(QuickTool.organizePrimary)
                }
                Divider()
                section("Edit PDF", more: (showsMoreEdit ? "Less" : "More", { withAnimation(.snappy) { showsMoreEdit.toggle() } })) {
                    grid(QuickTool.editPrimary + (showsMoreEdit ? QuickTool.editMore : []))
                }
                Divider()
                section("PDF Converter", more: (showsMoreConvert ? "Less" : "More", { withAnimation(.snappy) { showsMoreConvert.toggle() } })) {
                    grid(QuickTool.convertPrimary + (showsMoreConvert ? QuickTool.convertMore : []))
                }
            }
            .padding(18)
        }
        .frame(width: 400)
        .frame(maxHeight: 640)
    }

    private func grid(_ tools: [QuickTool]) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(tools) { tool in
                ToolTile(title: tool.title, systemImage: tool.systemImage, colors: tool.colors) {
                    controller.perform(tool)
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, more: (String, () -> Void)? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let more {
                    Button(more.0, action: more.1)
                        .buttonStyle(.plain)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Brand.accent)
                }
            }
            content()
        }
    }
}
