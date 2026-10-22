import AppKit

/// 历史中的独立书签优先，旧记录仍可借助文件架中的引用打开。
@MainActor
enum LinkedFileAccess {
    static func open(
        _ file: LinkedFile,
        fallbackBookmark: Data?,
        resolve: (Data) -> URL? = { data in
            var stale = false
            return try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
        },
        openURL: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) -> Bool {
        let candidates = [file.bookmarkData, fallbackBookmark].compactMap { $0 }
        for bookmark in candidates {
            guard let url = resolve(bookmark), url.isFileURL else { continue }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            if openURL(url) { return true }
        }
        return false
    }
}
