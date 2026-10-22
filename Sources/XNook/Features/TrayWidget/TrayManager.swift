import SwiftUI
import UniformTypeIdentifiers
import Observation

/// 文件架管理器
@Observable @MainActor
final class TrayManager {
    // MARK: - Published Properties

    var files: [TrayFile] = []
    var isDropTargeted = false
    private(set) var issue: Issue?
    var unavailableFileCount: Int { unresolvedRecords.count }

    enum Issue: Equatable {
        case readFailed
        case saveFailed
        case bookmarkCreationFailed
        case fileUnavailable
    }

    private let storageURL: URL
    private let resolveBookmark: (Data) -> (url: URL, isStale: Bool)?
    private let makeBookmark: (URL) throws -> Data
    private var unresolvedRecords: [FileRecord] = []
    private var storageIsReadable = true

    private static var defaultStorageURL: URL {
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
            Self.resolveBookmark(bookmarkData)
        }

        static func resolveBookmark(_ data: Data) -> (url: URL, isStale: Bool)? {
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: data,
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

    init(
        storageURL: URL? = nil,
        resolveBookmark: @escaping (Data) -> (url: URL, isStale: Bool)? = TrayFile.resolveBookmark,
        makeBookmark: @escaping (URL) throws -> Data = {
            try $0.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        }
    ) {
        self.storageURL = storageURL ?? Self.defaultStorageURL
        self.resolveBookmark = resolveBookmark
        self.makeBookmark = makeBookmark
        loadFiles()
    }

    // MARK: - Public Methods

    func loadFiles() {
        let records: [FileRecord]
        do {
            let data = try Data(contentsOf: storageURL)
            records = try JSONDecoder().decode([FileRecord].self, from: data)
        } catch {
            let error = error as NSError
            if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
                files = []
                unresolvedRecords = []
                storageIsReadable = true
                issue = nil
            } else {
                // 未读懂原件时禁止后续写入，避免空列表或新拖入的文件覆盖可恢复数据。
                storageIsReadable = false
                issue = .readFailed
            }
            return
        }

        var validFiles: [TrayFile] = []
        var hasUpdatedRecords = false
        var unresolvedRecords: [FileRecord] = []

        for record in records {
            guard let result = resolveBookmark(record.bookmarkData) else {
                // bookmark 无法解析（外接盘未挂载等），保留原始记录
                unresolvedRecords.append(record)
                continue
            }

            let url = result.url
            if result.isStale {
                // bookmark 过期，尝试重新创建
                let isAccessing = url.startAccessingSecurityScopedResource()
                defer {
                    if isAccessing {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                if let newBookmarkData = try? makeBookmark(url) {
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
        self.unresolvedRecords = unresolvedRecords
        storageIsReadable = true
        issue = nil
        // 所有保存路径共享未解析记录，后续增删文件时也不会丢失离线磁盘中的条目。
        if hasUpdatedRecords {
            saveFiles()
        }
    }

    func addFile(from url: URL) {
        guard storageIsReadable else { return }
        let isAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if isAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        guard let bookmarkData = try? makeBookmark(url) else {
            issue = .bookmarkCreationFailed
            return
        }

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
        if !saveFiles() {
            files.removeAll { $0.id == file.id }
        }
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
        guard storageIsReadable else { return }
        let previousFiles = files
        files.removeAll { $0.id == file.id }
        if !saveFiles() {
            files = previousFiles
        }
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
        guard let result = resolveBookmark(file.bookmarkData) else {
            if storageIsReadable { issue = .fileUnavailable }
            return
        }
        let isAccessing = result.url.startAccessingSecurityScopedResource()
        defer {
            if isAccessing {
                result.url.stopAccessingSecurityScopedResource()
            }
        }

        if storageIsReadable { issue = nil }
        if result.isStale {
            refreshBookmark(for: file, resolvedURL: result.url)
        }
        action(result.url)
    }

    /// 在 security scope 有效期间刷新过期的 bookmark
    private func refreshBookmark(for file: TrayFile, resolvedURL: URL) {
        guard storageIsReadable else { return }
        guard let newBookmarkData = try? makeBookmark(resolvedURL) else {
            issue = .bookmarkCreationFailed
            return
        }

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
            if !saveFiles() {
                files[index] = oldFile
            }
        }
    }

    // MARK: - Private Methods

    @discardableResult
    private func saveFiles() -> Bool {
        guard storageIsReadable else { return false }
        let records = unresolvedRecords + files.map { FileRecord(from: $0) }
        do {
            let data = try JSONEncoder().encode(records)
            try FileManager.default.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: storageURL, options: .atomic)
            issue = nil
            return true
        } catch {
            issue = .saveFailed
            return false
        }
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
