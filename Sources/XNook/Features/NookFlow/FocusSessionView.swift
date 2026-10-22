import SwiftUI

/// 任务入口、当前任务与资料历史共用一块区域；资源打开由父视图协调各 Manager。
struct FocusSessionView: View {
    @FocusState private var titleFocused: Bool
    @State private var taskTitle = ""
    @State private var isHistoryPresented = false
    @State private var isFilesPresented = false
    @State private var selectedHistoryID: UUID?
    @State private var resourceError: String?
    @State private var linkSessionID: UUID?
    @State private var isEditingLink = false

    let manager: FocusSessionManager
    let historyDisplayLimit: Int
    let trayFileCount: Int
    let onCreateLinkedNote: () -> Bool
    let onLinkTrayFiles: () -> Void
    let onEndSession: () -> Void
    let showHistory: Bool
    let onOpenNote: ((UUID) -> Bool)?
    let onOpenFile: ((LinkedFile) -> Bool)?
    let onInteractionChanged: (Bool) -> Void
    /// 链接面板展示状态回调：展开期间父视图需要暂停面板自动收起。
    var onLinksPresentationChanged: (Bool) -> Void = { _ in }

    init(
        manager: FocusSessionManager,
        historyDisplayLimit: Int,
        trayFileCount: Int,
        onCreateLinkedNote: @escaping () -> Bool,
        onLinkTrayFiles: @escaping () -> Void,
        onEndSession: @escaping () -> Void,
        showHistory: Bool = true,
        onOpenNote: ((UUID) -> Bool)? = nil,
        onOpenFile: ((LinkedFile) -> Bool)? = nil,
        onInteractionChanged: @escaping (Bool) -> Void = { _ in },
        onLinksPresentationChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.manager = manager
        self.historyDisplayLimit = historyDisplayLimit
        self.trayFileCount = trayFileCount
        self.onCreateLinkedNote = onCreateLinkedNote
        self.onLinkTrayFiles = onLinkTrayFiles
        self.onEndSession = onEndSession
        self.showHistory = showHistory
        self.onOpenNote = onOpenNote
        self.onOpenFile = onOpenFile
        self.onInteractionChanged = onInteractionChanged
        self.onLinksPresentationChanged = onLinksPresentationChanged
    }

    static let storageIssueHeight: CGFloat = 28
    static let defaultHistoryDisplayLimit = 3
    static let historyDisplayLimitRange = 1...5
    // 保留原尺寸估算 API 供旧调用方使用；新面板按内容测量，不限制可点击行高度。
    static let historyRowHeight: CGFloat = 15

    static func sanitizedHistoryDisplayLimit(_ value: Int) -> Int {
        min(max(value, historyDisplayLimitRange.lowerBound), historyDisplayLimitRange.upperBound)
    }

    static func historyListHeight(for recordCount: Int) -> CGFloat {
        24 + CGFloat(max(0, recordCount)) * historyRowHeight
    }

    private var isInteracting: Bool {
        titleFocused || isHistoryPresented || isFilesPresented || linkSessionID != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = manager.storageError {
                feedback(error)
                Button(L10n.flowRetry) { manager.retryLoadingStorage() }
                    .buttonStyle(.bordered)
            }
            taskAndHistory
            if let message = manager.activityMessage {
                feedback(message)
            }
            if let error = resourceError, !isHistoryPresented, !isFilesPresented {
                feedback(error)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(IslandStyle.primaryText)
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .onChange(of: isInteracting) { _, interacting in
            onInteractionChanged(interacting)
        }
        .onDisappear { onInteractionChanged(false) }
        .popover(isPresented: $isHistoryPresented, arrowEdge: .bottom) {
            historyBrowser
        }
        .popover(isPresented: $isFilesPresented, arrowEdge: .bottom) {
            if let session = manager.activeSession {
                resourceBrowser(for: session)
            }
        }
        .popover(isPresented: Self.guardedPresentationBinding(
            Binding(get: { linkSessionID != nil }, set: { presented in
                if !presented {
                    linkSessionID = nil
                    onLinksPresentationChanged(false)
                }
            }), isEditing: { isEditingLink }
        )) {
            if let linkSessionID {
                TaskLinksView(manager: manager, sessionID: linkSessionID, isEditing: $isEditingLink)
            }
        }
        .onDisappear { onLinksPresentationChanged(false) }
    }

    /// 编辑未结束时不允许外部收起链接面板，避免丢失正在编辑的内容。
    static func guardedPresentationBinding(
        _ presented: Binding<Bool>,
        isEditing: @escaping () -> Bool
    ) -> Binding<Bool> {
        Binding(get: { presented.wrappedValue }, set: { value in
            if value || !isEditing() { presented.wrappedValue = value }
        })
    }

    private func showLinks(for sessionID: UUID) {
        guard !isEditingLink else { return }
        linkSessionID = sessionID
        onLinksPresentationChanged(true)
    }

    @ViewBuilder
    private var taskAndHistory: some View {
        if showHistory, !manager.history.isEmpty {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    taskContent
                        .frame(minWidth: 220, idealWidth: 220, maxWidth: .infinity, alignment: .topLeading)
                    historyList
                        .frame(minWidth: 250, idealWidth: 250, maxWidth: .infinity, alignment: .topLeading)
                }
                VStack(alignment: .leading, spacing: 8) {
                    taskContent
                    Divider()
                    historyList
                }
            }
        } else {
            taskContent
        }
    }

    @ViewBuilder
    private var taskContent: some View {
        if let session = manager.activeSession {
            activeCard(for: session)
        } else {
            manualTaskEntry
        }
    }

    private var manualTaskEntry: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.sectionNookFlow)
                .font(.system(size: 13, weight: .semibold))
            TextField(L10n.flowTaskPlaceholder, text: $taskTitle)
                .textFieldStyle(.roundedBorder)
                .focused($titleFocused)
                .onSubmit(startManualTask)
                .disabled(manager.storageError != nil)
            Button(action: startManualTask) {
                Label(L10n.flowStartTask, systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(manager.storageError != nil)
        }
    }

    private func startManualTask() {
        guard manager.start(title: taskTitle) != nil else { return }
        taskTitle = ""
        titleFocused = false
        resourceError = nil
    }

    private func activeCard(for session: FocusSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L10n.flowActive, systemImage: "circle.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.green)
            Text(session.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text(L10n.flowStarted(session.startedAt.formatted(date: .omitted, time: .shortened)))
                    Spacer(minLength: 8)
                    elapsedTime(for: session)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.flowStarted(session.startedAt.formatted(date: .omitted, time: .shortened)))
                    elapsedTime(for: session)
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(IslandStyle.secondaryText)

            noteButton(for: session)
            webLinkButton(for: session)
            if !session.linkedFiles.isEmpty {
                Button {
                    resourceError = nil
                    isFilesPresented = true
                } label: {
                    Label(L10n.flowFileCount(session.linkedFiles.count), systemImage: "folder")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    linkTrayButton
                    endSessionButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    linkTrayButton
                    endSessionButton
                }
            }
        }
    }

    private func elapsedTime(for session: FocusSession) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(elapsedString(from: session.startedAt, to: context.date))
                .monospacedDigit()
        }
    }

    private func webLinkButton(for session: FocusSession) -> some View {
        Button { showLinks(for: session.id) } label: {
            Label(
                session.taskURLs.isEmpty ? L10n.flowWebLinks : L10n.flowWebLinks + " (\(session.taskURLs.count))",
                systemImage: "link"
            )
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.bordered)
        .disabled(manager.storageError != nil)
        .help(L10n.flowWebLinks)
        .accessibilityLabel(L10n.flowWebLinks + " " + session.title)
    }

    private func noteButton(for session: FocusSession) -> some View {
        Button {
            resourceError = nil
            if let note = session.linkedNote {
                openNote(note)
            } else {
                if !onCreateLinkedNote() {
                    resourceError = L10n.flowNoteCreationFailed
                }
            }
        } label: {
            Label(session.linkedNote?.title ?? L10n.flowCreateNote, systemImage: "note.text")
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .disabled(manager.storageError != nil && session.linkedNote == nil)
    }

    private var linkTrayButton: some View {
        Button(action: onLinkTrayFiles) {
            Label(trayFileCount == 0 ? L10n.flowEmptyTray : L10n.flowLinkTray, systemImage: "tray")
                .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.bordered)
        .disabled(trayFileCount == 0 || manager.storageError != nil)
    }

    private var endSessionButton: some View {
        Button(L10n.flowEndTask) {
            resourceError = nil
            isFilesPresented = false
            onEndSession()
        }
        .buttonStyle(.bordered)
        .disabled(manager.storageError != nil)
    }

    private var historyList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.flowRecentTasks)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(IslandStyle.secondaryText)
            ForEach(manager.history.prefix(Self.sanitizedHistoryDisplayLimit(historyDisplayLimit))) { record in
                Button {
                    selectedHistoryID = record.id
                    resourceError = nil
                    isHistoryPresented = true
                } label: {
                    historyRow(record)
                }
                .buttonStyle(.plain)
            }
            Button(L10n.flowViewAll(manager.history.count)) {
                selectedHistoryID = nil
                resourceError = nil
                isHistoryPresented = true
            }
            .buttonStyle(.bordered)
        }
    }

    private func historyRow(_ record: FocusSession) -> some View {
        HStack(spacing: 8) {
            Text(record.title)
                .lineLimit(1)
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(IslandStyle.secondaryText)
        }
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var historyBrowser: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if selectedHistoryID != nil {
                    Button {
                        selectedHistoryID = nil
                        resourceError = nil
                    } label: {
                        Label(L10n.back, systemImage: "chevron.left")
                    }
                }
                Text(L10n.flowAllTasks).font(.headline)
                Spacer()
                Button(L10n.flowClose) { isHistoryPresented = false }
            }
            ScrollView {
                if let record = manager.history.first(where: { $0.id == selectedHistoryID }) {
                    sessionDetails(record)
                } else {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(manager.history) { record in
                            Button {
                                selectedHistoryID = record.id
                                resourceError = nil
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    historyRow(record)
                                    if let endedAt = record.endedAt {
                                        Text(endedAt.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                    }
                }
            }
        }
        .font(.system(size: 13))
        .padding(16)
        .frame(width: 340, height: 400)
    }

    private func resourceBrowser(for session: FocusSession) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.flowTaskDetails).font(.headline)
                Spacer()
                Button(L10n.flowClose) { isFilesPresented = false }
            }
            ScrollView { sessionDetails(session) }
        }
        .font(.system(size: 13))
        .padding(16)
        .frame(width: 340, height: 360)
    }

    private func sessionDetails(_ session: FocusSession) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(session.title).font(.headline).textSelection(.enabled)
            Text(L10n.flowStarted(session.startedAt.formatted(date: .abbreviated, time: .shortened)))
                .font(.caption).foregroundStyle(.secondary)
            if let endedAt = session.endedAt {
                Text(L10n.flowEnded(endedAt.formatted(date: .abbreviated, time: .shortened)))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let note = session.linkedNote {
                Text(L10n.flowLinkedNote).font(.subheadline).foregroundStyle(.secondary)
                Button { openNote(note) } label: {
                    Label(note.title, systemImage: "note.text")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
            }
            if !session.linkedFiles.isEmpty {
                Text(L10n.flowLinkedFiles).font(.subheadline).foregroundStyle(.secondary)
                ForEach(session.linkedFiles, id: \.id) { file in
                    Button { openFile(file) } label: {
                        Label(file.name, systemImage: file.icon)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .buttonStyle(.bordered)
                }
            }
            if session.linkedNote == nil, session.linkedFiles.isEmpty {
                Text(L10n.flowNoResources).foregroundStyle(.secondary)
            }
            webLinkButton(for: session)
            if let error = resourceError {
                feedback(error)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func openNote(_ note: LinkedNote) {
        if onOpenNote?(note.id) == true {
            resourceError = nil
            isHistoryPresented = false
            isFilesPresented = false
        } else {
            resourceError = L10n.flowNoteUnavailable
        }
    }

    private func openFile(_ file: LinkedFile) {
        resourceError = onOpenFile?(file) == true ? nil : L10n.flowFileUnavailable
    }

    private func feedback(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle")
            .font(.system(size: 12))
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func elapsedString(from start: Date, to now: Date) -> String {
        let total = Int(max(0, now.timeIntervalSince(start)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
