import SwiftUI
import UniformTypeIdentifiers

struct TaskInboxView: View {
    var coordinator: PendingTaskCoordinator
    let onClose: () -> Void
    @State private var draft = ""
    @State private var showsImporter = false
    @State private var showsImportResults = false
    @State private var isReadingImport = false
    @State private var importError: String?
    @FocusState private var isInputFocused: Bool

    private var busy: Bool { coordinator.isBusy || isReadingImport }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.inboxTitle).font(.headline)
                Text("\(coordinator.visibleTasks.count)").foregroundStyle(.secondary)
                Spacer()
                Button(L10n.flowClose, action: onClose).controlSize(.small)
            }
            HStack(alignment: .top, spacing: 8) {
                TextField(L10n.inboxPlaceholder, text: $draft, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
                    .focused($isInputFocused)
                    .disabled(busy || coordinator.pending.storageError != nil)
                    .onSubmit { addDraft() }
                Button(L10n.inboxAdd, action: addDraft)
                    .disabled(busy || coordinator.pending.storageError != nil
                        || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.count > 500)
            }
            if draft.count > 500 {
                Text(L10n.inboxTitleRule).font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button(L10n.inboxImport) {
                    importError = nil
                    showsImportResults = false
                    showsImporter = true
                }
                .disabled(busy || coordinator.hasStorageIssue)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                if coordinator.needsRecovery {
                    Button(L10n.inboxRecovery) { Task { await coordinator.retryStorage() } }
                        .disabled(busy)
                }
            }
            .controlSize(.small)
            Text(L10n.inboxImportHelp).font(.caption2).foregroundStyle(.secondary)
            if let message = importError ?? coordinator.message {
                Text(message).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if coordinator.visibleTasks.isEmpty {
                        Text(L10n.inboxEmpty).font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(coordinator.visibleTasks) { task in
                        taskRow(task)
                        Divider()
                    }
                    if showsImportResults { importResults }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .frame(width: 400, height: 420)
        .task {
            await coordinator.prepare()
            isInputFocused = true
        }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                Task { await importFile(url) }
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { importError = L10n.inboxImportFailed }
            }
        }
    }

    private func taskRow(_ task: PendingTask) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(task.title).font(.callout).fixedSize(horizontal: false, vertical: true)
                if task.state == .handoff {
                    Text(L10n.inboxHandoff).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(L10n.inboxStart) {
                Task {
                    if await coordinator.start(id: task.id) { onClose() }
                }
            }
            .disabled(busy || coordinator.hasStorageIssue)
            Button(role: .destructive) {
                Task { await coordinator.remove(id: task.id) }
            } label: {
                Image(systemName: "trash")
            }
            .help(L10n.inboxDelete)
            .accessibilityLabel(L10n.inboxDelete + ": " + task.title)
            .disabled(busy || coordinator.pending.storageError != nil || task.state == .handoff)
        }
        .controlSize(.small)
    }

    private var importResults: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.inboxImportResults).font(.subheadline)
            if coordinator.importResults.isEmpty {
                Text(L10n.inboxImportEmpty).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(coordinator.importResults, id: \.index) { item in
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.inboxRow(item.index + 1) + " · " + (item.title ?? ""))
                        .font(.caption).lineLimit(2)
                    Text(resultDescription(item.outcome)).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func resultDescription(_ outcome: ImportItemResult.Outcome) -> String {
        switch outcome {
        case .added: L10n.inboxImported
        case .duplicate: L10n.inboxDuplicate
        case .invalid(let reason):
            switch reason {
            case .invalidSource: L10n.inboxInvalidSource
            case .invalidExternalID: L10n.inboxInvalidID
            case .invalidTitle: L10n.inboxTitleRule
            case .invalidItem: L10n.inboxInvalid
            }
        }
    }

    private func addDraft() {
        guard !busy else { return }
        let submitted = draft
        Task {
            if await coordinator.add(title: submitted), draft == submitted { draft = "" }
        }
    }

    private func importFile(_ url: URL) async {
        guard !busy else { return }
        isReadingImport = true
        showsImportResults = false
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
            isReadingImport = false
        }
        do {
            let data = try await PendingTaskManager.readImportFile(url)
            showsImportResults = await coordinator.importTasks(data: data)
        } catch {
            importError = L10n.inboxImportFailed
        }
    }
}
