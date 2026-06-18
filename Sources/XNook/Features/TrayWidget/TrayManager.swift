import SwiftUI
import UniformTypeIdentifiers

/// 文件架管理器
@MainActor
final class TrayManager: ObservableObject {
    // MARK: - Published Properties

    @Published var files: [TrayFile] = []
    @Published var isDropTargeted = false

    private let storageKey = "xnook_tray_files"

    // MARK: - TrayFile Model

    struct TrayFile: Identifiable, Codable {
        let id: UUID
        let bookmarkData: Data
        let name: String
        let icon: String
        let size: Int
        let addedAt: Date

        /// 从 bookmark data 解析 URL（每次访问前调用）
        func resolveURL() -> URL? {
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else { return nil }
            return url
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
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let records = try? JSONDecoder().decode([FileRecord].self, from: data) else { return }

        files = records.compactMap { record -> TrayFile? in
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: record.bookmarkData,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else { return nil }
            let icon = TrayFile.iconForFile(at: url)
            return TrayFile(
                id: record.id,
                bookmarkData: record.bookmarkData,
                name: url.lastPathComponent,
                icon: icon,
                size: record.size,
                addedAt: record.addedAt
            )
        }
    }

    func addFile(from url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }

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
        guard let url = file.resolveURL() else { return }
        NSWorkspace.shared.open(url)
    }

    func revealInFinder(_ file: TrayFile) {
        guard let url = file.resolveURL() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func copyToClipboard(_ file: TrayFile) {
        guard let url = file.resolveURL() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
    }

    // MARK: - Private Methods

    private func saveFiles() {
        let records = files.map { FileRecord(from: $0) }
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
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
