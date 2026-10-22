import Foundation

extension L10n {
    // 与 L10n+TaskLinks 重复的通用文案（任务标题回退、存储错误提示等）统一由该文件提供，
    // 同名定义会让 Swift 在 extension 之间产生二义性，这里只保留 NookFlow 独有的条目。
    static var flowStartTask: String { localized(zh: "开始任务", en: "Start task") }
    static var flowTaskPlaceholder: String { localized(zh: "接下来专注什么？", en: "What will you focus on?") }
    static var flowActive: String { localized(zh: "进行中", en: "In progress") }
    static var flowEndTask: String { localized(zh: "结束任务", en: "End task") }
    static var flowAllTasks: String { localized(zh: "全部任务", en: "All tasks") }
    static var flowTaskDetails: String { localized(zh: "任务资料", en: "Task resources") }
    static var flowCreateNote: String { localized(zh: "创建关联笔记", en: "Create linked note") }
    static var flowLinkTray: String { localized(zh: "关联文件架", en: "Link tray files") }
    static var flowEmptyTray: String { localized(zh: "文件架为空", en: "Tray is empty") }
    static var flowLinkedNote: String { localized(zh: "关联笔记", en: "Linked note") }
    static var flowLinkedFiles: String { localized(zh: "关联文件", en: "Linked files") }
    static var flowNoResources: String { localized(zh: "此任务没有关联资料。", en: "No resources were linked to this task.") }
    static var flowNoteUnavailable: String { localized(
        zh: "无法打开关联笔记，它可能已被删除或尚未恢复。",
        en: "The linked note could not be opened. It may have been deleted or not yet restored.") }
    static var flowNoteCreationFailed: String { localized(
        zh: "无法创建关联笔记。请在笔记中检查存储错误并重试，当前任务会继续保留。",
        en: "The linked note could not be created. Check the storage error in Notes and retry. The current task is preserved.") }
    static var flowFileUnavailable: String { localized(
        zh: "无法打开此文件，请检查文件是否存在以及是否有访问权限。任务记录会继续保留。",
        en: "This file could not be opened. Check that it exists and that access is allowed. The task record is preserved.") }
    static func flowFileCount(_ count: Int) -> String { localized(zh: "查看文件（\(count)）", en: "View files (\(count))") }
    static func flowViewAll(_ count: Int) -> String { localized(zh: "查看全部（\(count)）", en: "View all (\(count))") }
    static func flowEnded(_ time: String) -> String { localized(zh: "结束 \(time)", en: "Ended \(time)") }
}
