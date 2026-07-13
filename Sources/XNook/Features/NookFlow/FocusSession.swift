import Foundation

/// NookFlow 任务上下文会话 — 自包含快照模型，历史记录不依赖当前日历/笔记/文件架状态
struct FocusSession: Codable, Identifiable, Equatable {
    /// 会话唯一标识
    let id: UUID
    /// 任务标题（空白标题在 start 时回退为“未命名任务”）
    var title: String
    /// 关联的日历事件标识，可空（手动启动的任务无关联日程）
    var eventIdentifier: String?
    /// 会话开始时间
    var startedAt: Date
    /// 日程计划结束时间（来自 EKEvent.endDate），可空
    var scheduledEndAt: Date?
    /// 实际结束时间，仅在 state == .ended 时非空
    var endedAt: Date?
    /// 会话状态
    var state: State
    /// 关联笔记快照（关联时立即写入）
    var linkedNote: LinkedNote?
    /// 关联文件快照数组（关联时立即写入）
    var linkedFiles: [LinkedFile]

    enum State: String, Codable {
        case active
        case ended
    }

    /// 是否已结束
    var isEnded: Bool { state == .ended }
}

/// 关联笔记快照 — 只保存展示所需字段，避免依赖 NotesManager 当前状态
struct LinkedNote: Codable, Equatable {
    let id: UUID
    let title: String
}

/// 关联文件快照 — 只保存展示所需字段，避免依赖 TrayManager 当前状态
struct LinkedFile: Codable, Equatable {
    let id: UUID
    let name: String
    let icon: String
}

/// 持久化容器 — 同时保存未结束会话与历史记录
struct FocusSessionStore: Codable {
    /// 当前活跃会话（未结束），无则为 nil
    var activeSession: FocusSession?
    /// 已结束任务记录，按结束时间倒序排列（最新在前）
    var history: [FocusSession]
}
