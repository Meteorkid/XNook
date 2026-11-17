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
    private let legacyUserDefaults: UserDefaults?
    private let writeData: (Data) throws -> Void
    private let onSessionEnded: (FocusSession) -> Void

    // MARK: - Init

    init(
        userDefaults: UserDefaults? = nil,
        legacyUserDefaults: UserDefaults? = nil,
        writeData: ((Data) throws -> Void)? = nil,
        onSessionEnded: @escaping (FocusSession) -> Void = { _ in }
    ) {
        let store = userDefaults ?? Self.resolvedStore()
        self.userDefaults = store
        // 注入目标时只使用显式注入的迁移来源，测试不会接触主偏好。
        self.legacyUserDefaults = legacyUserDefaults ?? (userDefaults == nil ? .standard : nil)
        self.writeData = writeData ?? { store.set($0, forKey: Self.storageKey) }
        self.onSessionEnded = onSessionEnded
        loadFromStorage()
    }

    private static func resolvedStore() -> UserDefaults {
        UserDefaults(suiteName: storeSuiteName) ?? .standard
    }

    // MARK: - 会话生命周期

    enum PendingStartResult: Equatable {
        case started(UUID)
        case alreadyStarted(UUID)
        case activeTaskConflict
        case identifierConflict
        case storageUnavailable
        case invalidTask
    }

    /// nil 表示来源集合未知，调用者不能按空历史进行导入去重或恢复清理。
    var startedPendingTaskIDs: Set<UUID>? {
        guard storageError == nil else { return nil }
        let sessions = [activeSession].compactMap { $0 } + history
        var sessionsByOrigin: [UUID: UUID] = [:]
        for session in sessions {
            guard let origin = session.originPendingTaskID else { continue }
            // 旧版本的来源与会话 ID 可以不同；仅一来源指向不同会话时无法安全确认移交。
            if let existing = sessionsByOrigin[origin], existing != session.id { return nil }
            sessionsByOrigin[origin] = session.id
        }
        return Set(sessionsByOrigin.keys)
    }

    @discardableResult
    func startPendingTask(id: UUID, title: String) -> PendingStartResult {
        guard storageError == nil else { return .storageUnavailable }
        guard startedPendingTaskIDs != nil else { return .identifierConflict }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 500 else { return .invalidTask }
        if let existing = ([activeSession].compactMap { $0 } + history).first(where: { $0.originPendingTaskID == id }) {
            return .alreadyStarted(existing.id)
        }
        if session(id: id) != nil { return .identifierConflict }
        if let activeSession {
            activityMessage = L10n.flowExistingTask(activeSession.title)
            return .activeTaskConflict
        }
        let session = FocusSession(id: id, title: trimmed, eventIdentifier: nil,
            startedAt: Date(), scheduledEndAt: nil, endedAt: nil, state: .active,
            linkedNote: nil, linkedFiles: [], originPendingTaskID: id)
        guard persist(activeSession: session, history: history) else { return .storageUnavailable }
        activityMessage = nil
        return .started(id)
    }

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
        // 界面限制首批展示数量，持久化保留全部历史及可编辑的关联资料。
        let candidateHistory = [session] + history
        guard persist(activeSession: nil, history: candidateHistory) else { return false }
        activityMessage = nil
        onSessionEnded(session)
        return true
    }

    // MARK: - 明确定位活跃或历史任务

    func session(id: UUID) -> FocusSession? {
        if activeSession?.id == id { return activeSession }
        return history.first { $0.id == id }
    }

    @discardableResult
    func setLinkedNote(_ note: LinkedNote?, for sessionID: UUID) -> Bool {
        updateSession(id: sessionID) { $0.linkedNote = note }
    }

    /// 一次批量写入；重复 ID 保留原快照，只给缺少书签的记录补凭据。
    @discardableResult
    func linkFiles(_ files: [LinkedFile], to sessionID: UUID) -> Bool {
        updateSession(id: sessionID) { session in
            // 旧存储可能含重复ID，保留firstIndex的首项语义而不假定唯一。
            var indices: [UUID: Int] = [:]
            indices.reserveCapacity(session.linkedFiles.count + files.count)
            for (index, existing) in session.linkedFiles.enumerated() where indices[existing.id] == nil {
                indices[existing.id] = index
            }
            for file in files {
                if let index = indices[file.id] {
                    let existing = session.linkedFiles[index]
                    if existing.bookmarkData == nil, let bookmark = file.bookmarkData {
                        session.linkedFiles[index] = LinkedFile(
                            id: existing.id, name: existing.name, icon: existing.icon, bookmarkData: bookmark
                        )
                    }
                } else {
                    guard session.linkedFiles.count < Self.linkedFileLimit else { continue }
                    indices[file.id] = session.linkedFiles.count
                    session.linkedFiles.append(file)
                }
            }
        }
    }

    /// 用户重选文件时替换整个快照，允许修复已有但失效的书签。
    @discardableResult
    func replaceLinkedFile(_ replacement: LinkedFile, in sessionID: UUID) -> Bool {
        guard session(id: sessionID)?.linkedFiles.contains(where: { $0.id == replacement.id }) == true else {
            return false
        }
        return updateSession(id: sessionID) { session in
            guard let index = session.linkedFiles.firstIndex(where: { $0.id == replacement.id }) else { return }
            session.linkedFiles[index] = replacement
        }
    }

    @discardableResult
    func unlinkFile(id: UUID, from sessionID: UUID) -> Bool {
        updateSession(id: sessionID) { $0.linkedFiles.removeAll { $0.id == id } }
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

    /// 预算从本次操作时刻开始计算；历史记录仅保留原计划时间。
    @discardableResult
    func setTimeBudget(minutes: Int?, for sessionID: UUID, now: Date = Date()) -> Bool {
        guard let active = activeSession, active.id == sessionID, active.state == .active else { return false }
        let scheduledEndAt: Date?
        if let minutes {
            guard (1...1440).contains(minutes), now.timeIntervalSinceReferenceDate.isFinite else { return false }
            let end = now.addingTimeInterval(Double(minutes) * 60)
            guard end.timeIntervalSinceReferenceDate.isFinite, end > now else { return false }
            scheduledEndAt = end
        } else {
            scheduledEndAt = nil
        }
        return updateSession(id: sessionID) { $0.scheduledEndAt = scheduledEndAt }
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
        return linkFiles(snapshots.map {
            LinkedFile(id: $0.id, name: $0.name, icon: $0.icon, bookmarkData: $0.bookmarkData)
        }, to: sessionID)
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

    /// 只复制可解码的旧数据；保留旧域作为迁移时的回退快照，不覆盖已有目标。
    private func migrateLegacyStoreIfNeeded() -> Bool {
        guard userDefaults.object(forKey: Self.storageKey) == nil,
              let payload = legacyUserDefaults?.object(forKey: Self.storageKey) else { return true }
        guard let data = payload as? Data,
              (try? JSONDecoder().decode(FocusSessionStore.self, from: data)) != nil else {
            storageError = L10n.flowStorageReadError
            return false
        }
        do {
            try writeData(data)
        } catch {
            storageError = L10n.flowStorageWriteError
            return false
        }
        // 读回仅校验存储接受了完整副本，不把同进程读取视为物理落盘保证。
        guard userDefaults.data(forKey: Self.storageKey) == data else {
            storageError = L10n.flowStorageWriteError
            return false
        }
        return true
    }

    @discardableResult
    private func loadFromStorage() -> Bool {
        guard migrateLegacyStoreIfNeeded() else { return false }
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
