import SwiftUI
import UniformTypeIdentifiers

/// 文件架管理器
@MainActor
final class TrayManager: ObservableObject {
    // MARK: - Published Properties

    @Published var files: [TrayFile] = []
    @Published var isDropTargeted = false

    // MARK: - TrayFile Model

    struct TrayFile: Identifiable {
        let id: UUID
        let url: URL
        let name: String
        let icon: String
        let size: Int
        let addedAt: Date

        init(url: URL) {
            self.id = UUID()
            self.url = url
            self.name = url.lastPathComponent
            self.icon = Self.iconForFile(at: url)
            self.size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            self.addedAt = Date()
        }

        static func iconForFile(at url: URL) -> String {
            let ext = url.pathExtension.lowercased()

            switch ext {
            case "jpg", "jpeg", "png", "gif", "heic", "webp":
                return "photo"
            case "mp4", "mov", "avi", "mkv":
                return "video"
            case "mp3", "wav", "flac", "m4a":
                return "music.note"
            case "pdf":
                return "doc.richtext"
            case "doc", "docx", "txt", "md":
                return "doc.text"
            case "xls", "xlsx", "csv":
                return "tablecells"
            case "zip", "tar", "gz":
                return "archivebox"
            case "swift", "py", "js", "ts", "html", "css":
                return "chevron.left.forwardslash.chevron.right"
            default:
                return "doc"
            }
        }
    }

    // MARK: - Init

    init() {
        loadFiles()
    }

    // MARK: - Public Methods

    func loadFiles() {
        // TODO: 从 UserDefaults 加载文件引用
    }

    func addFile(from url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        let file = TrayFile(url: url)
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
        NSWorkspace.shared.open(file.url)
    }

    func revealInFinder(_ file: TrayFile) {
        NSWorkspace.shared.activateFileViewerSelecting([file.url])
    }

    func copyToClipboard(_ file: TrayFile) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([file.url as NSURL])
    }

    // MARK: - Private Methods

    private func saveFiles() {
        // TODO: 保存文件引用到 UserDefaults
    }

    static func formatFileSize(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
