import Foundation
import Observation

/// NookFlow 任务上下文管理器 — 负责会话生命周期与本地持久化
///
/// 职责收敛说明：
/// - 只接收纯值参数（id/title/name/icon 等快照字段），不依赖 NotesManager/TrayManager/CalendarManager
/// - 关联笔记/文件时由调用方（NotchContentView）读取原 Manager 并立即传入快照
/// - end() 只负责状态转换与持久化，不回读任何其他 Manager
@Observable @MainActor
final class FocusSessionManager {
    /// 空白标题统一回退值
    static let defaultTitle = "未命名任务"

    /// 持久化键
    private static let storageKey = "nookflow.sessions"

    /// 当前活跃会话（未结束），无则为 nil
    var activeSession: FocusSession?

    /// 已结束任务记录，按结束时间倒序排列（最新在前）
    private(set) var history: [FocusSession] = []

    /// 存储介质（可注入 UserDefaults suite 用于测试）
    private let userDefaults: UserDefaults

    // MARK: - Init

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        loadFromStorage()
    }

    // MARK: - 会话生命周期

    /// 启动新会话。若已有活跃会话则不重复启动（返回现有会话）。
    /// 空白标题（空字符串或纯空白）统一回退为“未命名任务”。
    @discardableResult
    func start(
        title: String,
        eventIdentifier: String? = nil,
        scheduledEndAt: Date? = nil
    ) -> FocusSession {
        // 已有活跃会话则不重复启动
        if let existing = activeSession {
            return existing
        }

        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = trimmed.isEmpty ? Self.defaultTitle : trimmed

        let session = FocusSession(
            id: UUID(),
            title: resolvedTitle,
            eventIdentifier: eventIdentifier,
            startedAt: Date(),
            scheduledEndAt: scheduledEndAt,
            endedAt: nil,
            state: .active,
            linkedNote: nil,
            linkedFiles: []
        )
        activeSession = session
        persist()
        return session
    }

    /// 结束当前活跃会话，移入历史记录。
    /// 无活跃会话时为 no-op。
    func end() {
        guard var session = activeSession else { return }
        session.endedAt = Date()
        session.state = .ended
        history.insert(session, at: 0)
        activeSession = nil
        persist()
    }

    // MARK: - 关联快照（立即写入并持久化）

    /// 关联笔记快照。无活跃会话时为 no-op。
    func linkNote(id: UUID, title: String) {
        guard activeSession != nil else { return }
        activeSession?.linkedNote = LinkedNote(id: id, title: title)
        persist()
    }

    /// 关联文件快照（按 id 去重）。无活跃会话时为 no-op。
    func linkFile(id: UUID, name: String, icon: String) {
        guard activeSession != nil else { return }
        // 去重：已存在同 id 的快照则跳过
        if activeSession?.linkedFiles.contains(where: { $0.id == id }) == true {
            return
        }
        activeSession?.linkedFiles.append(LinkedFile(id: id, name: name, icon: icon))
        persist()
    }

    /// 移除已关联文件快照。无活跃会话时为 no-op。
    func unlinkFile(id: UUID) {
        guard activeSession != nil else { return }
        activeSession?.linkedFiles.removeAll { $0.id == id }
        persist()
    }

    // MARK: - 持久化

    /// 从存储恢复：未结束会话恢复为 activeSession，已结束记录恢复为 history
    private func loadFromStorage() {
        guard let data = userDefaults.data(forKey: Self.storageKey),
              let store = try? JSONDecoder().decode(FocusSessionStore.self, from: data) else {
            return
        }
        activeSession = store.activeSession
        history = store.history
    }

    /// 立即持久化当前状态（activeSession + history）
    private func persist() {
        let store = FocusSessionStore(
            activeSession: activeSession,
            history: history
        )
        guard let data = try? JSONEncoder().encode(store) else { return }
        userDefaults.set(data, forKey: Self.storageKey)
    }
}
