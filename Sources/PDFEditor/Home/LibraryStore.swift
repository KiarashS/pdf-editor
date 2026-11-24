import AppKit
import Observation
import PDFKit

/// A file shown on the Home screen.
struct LibraryItem: Codable, Identifiable, Equatable {
    var path: String
    var bookmark: Data?
    var lastOpened: Date
    var lastPage: Int = 0
    var pageCount: Int?
    var starred = false

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var title: String { url.deletingPathExtension().lastPathComponent }
}

/// Recent and starred files, the page each was left on, and their previews.
/// Stored as JSON in Application Support; bookmarks keep access to files
/// when the app runs sandboxed.
@MainActor
@Observable
final class LibraryStore {
    static let shared = LibraryStore()

    private(set) var items: [LibraryItem] = []
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    static let maximumItems = 60

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PDFEditor", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("library.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([LibraryItem].self, from: data) {
            items = decoded
        }
        mergeSystemRecents()
    }

    var recents: [LibraryItem] { items.sorted { $0.lastOpened > $1.lastOpened } }
    var starred: [LibraryItem] { recents.filter(\.starred) }

    /// Adds files macOS remembers as recent documents for this app.
    func mergeSystemRecents() {
        for url in NSDocumentController.shared.recentDocumentURLs where !items.contains(where: { $0.path == url.path }) {
            let date = (try? url.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate) ?? .distantPast
            items.append(LibraryItem(path: url.path, bookmark: Self.bookmark(for: url), lastOpened: date))
        }
        trim()
    }

    func noteOpened(_ url: URL, pageCount: Int) {
        if let index = items.firstIndex(where: { $0.path == url.path }) {
            items[index].lastOpened = Date()
            items[index].pageCount = pageCount
            if items[index].bookmark == nil { items[index].bookmark = Self.bookmark(for: url) }
        } else {
            items.append(LibraryItem(path: url.path, bookmark: Self.bookmark(for: url), lastOpened: Date(), pageCount: pageCount))
        }
        trim()
        scheduleSave()
    }

    func recordPosition(of url: URL, page: Int, pageCount: Int) {
        guard let index = items.firstIndex(where: { $0.path == url.path }) else { return }
        guard items[index].lastPage != page || items[index].pageCount != pageCount else { return }
        items[index].lastPage = page
        items[index].pageCount = pageCount
        scheduleSave()
    }

    func lastPage(of url: URL) -> Int? {
        items.first { $0.path == url.path }?.lastPage
    }

    func toggleStar(_ item: LibraryItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].starred.toggle()
        scheduleSave()
    }

    func remove(_ item: LibraryItem) {
        items.removeAll { $0.id == item.id }
        scheduleSave()
    }

    func clearRecents() {
        items.removeAll { !$0.starred }
        NSDocumentController.shared.clearRecentDocuments(nil)
        scheduleSave()
    }

    /// The item's URL with sandbox access started; call `stopAccessingSecurityScopedResource` when done.
    func resolvedURL(for item: LibraryItem) -> URL {
        guard let bookmark = item.bookmark else { return item.url }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return item.url
        }
        _ = url.startAccessingSecurityScopedResource()
        return url
    }

    func open(_ item: LibraryItem) {
        let url = resolvedURL(for: item)
        guard FileManager.default.fileExists(atPath: url.path) else {
            let alert = NSAlert()
            alert.messageText = "\"\(item.title)\" can't be found"
            alert.informativeText = "It may have been moved or deleted. Remove it from the list?"
            alert.addButton(withTitle: "Remove")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn { remove(item) }
            return
        }
        AppRouter.shared.openDocument(at: url)
    }

    private func trim() {
        let sorted = recents
        if sorted.count > Self.maximumItems {
            let keep = Set(sorted.prefix(Self.maximumItems).map(\.id)).union(sorted.filter(\.starred).map(\.id))
            items.removeAll { !keep.contains($0.id) }
        }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let snapshot = items
        let url = fileURL
        let work = DispatchWorkItem {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
        saveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private static func bookmark(for url: URL) -> Data? {
        (try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
    }
}

/// First-page preview, page count and size of a file on disk.
struct FilePreview: @unchecked Sendable {
    let image: NSImage?
    let pageCount: Int?
    let fileSize: Int64?
    let isLocked: Bool
}

/// Loads previews off the main thread and caches them by path and modification date.
@MainActor
final class PreviewLoader {
    static let shared = PreviewLoader()
    private var cache: [String: FilePreview] = [:]

    func cached(_ path: String, modified: Date?) -> FilePreview? {
        cache[key(path, modified)]
    }

    func preview(for url: URL) async -> FilePreview {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let cacheKey = key(url.path, modified)
        if let hit = cache[cacheKey] { return hit }
        let result = await Task.detached(priority: .utility) { () -> FilePreview in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
            guard let document = PDFDocument(url: url) else {
                return FilePreview(image: NSWorkspace.shared.icon(forFile: url.path), pageCount: nil, fileSize: size, isLocked: false)
            }
            if document.isLocked {
                return FilePreview(image: nil, pageCount: nil, fileSize: size, isLocked: true)
            }
            let image = document.page(at: 0)?.thumbnail(of: CGSize(width: 440, height: 560), for: .cropBox)
            return FilePreview(image: image, pageCount: document.pageCount, fileSize: size, isLocked: false)
        }.value
        cache[cacheKey] = result
        return result
    }

    private func key(_ path: String, _ modified: Date?) -> String {
        path + "|" + String(modified?.timeIntervalSince1970 ?? 0)
    }
}
