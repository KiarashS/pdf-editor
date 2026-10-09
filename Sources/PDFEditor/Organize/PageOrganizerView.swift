import AppKit
import PDFEditorCore
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Thumbnail cache keyed by page identity, rotation and size.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()

    func image(for page: PDFPage, width: CGFloat, revision: Int) -> NSImage {
        let key = "\(ObjectIdentifier(page).hashValue)-\(page.rotation)-\(Int(width))-\(revision)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let size = PageGeometry.displaySize(of: page)
        let height = width * size.height / max(size.width, 1)
        let image = page.thumbnail(of: CGSize(width: width * 2, height: height * 2), for: .cropBox)
        cache.setObject(image, forKey: key)
        return image
    }
}

/// Grid of pages for reordering, rotating, inserting, extracting and deleting.
@MainActor
struct PageOrganizerView: View {
    @Bindable var controller: EditorController
    @State private var dropTarget: Int?

    var body: some View {
        let _ = controller.revision
        let pages = controller.document.pages
        VStack(spacing: 0) {
            OrganizerToolbar(controller: controller)
            Divider()
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: controller.organizerThumbnailSize + 20), spacing: 18)], spacing: 22) {
                    ForEach(Array(pages.enumerated()), id: \.element) { index, page in
                        PageCell(page: page, index: index, width: controller.organizerThumbnailSize,
                                 revision: controller.revision,
                                 isSelected: controller.organizerSelection.contains(index),
                                 isDropTarget: dropTarget == index)
                            .onTapGesture(count: 2) {
                                controller.mode = .read
                                controller.go(toPage: index)
                            }
                            .onTapGesture { select(index) }
                            .contextMenu { contextMenu(for: index) }
                            .draggable(PageDragItem(index: index))
                            .dropDestination(for: PageDragItem.self) { items, _ in
                                drop(items, at: index)
                            } isTargeted: { targeted in
                                dropTarget = targeted ? index : (dropTarget == index ? nil : dropTarget)
                            }
                    }
                }
                .padding(20)
            }
            .background(Color(nsColor: .underPageBackgroundColor))
            .dropDestination(for: URL.self) { urls, _ in
                controller.insertFiles(urls, at: controller.pageCount)
                return true
            }
        }
    }

    private func select(_ index: Int) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if controller.organizerSelection.contains(index) {
                controller.organizerSelection.remove(index)
            } else {
                controller.organizerSelection.insert(index)
            }
        } else if flags.contains(.shift), let anchor = controller.organizerSelection.min() {
            controller.organizerSelection = Set(min(anchor, index)...max(anchor, index))
        } else {
            controller.organizerSelection = [index]
        }
        controller.currentPageIndex = index
    }

    private func drop(_ items: [PageDragItem], at index: Int) -> Bool {
        let dragged = IndexSet(items.map(\.index))
        // Dragging one page of a multi-page selection moves the whole selection.
        let moving = dragged.count == 1 && controller.organizerSelection.contains(dragged.first!)
            ? IndexSet(controller.organizerSelection) : dragged
        guard !moving.isEmpty else { return false }
        let destination = (moving.first ?? 0) < index ? index + 1 : index
        controller.movePages(moving, to: destination)
        dropTarget = nil
        return true
    }

    @ViewBuilder
    private func contextMenu(for index: Int) -> some View {
        let targets = controller.organizerSelection.contains(index) ? IndexSet(controller.organizerSelection) : IndexSet(integer: index)
        Button("Rotate Left") { controller.rotatePages(targets, by: -90) }
        Button("Rotate Right") { controller.rotatePages(targets, by: 90) }
        Divider()
        Button("Insert Blank Page Before") { controller.insertBlankPage(at: index, size: pageSize(index)) }
        Button("Insert Blank Page After") { controller.insertBlankPage(at: index + 1, size: pageSize(index)) }
        Button("Insert File After…") { controller.insertFiles(at: index + 1) }
        Divider()
        Button("Duplicate") { controller.duplicatePages(targets) }
        Button("Extract…") { controller.extractPages(targets) }
        Button("Replace…") { controller.replacePages(targets) }
        Divider()
        Button("Delete", role: .destructive) { controller.deletePages(targets) }
    }

    private func pageSize(_ index: Int) -> CGSize {
        controller.document.page(at: index).map { $0.bounds(for: .mediaBox).size } ?? PaperSize.letter.size
    }
}

/// A page being dragged inside the organizer, carried as tagged text.
struct PageDragItem: Transferable {
    static let prefix = "pdfeditor-page:"
    let index: Int

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: { "\(PageDragItem.prefix)\($0.index)" }, importing: { (text: String) in
            guard text.hasPrefix(PageDragItem.prefix), let index = Int(text.dropFirst(PageDragItem.prefix.count)) else {
                throw CocoaError(.coderInvalidValue)
            }
            return PageDragItem(index: index)
        })
    }
}

struct PageCell: View {
    let page: PDFPage
    let index: Int
    let width: CGFloat
    let revision: Int
    let isSelected: Bool
    let isDropTarget: Bool

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: ThumbnailCache.shared.image(for: page, width: width, revision: revision))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: width)
                .background(Color.white)
                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
                        .padding(-4)
                )
                .overlay(alignment: .leading) {
                    if isDropTarget {
                        Rectangle().fill(Color.accentColor).frame(width: 4).offset(x: -12)
                    }
                }
            Text("\(index + 1)")
                .font(.caption.weight(isSelected ? .semibold : .regular))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear, in: Capsule())
        }
        .contentShape(Rectangle())
    }
}

@MainActor
struct OrganizerToolbar: View {
    @Bindable var controller: EditorController
    @State private var showsInsertOptions = false

    private var targets: IndexSet { IndexSet(controller.organizerSelection) }
    private var hasSelection: Bool { !controller.organizerSelection.isEmpty }
    private var insertionIndex: Int { (controller.organizerSelection.max() ?? controller.pageCount - 1) + 1 }

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                Button("Blank Page") { controller.sheet = .insertBlank }
                Button("From File…") { controller.insertFiles(at: insertionIndex) }
            } label: {
                Label("Insert", systemImage: "plus.rectangle.on.rectangle")
            }
            .fixedSize()
            Button("Rotate Left", systemImage: "rotate.left") { controller.rotatePages(targets, by: -90) }
                .disabled(!hasSelection)
            Button("Rotate Right", systemImage: "rotate.right") { controller.rotatePages(targets, by: 90) }
                .disabled(!hasSelection)
            Button("Duplicate", systemImage: "plus.square.on.square") { controller.duplicatePages(targets) }
                .disabled(!hasSelection)
            Button("Extract", systemImage: "square.and.arrow.up") { controller.extractPages(targets) }
                .disabled(!hasSelection)
            Button("Replace", systemImage: "arrow.left.arrow.right.square") { controller.replacePages(targets) }
                .disabled(!hasSelection)
            Button("Reverse", systemImage: "arrow.up.arrow.down") { controller.reversePages(targets.count > 1 ? targets : PageRange.all(controller.pageCount)) }
            Button("Split", systemImage: "scissors") { controller.sheet = .split }
            Button("Crop", systemImage: "crop") { controller.sheet = .crop }
            Button("Delete", systemImage: "trash", role: .destructive) { controller.deletePages(targets) }
                .disabled(!hasSelection)
            Spacer()
            Button("Select All") { controller.organizerSelection = Set(0..<controller.pageCount) }
            Slider(value: $controller.organizerThumbnailSize, in: 90...320)
                .frame(width: 110)
                .help("Thumbnail size")
        }
        .labelStyle(.iconOnly)
        .controlSize(.regular)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
