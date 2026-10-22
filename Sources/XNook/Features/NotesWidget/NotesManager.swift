import SwiftUI
import Observation

/// 笔记管理器 — 使用文件系统存储，避免 UserDefaults 大数据量问题
@Observable @MainActor
final class NotesManager {
    // MARK: - Published Properties

    private(set) var notes: [Note] = []
    private(set) var currentNote: Note?
    private(set) var isEditing = false
    private(set) var storageErrorMessage: String?
    private(set) var recoveryBackupURL: URL?

    var isStorageReadOnly: Bool { loadFailed }
    var canUndoDelete: Bool { deletedNote != nil && !loadFailed }

    enum ExportFormat: String, CaseIterable {
        case markdown = "md"
        case plainText = "txt"
    }

    enum ExportError: LocalizedError {
        case noteNotFound
        case invalidDestination

        var errorDescription: String? {
            switch self {
            case .noteNotFound: return L10n.notesExportMissing
            case .invalidDestination: return L10n.notesExportInvalidDestination
            }
        }
    }

    // MARK: - Note Model

    struct Note: Identifiable, Codable {
        let id: UUID
        var title: String
        var content: String
        var isMarkdown: Bool
        let createdAt: Date
        var updatedAt: Date

        init(title: String = "Untitled", content: String = "", isMarkdown: Bool = true) {
            self.id = UUID()
            self.title = title
            self.content = content
            self.isMarkdown = isMarkdown
            self.createdAt = Date()
            self.updatedAt = Date()
        }
    }

    // MARK: - Private Properties

    /// 防抖保存任务，连续编辑时延迟写入磁盘
    private var debounceSaveTask: Task<Void, Never>?
    private let notesStorageURL: URL
    private let saveDelay: TimeInterval
    private let writeData: (Data, URL) throws -> Void
    private var hasPendingChanges = false
    private var loadFailed = false
    private var deletedNote: (note: Note, index: Int)?

    // MARK: - Storage

    private static var storageURL: URL {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            fatalError("[XNook] Unable to locate application support directory")
        }
        return appSupport.appendingPathComponent("XNook/notes.json")
    }

    // MARK: - Init

    init(
        storageURL: URL? = nil,
        saveDelay: TimeInterval = 0.5,
        writeData: @escaping (Data, URL) throws -> Void = { data, url in
            try data.write(to: url, options: .atomic)
        }
    ) {
        self.notesStorageURL = storageURL ?? Self.storageURL
        self.saveDelay = saveDelay.isFinite ? max(0, saveDelay) : 0.5
        self.writeData = writeData
        loadNotes()
    }

    // MARK: - Public Methods

    func loadNotes() {
        // 重试读取前不能用磁盘旧内容替换尚未保存的编辑。
        guard !hasPendingChanges || flushPendingChanges() else { return }
        do {
            let data = try Data(contentsOf: notesStorageURL)
            let decoded = try JSONDecoder().decode([Note].self, from: data)
            notes = decoded
            if let currentNote {
                self.currentNote = notes.first { $0.id == currentNote.id }
                isEditing = self.currentNote != nil
            }
            deletedNote = nil
            loadFailed = false
            storageErrorMessage = nil
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // 只有文件确实不存在时才初始化示例，读取或解码失败不走此分支。
            if notes.isEmpty {
                notes = [
                    Note(title: "Welcome", content: "# Welcome to X Nook\n\nThis is your notes widget.", isMarkdown: true),
                    Note(title: "Quick Note", content: "Type your notes here...", isMarkdown: false)
                ]
            }
            loadFailed = false
            hasPendingChanges = true
            persist()
        } catch {
            loadFailed = true
            storageErrorMessage = L10n.notesReadFailed
        }
    }

    /// 创建新笔记并返回，便于调用方获取 id 等字段做关联
    func createNote(title: String = L10n.notesUntitled, content: String = "", isMarkdown: Bool = true) -> Note? {
        guard !isStorageReadOnly else { return nil }
        let note = Note(title: title, content: content, isMarkdown: isMarkdown)
        notes.insert(note, at: 0)
        currentNote = note
        isEditing = true
        hasPendingChanges = true
        flushPendingChanges()
        return note
    }

    /// 兼容旧调用方：创建默认笔记但不返回引用
    func createNote() {
        _ = createNote(title: L10n.notesUntitled, content: "", isMarkdown: true)
    }

    func saveNote(_ note: Note) {
        updateNoteInMemory(note)
        flushPendingChanges()
    }

    /// 防抖保存：连续编辑时延迟 0.5s 写入磁盘，避免每次按键都 I/O
    func saveNoteDebounced(_ note: Note) {
        guard updateNoteInMemory(note) else { return }
        debounceSaveTask?.cancel()
        let delay = saveDelay
        debounceSaveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.debounceSaveTask = nil
            self.persist()
        }
    }

    @discardableResult
    func deleteNote(_ note: Note) -> Bool {
        guard !isStorageReadOnly, let index = notes.firstIndex(where: { $0.id == note.id }) else {
            return false
        }
        // 保存最新内存内容和原位置，不能用列表曾经持有的旧副本撤销。
        deletedNote = (notes.remove(at: index), index)
        if currentNote?.id == note.id {
            currentNote = nil
            isEditing = false
        }
        hasPendingChanges = true
        flushPendingChanges()
        return true
    }

    func selectNote(_ note: Note) {
        selectNote(id: note.id)
    }

    @discardableResult
    func selectNote(id: UUID) -> Bool {
        guard let latestNote = notes.first(where: { $0.id == id }) else { return false }
        flushPendingChanges()
        currentNote = latestNote
        isEditing = true
        return true
    }

    func filteredNotes(matching query: String) -> [Note] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return notes }
        return notes.filter {
            $0.title.localizedStandardContains(query) || $0.content.localizedStandardContains(query)
        }
    }

    func updateCurrentNoteTitle(_ title: String) {
        guard var note = currentNote, note.title != title else { return }
        note.title = title
        note.updatedAt = Date()
        saveNoteDebounced(note)
    }

    func updateCurrentNoteContent(_ content: String) {
        guard var note = currentNote, note.content != content else { return }
        note.content = content
        note.updatedAt = Date()
        saveNoteDebounced(note)
    }

    @discardableResult
    func undoDelete() -> Bool {
        guard !isStorageReadOnly, let deletedNote else { return false }
        notes.insert(deletedNote.note, at: min(deletedNote.index, notes.count))
        self.deletedNote = nil
        hasPendingChanges = true
        flushPendingChanges()
        return true
    }

    func exportFileName(for note: Note, format: ExportFormat) -> String {
        let title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden = CharacterSet(charactersIn: "/:").union(.controlCharacters)
        let safeTitle = title.components(separatedBy: forbidden).joined(separator: "-")
        let stem = safeTitle.isEmpty || safeTitle == "." || safeTitle == ".." ? L10n.notesUntitled : safeTitle
        return "\(stem.prefix(120)).\(format.rawValue)"
    }

    /// 导出当前内存内容，标题作为文件名；纯文本保留原文，不丢弃 Markdown 标记。
    func exportNote(id: UUID, to destination: URL, format: ExportFormat) throws {
        guard let note = notes.first(where: { $0.id == id }) else { throw ExportError.noteNotFound }
        let protectedURLs = [notesStorageURL, recoveryBackupURL].compactMap { $0 }
        guard destination.isFileURL,
              !protectedURLs.contains(where: {
                  $0.standardizedFileURL.resolvingSymlinksInPath() == destination.standardizedFileURL.resolvingSymlinksInPath()
              }) else {
            throw ExportError.invalidDestination
        }
        try Data(note.content.utf8).write(to: destination, options: .atomic)
    }

    @discardableResult
    func closeEditor() -> Bool {
        guard !hasPendingChanges || flushPendingChanges() else { return false }
        isEditing = false
        currentNote = nil
        return true
    }

    @discardableResult
    func flushPendingChanges() -> Bool {
        debounceSaveTask?.cancel()
        debounceSaveTask = nil
        return persist()
    }

    /// 只有未保存的编辑需要阻止退出；单纯读取失败仍可正常关闭应用。
    func prepareForTermination() -> Bool {
        !hasPendingChanges || flushPendingChanges()
    }

    @discardableResult
    func retryPersistence() -> Bool {
        if loadFailed {
            loadNotes()
            return !loadFailed && storageErrorMessage == nil
        }
        return flushPendingChanges()
    }

    @discardableResult
    func recoverStorage() -> Bool {
        guard loadFailed else { return flushPendingChanges() }
        let backupURL = notesStorageURL.deletingLastPathComponent()
            .appendingPathComponent("notes.recovery-\(UUID().uuidString).json")
        do {
            // 仅由用户显式恢复触发；原件备份失败时绝不解除写入保护。
            let values = try notesStorageURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else {
                storageErrorMessage = L10n.notesRecoveryFailed
                return false
            }
            try FileManager.default.copyItem(at: notesStorageURL, to: backupURL)
        } catch {
            storageErrorMessage = L10n.notesRecoveryFailed
            return false
        }

        recoveryBackupURL = backupURL
        // 原件已备份，先尝试把它读回来：读取失败可能只是当时的临时状态
        // （权限刚恢复、写入被中断等），直接用空白列表覆盖等于放弃这些笔记。
        loadFailed = false
        if reloadFromStorageIgnoringDrafts() {
            hasPendingChanges = false
            storageErrorMessage = nil
            return true
        }

        // 原件确实无法解析，只能以空列表重建；此时副本是用户找回笔记的唯一途径。
        loadFailed = false
        hasPendingChanges = true
        guard flushPendingChanges() else { return false }
        storageErrorMessage = L10n.notesStorageReset
        return true
    }

    // MARK: - Private

    /// 强制用磁盘内容替换内存列表，不检查未保存草稿。
    /// 仅在原件已被备份后调用，调用方负责处理失败后的重建。
    @discardableResult
    private func reloadFromStorageIgnoringDrafts() -> Bool {
        do {
            let data = try Data(contentsOf: notesStorageURL)
            let decoded = try JSONDecoder().decode([Note].self, from: data)
            notes = decoded
            if let currentNote {
                self.currentNote = notes.first { $0.id == currentNote.id }
                isEditing = self.currentNote != nil
            }
            deletedNote = nil
            loadFailed = false
            storageErrorMessage = nil
            return true
        } catch {
            loadFailed = true
            storageErrorMessage = L10n.notesReadFailed
            return false
        }
    }

    @discardableResult
    private func updateNoteInMemory(_ note: Note) -> Bool {
        guard !isStorageReadOnly, let index = notes.firstIndex(where: { $0.id == note.id }) else { return false }
        notes[index] = note
        if currentNote?.id == note.id {
            currentNote = note
        }
        hasPendingChanges = true
        return true
    }

    @discardableResult
    private func persist() -> Bool {
        guard !loadFailed else { return false }
        guard hasPendingChanges else { return true }
        do {
            let data = try JSONEncoder().encode(notes)
            try FileManager.default.createDirectory(
                at: notesStorageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try writeData(data, notesStorageURL)
            hasPendingChanges = false
            storageErrorMessage = nil
            return true
        } catch {
            storageErrorMessage = L10n.notesSaveFailed
            return false
        }
    }
}
