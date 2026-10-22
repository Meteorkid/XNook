import Foundation
import Observation

/// NookFlow 会话与关联资料快照；候选状态写入成功后才发布到界面。
@Observable @MainActor
final class FocusSessionManager {
    static var defaultTitle: String { L10n.flowUntitledTask }
    private static let storageKey = "nookflow.sessions"

    private(set) var activeSession: FocusSession?
    /// 已结束记录按结束时间倒序排列。
    private(set) var history: [FocusSession] = []
    /// 读取或写入失败后禁止继续写回，直到显式重新读取。
    private(set) var storageError: String?
    private(set) var activityMessage: String?

    private let userDefaults: UserDefaults
    private let writeData: (Data) throws -> Void

    init(
        userDefaults: UserDefaults = .standard,
        writeData: ((Data) throws -> Void)? = nil
    ) {
        self.userDefaults = userDefaults
        self.writeData = writeData ?? { userDefaults.set($0, forKey: Self.storageKey) }
        loadFromStorage()
    }

    // MARK: - 会话生命周期

    @discardableResult
    func start(
        title: String,
        eventIdentifier: String? = nil,
        scheduledEndAt: Date? = nil
    ) -> FocusSession? {
        guard storageError == nil else { return nil }
        if let existing = activeSession {
            activityMessage = L10n.flowExistingTask(existing.title)
            return existing
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let session = FocusSession(
            id: UUID(), title: trimmed.isEmpty ? Self.defaultTitle : trimmed,
            eventIdentifier: eventIdentifier, startedAt: Date(), scheduledEndAt: scheduledEndAt,
            endedAt: nil, state: .active, linkedNote: nil, linkedFiles: []
        )
        guard persist(activeSession: session, history: history) else { return nil }
        activityMessage = nil
        return session
    }

    @discardableResult
    func end() -> Bool {
        guard storageError == nil else { return false }
        guard var session = activeSession else { return true }
        session.endedAt = Date()
        session.state = .ended
        guard persist(activeSession: nil, history: [session] + history) else { return false }
        activityMessage = nil
        return true
    }

    // MARK: - 明确定位活跃或历史任务

    func session(id: UUID) -> FocusSession? {
        if activeSession?.id == id { return activeSession }
        return history.first { $0.id == id }
    }

    enum TaskLinkResult: Equatable {
        case added(UUID)
        case existing(UUID)
        case invalidLink
        case limitReached
        case taskUnavailable
        case saveFailed
    }

    @discardableResult
    func addTaskURL(urlString: String, title: String, to sessionID: UUID) -> TaskLinkResult {
        guard storageError == nil else { return .saveFailed }
        guard let session = session(id: sessionID) else { return .taskUnavailable }
        guard let link = LinkedTaskURL.make(urlString: urlString, title: title) else { return .invalidLink }
        if let existing = session.taskURLs.first(where: { $0.validatedURL?.absoluteString == link.urlString }) {
            return .existing(existing.id)
        }
        // 限制只作用于新增；保留旧存储中的完整快照。
        guard session.taskURLs.count < 20 else { return .limitReached }
        guard updateSession(id: sessionID, change: { $0.linkedURLs = $0.taskURLs + [link] }) else {
            return .saveFailed
        }
        return .added(link.id)
    }

    enum TaskLinkEditResult: Equatable {
        case updated
        case unchanged
        case invalidLink
        case existing(UUID)
        case linkUnavailable
        case taskUnavailable
        case conflict
        case saveFailed
    }

    @discardableResult
    func editTaskURL(
        _ original: LinkedTaskURL, urlString: String, title: String, in sessionID: UUID
    ) -> TaskLinkEditResult {
        guard storageError == nil else { return .saveFailed }
        guard let session = session(id: sessionID) else { return .taskUnavailable }
        let indices = session.taskURLs.indices.filter { session.taskURLs[$0].id == original.id }
        guard let index = indices.first else { return .linkUnavailable }
        // 重复 ID 无法确定用户正在编辑哪一项，拒绝覆盖旧数据。
        guard indices.count == 1, session.taskURLs[index] == original else { return .conflict }
        guard let candidate = LinkedTaskURL.make(urlString: urlString, title: title) else { return .invalidLink }
        if original.title == candidate.title, original.validatedURL?.absoluteString == candidate.urlString {
            return .unchanged
        }
        if let existing = session.taskURLs.first(where: {
            $0.id != original.id && $0.validatedURL?.absoluteString == candidate.urlString
        }) {
            return .existing(existing.id)
        }
        let replacement = LinkedTaskURL(
            id: original.id, title: candidate.title, urlString: candidate.urlString, revision: UUID()
        )
        guard updateSession(id: sessionID, change: { $0.linkedURLs?[index] = replacement }) else {
            return .saveFailed
        }
        return .updated
    }

    @discardableResult
    func unlinkTaskURL(id: UUID, from sessionID: UUID) -> Bool {
        updateSession(id: sessionID) { $0.linkedURLs?.removeAll { $0.id == id } }
    }

    // MARK: - 活跃任务兼容入口

    @discardableResult
    func linkNote(id: UUID, title: String) -> Bool {
        guard let sessionID = activeSession?.id else { return false }
        return updateSession(id: sessionID) { $0.linkedNote = LinkedNote(id: id, title: title) }
    }

    @discardableResult
    func linkFile(id: UUID, name: String, icon: String) -> Bool {
        guard let sessionID = activeSession?.id else { return false }
        return updateSession(id: sessionID) { session in
            guard !session.linkedFiles.contains(where: { $0.id == id }) else { return }
            session.linkedFiles.append(LinkedFile(id: id, name: name, icon: icon))
        }
    }

    @discardableResult
    func unlinkFile(id: UUID) -> Bool {
        guard let sessionID = activeSession?.id else { return false }
        return updateSession(id: sessionID) { $0.linkedFiles.removeAll { $0.id == id } }
    }

    private func updateSession(id: UUID, change: (inout FocusSession) -> Void) -> Bool {
        guard storageError == nil, var updated = session(id: id) else { return false }
        let original = updated
        change(&updated)
        guard updated != original else { return true }
        if activeSession?.id == id {
            return persist(activeSession: updated, history: history)
        }
        guard let index = history.firstIndex(where: { $0.id == id }) else { return false }
        var updatedHistory = history
        updatedHistory[index] = updated
        return persist(activeSession: activeSession, history: updatedHistory)
    }

    // MARK: - 持久化

    @discardableResult
    func retryLoadingStorage() -> Bool {
        loadFromStorage()
    }

    @discardableResult
    private func loadFromStorage() -> Bool {
        guard let storedValue = userDefaults.object(forKey: Self.storageKey) else {
            activeSession = nil
            history = []
            storageError = nil
            activityMessage = nil
            return true
        }
        guard let data = storedValue as? Data else {
            storageError = L10n.flowStorageReadError
            return false
        }
        do {
            let store = try JSONDecoder().decode(FocusSessionStore.self, from: data)
            activeSession = store.activeSession
            history = store.history
            storageError = nil
            activityMessage = nil
            return true
        } catch {
            storageError = L10n.flowStorageReadError
            return false
        }
    }

    /// UserDefaults.set 返回表示已接受写入，不承诺同步物理落盘。
    private func persist(activeSession candidate: FocusSession?, history candidateHistory: [FocusSession]) -> Bool {
        guard storageError == nil else { return false }
        do {
            let data = try JSONEncoder().encode(FocusSessionStore(activeSession: candidate, history: candidateHistory))
            try writeData(data)
            activeSession = candidate
            history = candidateHistory
            return true
        } catch {
            storageError = L10n.flowStorageWriteError
            return false
        }
    }
}
