import Foundation

extension L10n {
    static var inboxTitle: String { localized(zh: "待办收件箱", en: "Task inbox") }
    static var inboxShortTitle: String { localized(zh: "待办", en: "Inbox") }
    static var showTaskInboxShortcut: String { localized(zh: "在概览显示待办入口", en: "Show inbox shortcut on overview") }
    static var showTaskInboxShortcutDescription: String {
        localized(zh: "隐藏当前任务和最近任务组件时，在概览底部显示待办收件箱入口。",
                  en: "Show an inbox shortcut below the overview when Current Task and Recent Tasks are hidden.")
    }
    static var inboxPlaceholder: String { localized(zh: "记下一件待办事项", en: "Capture a task") }
    static var inboxAdd: String { localized(zh: "添加", en: "Add") }
    static var inboxStart: String { localized(zh: "开始", en: "Start") }
    static var inboxDelete: String { localized(zh: "删除待办", en: "Delete task") }
    static var inboxImport: String { localized(zh: "导入 JSON", en: "Import JSON") }
    static var inboxImportHelp: String { localized(zh: "版本 1 · 每批最多 200 项、1 MiB", en: "Version 1 · Up to 200 items and 1 MiB per import") }
    static var inboxImportResults: String { localized(zh: "本次导入结果", en: "Import results") }
    static var inboxImportEmpty: String { localized(zh: "文件中没有待办事项。", en: "The file contains no tasks.") }
    static var inboxInvalidSource: String { localized(zh: "source 不能为空，最多 64 个字符。", en: "source must contain 1–64 characters.") }
    static var inboxInvalidID: String { localized(zh: "id 不能为空，最多 128 个字符。", en: "id must contain 1–128 characters.") }
    static var inboxEmpty: String { localized(zh: "先记下来，准备好时再开始。", en: "Capture tasks now. Start when you are ready.") }
    static var inboxRecovery: String { localized(zh: "重试读取并恢复状态", en: "Reload and recover") }
    static var inboxHandoff: String { localized(zh: "开始状态待确认", en: "Start needs confirmation") }
    static var inboxStorageUnavailable: String {
        localized(zh: "待办或任务历史暂时不可读取。请重试读取，暂不开始或导入任务。",
                  en: "The inbox or task history could not be read. Reload before starting or importing tasks.")
    }
    static var inboxSaveFailed: String {
        localized(zh: "未确认保存成功，输入与恢复凭据已保留。请重试读取后再操作。",
                  en: "The save was not confirmed. Input and recovery records are preserved. Reload before retrying.")
    }
    static var inboxTitleRule: String { localized(zh: "标题不能为空，最多 500 个字符。", en: "Enter a title of up to 500 characters.") }
    static var inboxTaskMissing: String { localized(zh: "这条待办已不在收件箱中。", en: "This task is no longer in the inbox.") }
    static var inboxActiveTaskConflict: String { localized(zh: "请先结束当前任务，再开始这条待办。", en: "Finish the current task before starting this one.") }
    static var inboxIdentityConflict: String { localized(zh: "任务标识发生冲突，原任务未被替换。", en: "The task identity conflicts with an existing task. Nothing was replaced.") }
    static var inboxStartUnconfirmed: String {
        localized(zh: "开始任务的结果尚未确认。恢复凭据已保留，请重试读取后继续。",
                  en: "Starting the task was not confirmed. Recovery records are preserved; reload to continue.")
    }
    static var inboxImportFailed: String {
        localized(zh: "导入未完成。请检查文件格式、版本和大小；源文件未修改。",
                  en: "Import did not finish. Check the format, version, and size. The source file was not modified.")
    }
    static var inboxImported: String { localized(zh: "已添加", en: "Added") }
    static var inboxDuplicate: String { localized(zh: "已存在，未覆盖", en: "Already exists; unchanged") }
    static var inboxInvalid: String { localized(zh: "字段或长度不符合要求", en: "Invalid fields or length") }
    static func inboxRow(_ number: Int) -> String { localized(zh: "第 \(number) 项", en: "Item \(number)") }
}
