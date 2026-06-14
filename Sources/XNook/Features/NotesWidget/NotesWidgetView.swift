import SwiftUI

/// 笔记 Widget 视图
struct NotesWidgetView: View {
    @ObservedObject var notesManager: NotesManager
    @State private var editingContent: String = ""

    var body: some View {
        VStack(spacing: 12) {
            // 标题栏
            HStack {
                Image(systemName: "note.text")
                    .font(.system(size: 12))
                    .foregroundColor(.yellow)
                Text("Notes")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(action: {
                    notesManager.createNote()
                    editingContent = ""
                }) {
                    Image(systemName: "plus")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
            }

            if notesManager.isEditing, let note = notesManager.currentNote {
                // 编辑器
                noteEditor(note: note)
            } else {
                // 笔记列表
                noteList
            }
        }
        .padding(16)
        .frame(width: 280)
        .onAppear {
            if let note = notesManager.currentNote {
                editingContent = note.content
            }
        }
    }

    // MARK: - 笔记列表

    private var noteList: some View {
        ScrollView {
            VStack(spacing: 8) {
                if notesManager.notes.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "note.text")
                            .font(.system(size: 20))
                            .foregroundColor(.secondary)
                        Text("No notes")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                } else {
                    ForEach(notesManager.notes) { note in
                        NoteRow(note: note) {
                            notesManager.selectNote(note)
                            editingContent = note.content
                        } onDelete: {
                            notesManager.deleteNote(note)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: 200)
    }

    // MARK: - 笔记编辑器

    private func noteEditor(note: NotesManager.Note) -> some View {
        VStack(spacing: 8) {
            // 编辑器工具栏
            HStack {
                Button(action: {
                    notesManager.closeEditor()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10))
                        Text("Back")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)

                Spacer()

                Text(note.isMarkdown ? "Markdown" : "Plain Text")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(4)
            }

            // 内容编辑区
            TextEditor(text: $editingContent)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(6)
                .frame(height: 150)
                .onChange(of: editingContent) {
                    var updatedNote = note
                    updatedNote.content = editingContent
                    updatedNote.updatedAt = Date()
                    notesManager.saveNote(updatedNote)
                }

            // 保存按钮
            Button(action: {
                var updatedNote = note
                updatedNote.content = editingContent
                updatedNote.updatedAt = Date()
                notesManager.saveNote(updatedNote)
                notesManager.closeEditor()
            }) {
                Text("Save")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(Color.accentColor)
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Note Row

struct NoteRow: View {
    let note: NotesManager.Note
    let onSelect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // 图标
            Image(systemName: note.isMarkdown ? "doc.text" : "note.text")
                .font(.system(size: 14))
                .foregroundColor(.yellow)

            // 内容
            VStack(alignment: .leading, spacing: 2) {
                Text(note.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .foregroundColor(.primary)

                Text(note.content.prefix(50).replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 9))
                    .lineLimit(1)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // 操作按钮
            HStack(spacing: 8) {
                Button(action: onSelect) {
                    Image(systemName: "pencil")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(6)
        .onTapGesture {
            onSelect()
        }
    }
}

// MARK: - Preview

#Preview {
    NotesWidgetView(notesManager: NotesManager())
        .background(Color.black)
}
