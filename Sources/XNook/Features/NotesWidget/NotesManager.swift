import SwiftUI

/// 笔记管理器
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

    // MARK: - Init

    init() {
        loadNotes()
    }

    // MARK: - Public Methods

    func loadNotes() {
        // TODO: 从 UserDefaults 或文件系统加载
        if notes.isEmpty {
            // 创建示例笔记
            notes = [
                Note(title: "Welcome", content: "# Welcome to X Nook\n\nThis is your notes widget.", isMarkdown: true),
                Note(title: "Quick Note", content: "Type your notes here...", isMarkdown: false)
            ]
        }
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
        // TODO: 保存到 UserDefaults 或文件系统
    }

    func deleteNote(_ note: Note) {
        notes.removeAll { $0.id == note.id }
        if currentNote?.id == note.id {
            currentNote = nil
        }
        // TODO: 从 UserDefaults 或文件系统删除
    }

    func selectNote(_ note: Note) {
        currentNote = note
        isEditing = true
    }

    func closeEditor() {
        isEditing = false
        currentNote = nil
    }
}
