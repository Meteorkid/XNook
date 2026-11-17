import Foundation
import Observation

/// 先保留待办开始意图，再幂等创建会话；跨存储失败时仍有完整恢复凭据。
@Observable @MainActor
final class PendingTaskCoordinator {
    let pending: PendingTaskManager
    let focus: FocusSessionManager
    private(set) var message: String?
    private(set) var importResults: [ImportItemResult] = []
    private(set) var isWorking = false
    private var hasPrepared = false

    init(pending: PendingTaskManager, focus: FocusSessionManager) {
        self.pending = pending
        self.focus = focus
    }

    /// 初始化恢复独占变更入口，避免新操作抢占后让恢复永久跳过。
    var isBusy: Bool { !hasPrepared || isWorking || pending.isLoading || pending.isSaving }
    var hasStorageIssue: Bool { pending.storageError != nil || focus.startedPendingTaskIDs == nil }
    var needsRecovery: Bool { hasStorageIssue || visibleTasks.contains(where: { $0.state == .handoff }) }

    var visibleTasks: [PendingTask] {
        let started = focus.startedPendingTaskIDs
        return pending.items.filter { $0.state == .pending || started?.contains($0.id) != true }
    }

    func prepare() async {
        await pending.waitUntilLoaded()
        guard !hasPrepared, !isWorking else { return }
        hasPrepared = true
        isWorking = true
        defer { isWorking = false }
        await reconcile()
    }

    func retryStorage() async {
        guard !isBusy else { return }
        isWorking = true
        defer { isWorking = false }
        let focusLoaded = focus.retryLoadingStorage()
        let pendingLoaded = await pending.retryLoading()
        guard focusLoaded, pendingLoaded else { message = L10n.inboxStorageUnavailable; return }
        await reconcile()
    }

    @discardableResult
    func add(title: String) async -> Bool {
        guard !isBusy else { return false }
        isWorking = true
        defer { isWorking = false }
        do {
            try await pending.add(title: title)
            message = nil
            return true
        } catch {
            message = (error as? PendingTaskError) == .invalidTitle ? L10n.inboxTitleRule : L10n.inboxSaveFailed
            return false
        }
    }

    @discardableResult
    func start(id: UUID) async -> Bool {
        guard !isBusy else { return false }
        guard !hasStorageIssue, let started = focus.startedPendingTaskIDs else {
            message = L10n.inboxStorageUnavailable
            return false
        }
        guard let task = pending.items.first(where: { $0.id == id }) else {
            if started.contains(id) {
                message = nil
                return true
            }
            message = L10n.inboxTaskMissing
            return false
        }
        if !started.contains(id), focus.activeSession != nil {
            message = L10n.inboxActiveTaskConflict
            return false
        }
        isWorking = true
        defer { isWorking = false }
        do {
            try await pending.markHandoff(id: id)
        } catch {
            message = L10n.inboxSaveFailed
            return false
        }
        switch focus.startPendingTask(id: id, title: task.title) {
        case .started, .alreadyStarted:
            message = nil
            return true
        case .activeTaskConflict:
            message = L10n.inboxActiveTaskConflict
        case .identifierConflict:
            message = L10n.inboxIdentityConflict
        case .storageUnavailable:
            message = L10n.inboxStartUnconfirmed
        case .invalidTask:
            message = L10n.inboxTitleRule
        }
        return false
    }

    func remove(id: UUID) async {
        guard !isBusy else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await pending.remove(id: id)
            message = nil
        } catch {
            message = (error as? PendingTaskError) == .handoffRequiresReconciliation
                ? L10n.inboxStartUnconfirmed : L10n.inboxSaveFailed
        }
    }

    @discardableResult
    func importTasks(data: Data) async -> Bool {
        guard !isBusy else { return false }
        importResults = []
        guard let started = focus.startedPendingTaskIDs else {
            message = L10n.inboxStorageUnavailable
            return false
        }
        isWorking = true
        defer { isWorking = false }
        do {
            importResults = try await pending.importTasks(data: data, knownStartedIDs: started)
            message = nil
            return true
        } catch {
            message = pending.storageError != nil ? L10n.inboxSaveFailed : L10n.inboxImportFailed
            return false
        }
    }

    private func reconcile() async {
        guard pending.storageError == nil, let started = focus.startedPendingTaskIDs else {
            message = L10n.inboxStorageUnavailable
            return
        }
        do {
            try await pending.reconcileHandoffs(knownStartedIDs: started)
            message = nil
        } catch {
            message = L10n.inboxSaveFailed
        }
    }
}
