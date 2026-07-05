import SwiftUI

/// 笔记管理器 — 使用文件系统存储，避免 UserDefaults 大数据量问题
@MainActor
final class NotesManager: ObservableObject {
    // MARK: - Published Properties

    @Published var notes: [Note] = []
    @Published var currentNote: Note?
    @Published var isEditing = false

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

    // MARK: - Storage

    private static var storageURL: URL {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            fatalError("[XNook] Unable to locate application support directory")
        }
        return appSupport.appendingPathComponent("XNook/notes.json")
    }

    // MARK: - Init

    init() {
        loadNotes()
    }

    // MARK: - Public Methods

    func loadNotes() {
        let url = Self.storageURL
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Note].self, from: data) else {
            // 首次启动：创建示例笔记
            notes = [
                Note(title: "Welcome", content: "# Welcome to X Nook\n\nThis is your notes widget.", isMarkdown: true),
                Note(title: "Quick Note", content: "Type your notes here...", isMarkdown: false)
            ]
            persist()
            return
        }
        notes = decoded
    }

    func createNote() {
        let note = Note()
        notes.insert(note, at: 0)
        currentNote = note
        isEditing = true
    }

    func saveNote(_ note: Note) {
        if let index = notes.firstIndex(where: { $0.id == note.id }) {
            notes[index] = note
        }
        persist()
    }

    /// 防抖保存：连续编辑时延迟 0.5s 写入磁盘，避免每次按键都 I/O
    func saveNoteDebounced(_ note: Note) {
        debounceSaveTask?.cancel()
        debounceSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            guard !Task.isCancelled, let self else { return }
            if let index = self.notes.firstIndex(where: { $0.id == note.id }) {
                self.notes[index] = note
            }
            self.persist()
        }
    }

    func deleteNote(_ note: Note) {
        notes.removeAll { $0.id == note.id }
        if currentNote?.id == note.id {
            currentNote = nil
        }
        persist()
    }

    func selectNote(_ note: Note) {
        currentNote = note
        isEditing = true
    }

    func closeEditor() {
        isEditing = false
        currentNote = nil
    }

    // MARK: - Private

    private func persist() {
        guard let data = try? JSONEncoder().encode(notes) else { return }
        let url = Self.storageURL
        // 确保目录存在
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}
