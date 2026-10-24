import SwiftUI
import UniformTypeIdentifiers

/// 任务资料按 ID 实时读取；历史快照不依赖文件架或笔记组件是否显示。
struct FocusSessionResourcesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showsFilePicker = false
    @State private var replacementFileID: UUID?
    @State private var fileSelectionError: String?
    @State private var webAddress = ""
    @State private var webTitle = ""
    @State private var budgetMinutes = "25"
    @State private var inputError: String?
    @State private var linkEdit: TaskLinkEditDraft?
    @State private var showsInbox = false

    let sessionID: UUID
    let resources: FocusResourceCoordinator
    let pendingTasks: PendingTaskCoordinator?
    @Binding var showsNoteEditor: Bool
    @Binding var showsLinkEditor: Bool

    init(sessionID: UUID, resources: FocusResourceCoordinator, showsNoteEditor: Binding<Bool>,
         showsLinkEditor: Binding<Bool> = .constant(false), pendingTasks: PendingTaskCoordinator? = nil) {
        self.sessionID = sessionID
        self.resources = resources
        self.pendingTasks = pendingTasks
        _showsNoteEditor = showsNoteEditor
        _showsLinkEditor = showsLinkEditor
    }

    private var writesBlocked: Bool { resources.manager.storageError != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L10n.flowTaskDetails).font(.headline)
                Spacer()
                Button(L10n.flowClose) { dismiss() }
                    .disabled(showsNoteEditor || showsLinkEditor)
            }
            if let session = resources.manager.session(id: sessionID) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(session.title)
                            .font(.title3.weight(.semibold))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L10n.flowStarted(session.startedAt.formatted(date: .abbreviated, time: .shortened)))
                            if let endedAt = session.endedAt {
                                Text(L10n.flowEnded(endedAt.formatted(date: .abbreviated, time: .shortened)))
                            }
                            if let planned = session.scheduledEndAt {
                                Text(L10n.flowBudgetEnd(planned.formatted(date: .abbreviated, time: .shortened)))
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        if pendingTasks != nil {
                            Button { showsInbox = true } label: {
                                Label(L10n.inboxTitle, systemImage: "tray")
                            }
                            .disabled(showsNoteEditor || showsLinkEditor)
                        }
                        Divider()
                        noteSection(for: session)
                        Divider()
                        filesSection(for: session)
                        Divider()
                        webLinksSection(for: session)
                        Divider()
                        budgetSection(for: session)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text(L10n.flowResourceTaskMissing).foregroundStyle(.secondary)
                linkEditor
            }
            if let error = fileSelectionError ?? inputError ?? resources.errorMessage ?? resources.manager.storageError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if resources.manager.storageError != nil {
                Button(L10n.flowRetry) {
                    if resources.manager.retryLoadingStorage() { resources.clearError() }
                }
            }
        }
        .padding(18)
        .frame(width: 420, height: 430)
        .interactiveDismissDisabled(showsNoteEditor || showsLinkEditor)
        .sheet(isPresented: Self.editorPresentationBinding($showsNoteEditor, notes: resources.notes)) {
            noteEditor
        }
        .popover(isPresented: $showsInbox) {
            if let pendingTasks {
                TaskInboxView(coordinator: pendingTasks, onClose: { showsInbox = false })
            }
        }
        .fileImporter(isPresented: $showsFilePicker, allowedContentTypes: [.item]) { result in
            defer { replacementFileID = nil }
            guard let fileID = replacementFileID else { return }
            switch result {
            case .success(let url):
                fileSelectionError = nil
                resources.replaceFile(id: fileID, in: sessionID, with: url)
            case .failure(let error):
                if (error as? CocoaError)?.code != .userCancelled {
                    fileSelectionError = L10n.flowFileSelectionFailed
                }
            }
        }
    }

    private func webLinksSection(for session: FocusSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L10n.flowWebLinks, systemImage: "link").font(.subheadline.weight(.semibold))
            if session.taskURLs.isEmpty { Text(L10n.flowNoWebLinks).foregroundStyle(.secondary) }
            ForEach(session.taskURLs) { link in
                if linkEdit?.original.id == link.id {
                    linkEditor
                } else {
                    webLinkRow(link)
                }
            }
            // 存储重载后原链接可能已移除；仍展示草稿，供用户复制或取消。
            if let linkEdit, !session.taskURLs.contains(where: { $0.id == linkEdit.original.id }) {
                linkEditor
            }
            TextField(L10n.flowWebAddress, text: $webAddress).textFieldStyle(.roundedBorder)
                .accessibilityLabel(L10n.flowWebAddressLabel)
            TextField(L10n.flowWebTitle, text: $webTitle).textFieldStyle(.roundedBorder)
            Button(L10n.flowAddWebLink) {
                inputError = nil
                fileSelectionError = nil
                if resources.addTaskURL(urlString: webAddress, title: webTitle, to: sessionID) {
                    webAddress = ""
                    webTitle = ""
                }
            }
            .disabled(writesBlocked || linkEdit != nil || webAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Text(L10n.flowWebLinkRule).font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }

    private func webLinkRow(_ link: LinkedTaskURL) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(link.title).fontWeight(.medium).fixedSize(horizontal: false, vertical: true)
            Text(link.urlString).font(.caption).foregroundStyle(.secondary)
                .lineLimit(2).textSelection(.enabled)
            HStack {
                Button(L10n.flowOpen) { resources.openTaskURL(id: link.id, in: sessionID) }
                    .disabled(link.validatedURL == nil)
                    .accessibilityLabel(L10n.flowOpen + " " + link.title)
                Button(L10n.flowEditWebLink) {
                    clearInputErrors()
                    linkEdit = TaskLinkEditDraft(link: link)
                    showsLinkEditor = true
                }
                .disabled(writesBlocked || linkEdit != nil)
                .accessibilityLabel(L10n.flowEditWebLink + " " + link.title)
                Button(L10n.flowUnlink) { resources.unlinkTaskURL(id: link.id, from: sessionID) }
                    .disabled(writesBlocked || linkEdit != nil)
                    .accessibilityLabel(L10n.flowUnlink + " " + link.title)
            }
        }
    }

    @ViewBuilder
    private var linkEditor: some View {
        if let draft = Binding($linkEdit) {
            TaskLinkEditorView(draft: draft, writesBlocked: writesBlocked, onSave: {
                guard let edit = linkEdit else { return }
                clearInputErrors()
                if resources.editTaskURL(edit.original, urlString: edit.address, title: edit.title, in: sessionID) {
                    linkEdit = nil
                    showsLinkEditor = false
                }
            }, onCancel: {
                linkEdit = nil
                showsLinkEditor = false
                clearInputErrors()
            })
        }
    }

    private func clearInputErrors() {
        inputError = nil
        fileSelectionError = nil
        resources.clearError()
    }

    private func budgetSection(for session: FocusSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L10n.flowTimeBudget, systemImage: "clock").font(.subheadline.weight(.semibold))
            if let end = session.scheduledEndAt {
                Text(L10n.flowBudgetEnd(end.formatted(date: .abbreviated, time: .shortened)))
            } else {
                Text(L10n.flowNoBudget).foregroundStyle(.secondary)
            }
            if session.isEnded {
                Text(L10n.flowBudgetHistoryReadOnly).font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    TextField(L10n.flowBudgetMinutes, text: $budgetMinutes)
                        .textFieldStyle(.roundedBorder).frame(width: 70)
                        .accessibilityLabel(L10n.flowTimeBudget + " " + L10n.flowBudgetMinutes)
                        .onSubmit { applyBudget() }
                    Text(L10n.flowBudgetMinutes)
                    Button(L10n.flowApplyBudget, action: applyBudget).disabled(writesBlocked)
                    Button(L10n.flowClearBudget) {
                        inputError = nil
                        fileSelectionError = nil
                        resources.setTimeBudget(minutes: nil, in: sessionID)
                    }
                    .disabled(writesBlocked || session.scheduledEndAt == nil)
                }
                .controlSize(.small)
                Text(L10n.flowBudgetHelp).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.callout)
    }

    private func applyBudget() {
        fileSelectionError = nil
        guard let minutes = Int(budgetMinutes.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...1440).contains(minutes) else {
            inputError = L10n.flowBudgetInvalid
            return
        }
        inputError = nil
        resources.setTimeBudget(minutes: minutes, in: sessionID)
    }

    private func noteSection(for session: FocusSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L10n.flowLinkedNote, systemImage: "note.text").font(.subheadline.weight(.semibold))
            if let note = session.linkedNote {
                Text(note.title)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(L10n.flowOpen) { openNote() }
                    Button(L10n.flowUnlink) { resources.unlinkNote(in: sessionID) }
                        .disabled(writesBlocked)
                }
            } else {
                Text(L10n.flowNoLinkedNote).foregroundStyle(.secondary)
            }
            HStack {
                // 有效关联直接打开；解除关联后可以创建另一篇笔记。
                if session.linkedNote == nil || !resources.notes.notes.contains(where: { $0.id == session.linkedNote?.id }) {
                    Button(L10n.flowCreateNote) {
                        if resources.createNote(in: sessionID) { showsNoteEditor = true }
                    }
                    .disabled(writesBlocked || resources.notes.isStorageReadOnly)
                }
                Menu(session.linkedNote == nil ? L10n.flowRelinkNote : L10n.flowChangeNote) {
                    ForEach(resources.notes.notes) { note in
                        Button(note.title) { resources.linkNote(id: note.id, to: sessionID) }
                    }
                }
                .disabled(writesBlocked || resources.notes.isStorageReadOnly || resources.notes.notes.isEmpty)
            }
        }
        .font(.callout)
    }

    private func filesSection(for session: FocusSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L10n.flowLinkedFiles, systemImage: "tray.full").font(.subheadline.weight(.semibold))
            if session.linkedFiles.isEmpty {
                Text(L10n.flowNoLinkedFiles).foregroundStyle(.secondary)
            }
            ForEach(session.linkedFiles, id: \.id) { file in
                VStack(alignment: .leading, spacing: 6) {
                    Label(file.name, systemImage: file.icon)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(L10n.flowOpen) { resources.openFile(id: file.id, in: sessionID) }
                        Button(L10n.flowReselectFile) {
                            fileSelectionError = nil
                            replacementFileID = file.id
                            showsFilePicker = true
                        }
                        .disabled(writesBlocked)
                        Button(L10n.flowUnlink) { resources.unlinkFile(id: file.id, from: sessionID) }
                            .disabled(writesBlocked)
                    }
                }
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
            }
            Button(resources.tray.files.isEmpty ? L10n.flowEmptyTray : L10n.flowLinkTray) {
                resources.linkTrayFiles(to: sessionID)
            }
            .disabled(writesBlocked || resources.tray.files.isEmpty)
        }
        .font(.callout)
    }

    private func openNote() {
        if resources.openNote(in: sessionID) { showsNoteEditor = true }
    }

    private var noteEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(resources.notes.currentNote?.title ?? L10n.flowLinkedNote)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(L10n.flowClose) {
                    Self.editorPresentationBinding($showsNoteEditor, notes: resources.notes).wrappedValue = false
                }
            }
            NotesWidgetView(notesManager: resources.notes)
            if let error = resources.notes.storageErrorMessage {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(18)
        .frame(width: 410)
        .interactiveDismissDisabled()
    }

    /// 所有关闭入口都先提交现有编辑，失败时让原编辑器继续展示。
    static func editorPresentationBinding(
        _ presented: Binding<Bool>, notes: NotesManager,
        shouldDiscardPendingChanges: @escaping @MainActor () -> Bool = {
            AppDelegate.shared?.discardsPendingNotesOnTermination == true
        }
    ) -> Binding<Bool> {
        Binding(get: { presented.wrappedValue }, set: { value in
            if value || shouldDiscardPendingChanges() || notes.closeEditor() { presented.wrappedValue = value }
        })
    }
}

struct FocusSessionHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedSessionID: UUID?
    @State private var showsInbox = false
    let resources: FocusResourceCoordinator
    let pendingTasks: PendingTaskCoordinator?
    @Binding var showsNoteEditor: Bool
    @Binding var showsLinkEditor: Bool

    init(resources: FocusResourceCoordinator, showsNoteEditor: Binding<Bool>,
         showsLinkEditor: Binding<Bool> = .constant(false), pendingTasks: PendingTaskCoordinator? = nil) {
        self.resources = resources
        self.pendingTasks = pendingTasks
        _showsNoteEditor = showsNoteEditor
        _showsLinkEditor = showsLinkEditor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let selectedSessionID {
                Button(L10n.flowBackToHistory) {
                    self.selectedSessionID = nil
                    resources.clearError()
                }
                .disabled(showsNoteEditor || showsLinkEditor)
                .padding([.horizontal, .top], 18)
                FocusSessionResourcesView(
                    sessionID: selectedSessionID, resources: resources, showsNoteEditor: $showsNoteEditor,
                    showsLinkEditor: $showsLinkEditor, pendingTasks: pendingTasks
                )
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(L10n.flowAllTasks).font(.headline)
                        Spacer()
                        Button(L10n.flowClose) { dismiss() }
                    }
                    if pendingTasks != nil {
                        Button { showsInbox = true } label: {
                            Label(L10n.inboxTitle, systemImage: "tray")
                        }
                    }
                    if resources.manager.history.isEmpty {
                        Text(L10n.flowNoHistory).foregroundStyle(.secondary)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 10) {
                                ForEach(resources.manager.history) { session in
                                    Button {
                                        resources.clearError()
                                        selectedSessionID = session.id
                                    } label: {
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(session.title)
                                                .font(.callout.weight(.medium))
                                                .fixedSize(horizontal: false, vertical: true)
                                            if let endedAt = session.endedAt {
                                                Text(endedAt.formatted(date: .abbreviated, time: .shortened))
                                                    .font(.caption).foregroundStyle(.secondary)
                                            }
                                            HStack(spacing: 8) {
                                                if session.linkedNote != nil {
                                                    Label(L10n.flowLinkedNote, systemImage: "note.text")
                                                }
                                                if !session.linkedFiles.isEmpty {
                                                    Label(L10n.flowFileCount(session.linkedFiles.count), systemImage: "tray.full")
                                                }
                                            }
                                            .font(.caption).foregroundStyle(.secondary)
                                        }
                                        .padding(10)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .padding(18)
                .frame(width: 420, height: 430)
            }
        }
        .interactiveDismissDisabled(showsNoteEditor || showsLinkEditor)
        .popover(isPresented: $showsInbox) {
            if let pendingTasks {
                TaskInboxView(coordinator: pendingTasks, onClose: { showsInbox = false })
            }
        }
    }
}
