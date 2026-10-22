import Foundation
import Observation

/// NookFlow 会话与关联资料快照；候选状态写入成功后才发布到界面。
@Observable @MainActor
final class FocusSessionManager {
    /// 空白标题统一回退值
    static var defaultTitle: String { L10n.flowUntitledTask }

    /// 持久化键
    private static let storageKey = "nookflow.sessions"

    /// 历史使用的独立 UserDefaults 域。NookFlow 历史数据量大且会写入 bookmark
    /// 二进制，与主偏好共用同一个 plist 会互相牵连：任一侧损坏都会连累另一侧。
    private static let storeSuiteName = "com.meteorkid.xnook.nookflow"

    /// 历史保留上限。每条记录可携带 security-scoped bookmark（数百字节到数 KB），
    /// 且每次写入都是全量编码，无节制增长会让启动解码与每次操作越来越慢。
    static let historyLimit = 200

    /// 单个会话最多保留的文件快照，避免一次性关联整个文件架导致单条记录膨胀。
    static let linkedFileLimit = 50

    /// 当前活跃会话（未结束），无则为 nil
    private(set) var activeSession: FocusSession?

    /// 已结束任务记录，按结束时间倒序排列（最新在前）
    private(set) var history: [FocusSession] = []
    /// 读取或写入失败后禁止继续写回，直到显式重新读取。
    private(set) var storageError: String?
    private(set) var activityMessage: String?

    /// 存储介质（可注入 UserDefaults suite 用于测试）
    private let userDefaults: UserDefaults
    private let writeData: (Data) throws -> Void

    // MARK: - Init

    init(
        userDefaults: UserDefaults? = nil,
        writeData: ((Data) throws -> Void)? = nil
    ) {
        guard let injected = userDefaults else {
            let store = Self.resolvedStore()
            self.userDefaults = store
            self.writeData = writeData ?? { store.set($0, forKey: Self.storageKey) }
            // 迁移只发生在默认存储路径上；注入的 store（如测试）一律不碰主偏好。
            Self.migrateLegacyStore(to: store)
            loadFromStorage()
            return
        }
        self.userDefaults = injected
        self.writeData = writeData ?? { injected.set($0, forKey: Self.storageKey) }
        loadFromStorage()
    }

    private static func resolvedStore() -> UserDefaults {
        UserDefaults(suiteName: storeSuiteName) ?? .standard
    }

    /// 把仍停留在主偏好里的旧历史搬到独立存储域。
    /// 只有写入新位置成功后才清除旧位置，搬运失败时保留原数据不动。
    private static func migrateLegacyStore(to store: UserDefaults) {
        let standard = UserDefaults.standard
        guard store !== standard,
              let payload = standard.object(forKey: storageKey),
              store.object(forKey: storageKey) == nil else { return }
        store.set(payload, forKey: storageKey)
        guard store.object(forKey: storageKey) != nil else { return }
        standard.removeObject(forKey: storageKey)
    }

    // MARK: - 会话生命周期

    @discardableResult
    func start(
        title: String,
        eventIdentifier: String? = nil,
        scheduledEndAt: Date? = nil
    ) -> FocusSession? {
        guard storageError == nil else { return nil }
        // 已有活跃会话则不重复启动
        if let existing = activeSession {
            activityMessage = L10n.flowExistingTask(existing.title)
            return existing
        }

        activityMessage = nil

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
        var candidateHistory = [session] + history
        if candidateHistory.count > Self.historyLimit {
            candidateHistory = Array(candidateHistory.prefix(Self.historyLimit))
        }
        guard persist(activeSession: nil, history: candidateHistory) else { return false }
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

    /// 待关联的文件快照，用于批量写入。
    struct FileSnapshot {
        let id: UUID
        let name: String
        let icon: String
        let bookmarkData: Data?

        init(id: UUID, name: String, icon: String, bookmarkData: Data? = nil) {
            self.id = id
            self.name = name
            self.icon = icon
            self.bookmarkData = bookmarkData
        }
    }

    /// 关联文件快照（按 id 去重）。无活跃会话时为 no-op。
    @discardableResult
    func linkFile(id: UUID, name: String, icon: String, bookmarkData: Data? = nil) -> Bool {
        linkFiles([FileSnapshot(id: id, name: name, icon: icon, bookmarkData: bookmarkData)])
    }

    /// 批量关联文件快照，全部处理完只持久化一次。
    /// 逐个调用会让 n 个文件变成 n 次全量编码写盘。
    @discardableResult
    func linkFiles(_ snapshots: [FileSnapshot]) -> Bool {
        guard let sessionID = activeSession?.id else { return false }
        return updateSession(id: sessionID) { session in
            for snapshot in snapshots {
                guard let index = session.linkedFiles.firstIndex(where: { $0.id == snapshot.id }) else {
                    guard session.linkedFiles.count < Self.linkedFileLimit else { continue }
                    session.linkedFiles.append(
                        LinkedFile(id: snapshot.id, name: snapshot.name, icon: snapshot.icon, bookmarkData: snapshot.bookmarkData)
                    )
                    continue
                }
                // 老版本的关联没有书签，再次关联时只补访问凭据，不改原快照标题。
                let existing = session.linkedFiles[index]
                guard existing.bookmarkData == nil, let bookmarkData = snapshot.bookmarkData else { continue }
                session.linkedFiles[index] = LinkedFile(
                    id: existing.id, name: existing.name, icon: existing.icon, bookmarkData: bookmarkData
                )
            }
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
