import SwiftUI

/// 笔记 Widget 视图
struct NotesWidgetView: View {
    @ObservedObject var notesManager: NotesManager
    @State private var editingContent: String = ""

    var body: some View {
        VStack(spacing: 6) {
            // 标题
            HStack {
                Image(systemName: "note.text")
                    .font(.system(size: 10))
                    .foregroundColor(.yellow)
                Text(L10n.widgetNotes)
                    .font(.system(size: 10, weight: .semibold))
                Spacer()
                Button(action: {
                    notesManager.createNote()
                    editingContent = ""
                }) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.yellow)
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
    }

    // MARK: - 笔记列表

    private var noteList: some View {
        VStack(spacing: 4) {
            if notesManager.notes.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "note.text")
                        .font(.system(size: 18))
                        .foregroundColor(.secondary)
                    Text(L10n.noNotes)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else {
                ForEach(notesManager.notes.prefix(4)) { note in
                    noteRow(note: note)
                }
            }
        }
    }

    // MARK: - 笔记行

    private func noteRow(note: NotesManager.Note) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3)
                .fill(note.isMarkdown ? Color.yellow.opacity(0.2) : Color.blue.opacity(0.2))
                .frame(width: 18, height: 18)
                .overlay(
                    Image(systemName: note.isMarkdown ? "doc.text" : "note.text")
                        .font(.system(size: 9))
                        .foregroundColor(note.isMarkdown ? .yellow : .blue)
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(note.title)
                    .font(.system(size: 9, weight: .medium))
                    .lineLimit(1)
                    .foregroundColor(.primary)

                Text(note.content.prefix(25).replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 8))
                    .lineLimit(1)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button(action: {
                notesManager.selectNote(note)
                editingContent = note.content
            }) {
                Image(systemName: "pencil.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(6)
    }

    // MARK: - 笔记编辑器

    private func noteEditor(note: NotesManager.Note) -> some View {
        VStack(spacing: 4) {
            // 工具栏
            HStack {
                Button(action: { notesManager.closeEditor() }) {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 8))
                        Text(L10n.back)
                            .font(.system(size: 9, weight: .medium))
                    }
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)

                Spacer()

                Text(note.isMarkdown ? L10n.markdown : L10n.plainText)
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(3)
            }

            // 内容编辑区
            TextEditor(text: $editingContent)
                .font(.system(size: 10, design: .monospaced))
                .scrollContentBackground(.hidden)
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(4)
                .frame(height: 80)
                .onChange(of: editingContent) { _, _ in
                    var updatedNote = note
                    updatedNote.content = editingContent
                    updatedNote.updatedAt = Date()
                    notesManager.saveNoteDebounced(updatedNote)
                }

            // 保存按钮
            Button(action: {
                var updatedNote = note
                updatedNote.content = editingContent
                updatedNote.updatedAt = Date()
                notesManager.saveNote(updatedNote)
                notesManager.closeEditor()
            }) {
                Text(L10n.save)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(Color.yellow)
                    .cornerRadius(4)
            }
            .buttonStyle(.plain)
        }
    }
}

#Preview {
    NotesWidgetView(notesManager: NotesManager())
        .background(Color.black)
}
