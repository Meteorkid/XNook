import SwiftUI
import UniformTypeIdentifiers

/// 概览保留最近笔记，详情提供完整列表和编辑空间。
struct NotesWidgetView: View {
    var notesManager: NotesManager
    var isDetail: Bool = false
    var onShowAll: (() -> Void)? = nil
    var onInteractionChanged: (Bool) -> Void = { _ in }
    var availableHeight: CGFloat? = nil
    @Environment(\.colorScheme) private var colorScheme
    private var noteAccent: Color { colorScheme == .dark ? .yellow : Color(red: 0.55, green: 0.32, blue: 0.02) }

    @State private var showsStorageIssue = false
    @State private var searchQuery = ""
    @State private var exportError: String?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case search, title, content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isDetail ? 12 : 8) {
            header

            if notesManager.canUndoDelete {
                undoDeleteBar
            }

            if notesManager.isEditing, let note = notesManager.currentNote,
               isDetail || availableHeight == nil || onShowAll == nil {
                noteEditor(note: note)
            } else {
                if isDetail {
                    TextField(L10n.notesSearch, text: $searchQuery)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))
                        .focused($focusedField, equals: .search)
                        .accessibilityLabel(L10n.notesSearch)
                }
                noteList
            }

            if !isDetail, let onShowAll {
                Button(L10n.notesShowAll(notesManager.notes.count), action: onShowAll)
                    .font(.system(size: 11, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .expandedPanelDebugFrame(id: "expandedPanelNotesShowAll")
                    .expandedPanelDebugFrame(id: "gridWidgetNotesShowAll")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: notesManager.currentNote?.id, initial: true) { _, id in
            guard id != nil, !notesManager.isStorageReadOnly,
                  isDetail || availableHeight == nil || onShowAll == nil else { return }
            focusedField = notesManager.currentNote?.content.isEmpty == true ? .title : .content
        }
        .onChange(of: showsStorageIssue) { _, isPresented in
            onInteractionChanged(isPresented)
        }
        .onDisappear {
            notesManager.flushPendingChanges()
            onInteractionChanged(false)
        }
        .alert(L10n.notesExportFailed, isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button(L10n.notesDone, role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "note.text")
                .foregroundStyle(noteAccent)
            Text(L10n.widgetNotes)
                .fontWeight(.semibold)
            Spacer(minLength: 0)
            if notesManager.storageErrorMessage != nil || notesManager.recoveryBackupURL != nil {
                Button(action: { showsStorageIssue = true }) {
                    Image(systemName: notesManager.storageErrorMessage == nil ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(notesManager.storageErrorMessage == nil ? .green : .orange)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(notesManager.storageErrorMessage == nil ? L10n.notesShowBackup : L10n.notesStorageWarning)
                .accessibilityLabel(notesManager.storageErrorMessage == nil ? L10n.notesShowBackup : L10n.notesStorageWarning)
                .popover(isPresented: $showsStorageIssue) { storageIssue }
            }
            Button(action: createNote) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(noteAccent)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(notesManager.isStorageReadOnly)
            .help(L10n.notesNew)
            .accessibilityLabel(L10n.notesNew)
        }
        .font(.system(size: 13))
        .frame(minHeight: 24)
    }

    private var undoDeleteBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                Text(L10n.notesDeleted).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                undoDeleteButton
            }
            undoDeleteButton
        }
        .font(.system(size: isDetail ? 12 : 11))
    }

    private var undoDeleteButton: some View {
        // 不注册 Command-Z，文字编辑器继续使用自身的撤销栈。
        Button(L10n.notesUndoDelete) { notesManager.undoDelete() }
            .buttonStyle(.plain)
            .foregroundStyle(noteAccent)
            .padding(.vertical, 5)
    }

    private var storageIssue: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(notesManager.storageErrorMessage ?? L10n.notesRecovered)
                .font(.system(size: 12))
            if notesManager.storageErrorMessage != nil {
                HStack {
                    Button(L10n.notesRetry) {
                        if notesManager.retryPersistence() { showsStorageIssue = false }
                    }
                    if notesManager.isStorageReadOnly {
                        Button(L10n.notesRecover) {
                            if notesManager.recoverStorage() { showsStorageIssue = false }
                        }
                    }
                }
            }
            if let backupURL = notesManager.recoveryBackupURL {
                Button(L10n.notesShowBackup) {
                    NSWorkspace.shared.activateFileViewerSelecting([backupURL])
                }
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private var visibleNotes: [NotesManager.Note] {
        let reserved: CGFloat = 54 + (notesManager.canUndoDelete ? 30 : 0)
        let limit = GridWidgetContentLayout.rowLimit(height: availableHeight, reserved: reserved, rowHeight: 44, maximum: 3)
        return isDetail ? notesManager.filteredNotes(matching: searchQuery) : Array(notesManager.notes.prefix(limit))
    }

    private var noteList: some View {
        LazyVStack(alignment: .leading, spacing: isDetail ? 6 : 4) {
            if visibleNotes.isEmpty {
                Group {
                    if isDetail || availableHeight == nil {
                        VStack(spacing: 8) {
                            Image(systemName: "note.text")
                                .font(.system(size: 20))
                            Text(notesManager.notes.isEmpty ? L10n.noNotes : L10n.notesNoMatches)
                            if isDetail {
                                Text(notesManager.notes.isEmpty ? L10n.notesEmptyHint : L10n.notesSearchHint)
                                    .font(.system(size: 12))
                            }
                        }
                    } else {
                        Label(L10n.noNotes, systemImage: "note.text")
                            .font(.system(size: 11))
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            } else {
                if isDetail {
                    Text(L10n.notesCount(visibleNotes.count))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                ForEach(visibleNotes) { note in
                    noteRow(note: note)
                }
            }
        }
    }

    private func noteRow(note: NotesManager.Note) -> some View {
        Button {
            guard notesManager.selectNote(id: note.id) else { return }
            if !isDetail { onShowAll?() }
            focusedField = .content
        } label: {
            HStack(spacing: 8) {
                Image(systemName: note.isMarkdown ? "doc.text" : "note.text")
                    .font(.system(size: 13))
                    .foregroundStyle(note.isMarkdown ? noteAccent : .blue)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(note.title.isEmpty ? L10n.notesUntitled : note.title)
                        .font(.system(size: isDetail ? 13 : 12, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(note.content.isEmpty ? L10n.notesNoContent : note.content.prefix(120).replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, isDetail ? 10 : 0)
            .padding(.vertical, isDetail ? 10 : 4)
            .background(Color.secondary.opacity(isDetail ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .expandedPanelDebugFrame(id: "expandedPanelNote-\(note.id.uuidString)")
        .expandedPanelDebugFrame(id: "gridWidgetNotesRow-\(note.id.uuidString)")
        .contextMenu {
            Button(L10n.notesDelete, role: .destructive) { notesManager.deleteNote(note) }
                .disabled(notesManager.isStorageReadOnly)
        }
    }

    private func noteEditor(note: NotesManager.Note) -> some View {
        VStack(alignment: .leading, spacing: isDetail ? 10 : 6) {
            HStack(spacing: 4) {
                Button(action: closeEditor) {
                    Label(L10n.back, systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
                Spacer(minLength: 0)
                Menu {
                    Button(L10n.notesExportMarkdown) { export(note, format: .markdown) }
                    Button(L10n.notesExportText) { export(note, format: .plainText) }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(L10n.notesExport)
                .accessibilityLabel(L10n.notesExport)
                Button(role: .destructive) {
                    notesManager.deleteNote(note)
                    focusedField = nil
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(notesManager.isStorageReadOnly)
                .help(L10n.notesDelete)
                .accessibilityLabel(L10n.notesDelete)
            }
            .font(.system(size: isDetail ? 12 : 11))

            TextField(L10n.notesTitle, text: Binding(
                get: { notesManager.currentNote?.title ?? "" },
                set: {
                    guard notesManager.currentNote?.id == note.id else { return }
                    notesManager.updateCurrentNoteTitle($0)
                }
            ))
            .font(.system(size: isDetail ? 15 : 13, weight: .semibold))
            .textFieldStyle(.plain)
            .focused($focusedField, equals: .title)
            .disabled(notesManager.isStorageReadOnly)
            .accessibilityLabel(L10n.notesTitle)

            TextEditor(text: Binding(
                get: { notesManager.currentNote?.content ?? "" },
                set: {
                    guard notesManager.currentNote?.id == note.id else { return }
                    notesManager.updateCurrentNoteContent($0)
                }
            ))
            .font(.system(size: isDetail ? 13 : 12, design: note.isMarkdown ? .monospaced : .default))
            .scrollContentBackground(.hidden)
            .padding(4)
            .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            .frame(height: isDetail ? 240 : 100)
            .focused($focusedField, equals: .content)
            .disabled(notesManager.isStorageReadOnly)
            .accessibilityLabel(L10n.notesContent)

            HStack {
                Text(note.isMarkdown ? L10n.markdown : L10n.plainText)
                    .font(.system(size: isDetail ? 12 : 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button(L10n.notesDone, action: closeEditor)
                    .font(.system(size: isDetail ? 12 : 11, weight: .medium))
                    .buttonStyle(.bordered)
                    .tint(noteAccent)
            }
        }
        .id(note.id)
    }

    private func createNote() {
        guard notesManager.createNote(title: L10n.notesUntitled) != nil else { return }
        searchQuery = ""
        if !isDetail { onShowAll?() }
        focusedField = .title
    }

    private func closeEditor() {
        if notesManager.isStorageReadOnly || notesManager.flushPendingChanges() {
            notesManager.closeEditor()
            focusedField = nil
        } else {
            showsStorageIssue = true
        }
    }

    private func export(_ note: NotesManager.Note, format: NotesManager.ExportFormat) {
        let panel = NSSavePanel()
        panel.title = L10n.notesExport
        panel.allowedContentTypes = [format == .markdown ? (UTType(filenameExtension: "md") ?? .plainText) : .plainText]
        panel.nameFieldStringValue = notesManager.exportFileName(for: notesManager.currentNote ?? note, format: format)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try notesManager.exportNote(id: note.id, to: destination, format: format)
        } catch {
            exportError = error.localizedDescription
        }
    }
}
