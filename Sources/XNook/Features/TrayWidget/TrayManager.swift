import SwiftUI
import UniformTypeIdentifiers

/// 文件架管理器
@MainActor
final class TrayManager: ObservableObject {
    // MARK: - Published Properties

    @Published var files: [TrayFile] = []
    @Published var isDropTargeted = false

    private static var storageURL: URL {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            fatalError("[XNook] Unable to locate application support directory")
        }
        return appSupport.appendingPathComponent("XNook/tray_files.json")
    }

    // MARK: - TrayFile Model

    struct TrayFile: Identifiable, Codable {
        let id: UUID
        let bookmarkData: Data
        let name: String
        let icon: String
        let size: Int
        let addedAt: Date

        /// 从 bookmark data 解析 URL（每次访问前调用）
        /// - Returns: (url, isStale) 元组，isStale 表示 bookmark 是否过期需要重新创建
        func resolveURL() -> (url: URL, isStale: Bool)? {
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else { return nil }
            return (url, isStale)
        }

        static func iconForFile(at url: URL) -> String {
            let ext = url.pathExtension.lowercased()
            switch ext {
            case "jpg", "jpeg", "png", "gif", "heic", "webp": return "photo"
            case "mp4", "mov", "avi", "mkv": return "video"
            case "mp3", "wav", "flac", "m4a": return "music.note"
            case "pdf": return "doc.richtext"
            case "doc", "docx", "txt", "md": return "doc.text"
            case "xls", "xlsx", "csv": return "tablecells"
            case "zip", "tar", "gz": return "archivebox"
            case "swift", "py", "js", "ts", "html", "css": return "chevron.left.forwardslash.chevron.right"
            default: return "doc"
            }
        }
    }

    // MARK: - Init

    init() {
        loadFiles()
    }

    // MARK: - Public Methods

    func loadFiles() {
        let url = Self.storageURL
        guard let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder().decode([FileRecord].self, from: data) else { return }

        var validFiles: [TrayFile] = []
        var hasUpdatedRecords = false
        var unresolvedRecords: [FileRecord] = []  // 无法解析的记录，保留原样

        for record in records {
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: record.bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else {
                // bookmark 无法解析（外接盘未挂载等），保留原始记录
                unresolvedRecords.append(record)
                continue
            }

            if isStale {
                // bookmark 过期，尝试重新创建
                let isAccessing = url.startAccessingSecurityScopedResource()
                defer {
                    if isAccessing {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                if let newBookmarkData = try? url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ) {
                    let icon = TrayFile.iconForFile(at: url)
                    validFiles.append(TrayFile(
                        id: record.id,
                        bookmarkData: newBookmarkData,
                        name: url.lastPathComponent,
                        icon: icon,
                        size: record.size,
                        addedAt: record.addedAt
                    ))
                    hasUpdatedRecords = true
                } else {
                    // 重建失败，保留原始记录
                    unresolvedRecords.append(record)
                }
            } else {
                let icon = TrayFile.iconForFile(at: url)
                validFiles.append(TrayFile(
                    id: record.id,
                    bookmarkData: record.bookmarkData,
                    name: url.lastPathComponent,
                    icon: icon,
                    size: record.size,
                    addedAt: record.addedAt
                ))
            }
        }

        files = validFiles
        // 只在有更新时才保存（过期重建成功），保留未解析的原始记录
        if hasUpdatedRecords {
            let mergedRecords = unresolvedRecords + validFiles.map { FileRecord(from: $0) }
            if let mergedData = try? JSONEncoder().encode(mergedRecords) {
                try? mergedData.write(to: Self.storageURL, options: .atomic)
            }
        }
    }

    func addFile(from url: URL) {
        let isAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if isAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        guard let bookmarkData = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let file = TrayFile(
            id: UUID(),
            bookmarkData: bookmarkData,
            name: url.lastPathComponent,
            icon: TrayFile.iconForFile(at: url),
            size: size,
            addedAt: Date()
        )
        files.append(file)
        saveFiles()
    }

    func addFile(from pasteboard: NSPasteboard) {
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL] else { return }
        for url in urls {
            addFile(from: url)
        }
    }

    func removeFile(_ file: TrayFile) {
        files.removeAll { $0.id == file.id }
        saveFiles()
    }

    func openFile(_ file: TrayFile) {
        withResolvedURL(for: file) { url in
            NSWorkspace.shared.open(url)
        }
    }

    func revealInFinder(_ file: TrayFile) {
        withResolvedURL(for: file) { url in
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func copyToClipboard(_ file: TrayFile) {
        withResolvedURL(for: file) { url in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([url as NSURL])
        }
    }

    private func withResolvedURL(for file: TrayFile, perform action: (URL) -> Void) {
        guard let result = file.resolveURL() else { return }
        let isAccessing = result.url.startAccessingSecurityScopedResource()
        defer {
            if isAccessing {
                result.url.stopAccessingSecurityScopedResource()
            }
        }

        if result.isStale {
            refreshBookmark(for: file, resolvedURL: result.url)
        }
        action(result.url)
    }

    /// 在 security scope 有效期间刷新过期的 bookmark
    private func refreshBookmark(for file: TrayFile, resolvedURL: URL) {
        guard let newBookmarkData = try? resolvedURL.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }

        // 更新对应文件的 bookmarkData
        if let index = files.firstIndex(where: { $0.id == file.id }) {
            let oldFile = files[index]
            files[index] = TrayFile(
                id: oldFile.id,
                bookmarkData: newBookmarkData,
                name: oldFile.name,
                icon: oldFile.icon,
                size: oldFile.size,
                addedAt: oldFile.addedAt
            )
            saveFiles()
        }
    }

    // MARK: - Private Methods

    private func saveFiles() {
        let records = files.map { FileRecord(from: $0) }
        guard let data = try? JSONEncoder().encode(records) else { return }
        let url = Self.storageURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }

    static func formatFileSize(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    // MARK: - 持久化记录

    private struct FileRecord: Codable {
        let id: UUID
        let bookmarkData: Data
        let size: Int
        let addedAt: Date

        init(from file: TrayFile) {
            self.id = file.id
            self.bookmarkData = file.bookmarkData
            self.size = file.size
            self.addedAt = file.addedAt
        }
    }
}
