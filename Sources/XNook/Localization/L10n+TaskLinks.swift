import Foundation

extension L10n {
    static var flowWebLinks: String { localized(zh: "网页链接", en: "Web links") }
    static var flowNoWebLinks: String { localized(zh: "还没有关联网页", en: "No web links yet") }
    static var flowWebAddress: String { localized(zh: "https://…", en: "https://…") }
    static var flowWebAddressLabel: String { localized(zh: "网页地址", en: "Web address") }
    static var flowWebTitle: String { localized(zh: "链接标题（可选）", en: "Link title (optional)") }
    static var flowAddWebLink: String { localized(zh: "添加链接", en: "Add link") }
    static var flowEditWebLink: String { localized(zh: "编辑链接", en: "Edit link") }
    static var flowCancelWebLinkEdit: String { localized(zh: "取消编辑", en: "Cancel editing") }
    static var flowWebLinkChanged: String { localized(zh: "链接已被修改。你的输入仍保留，请取消编辑后重新打开最新内容。", en: "This link has changed. Your input is kept; cancel editing and reopen the latest version.") }
    static var flowWebLinkRemoved: String { localized(zh: "链接已被解除关联，无法保存这次编辑。你的输入仍保留。", en: "This link was removed, so this edit cannot be saved. Your input is kept.") }
    static var flowWebLinkRule: String { localized(zh: "仅支持 HTTP/HTTPS；每个任务最多 20 项，标题最多 120 字符。", en: "HTTP/HTTPS only. Up to 20 links per task and 120 characters per title.") }
    static var flowInvalidWebLink: String { localized(zh: "请输入有效的 HTTP/HTTPS 地址，不含账户密码；标题最多 120 字符。", en: "Enter a valid HTTP/HTTPS address without credentials and a title of up to 120 characters.") }
    static var flowWebLinkExists: String { localized(zh: "链接已存在，原名称已保留。", en: "This link already exists. Its original name is preserved.") }
    static var flowWebLinkLimit: String { localized(zh: "每个任务最多关联 20 个网页。", en: "A task can contain up to 20 web links.") }
    static var flowWebLinkUnavailable: String { localized(zh: "无法打开这个网页链接。", en: "This web link could not be opened.") }
    static var flowUntitledTask: String { localized(zh: "未命名任务", en: "Untitled task") }
    static func flowExistingTask(_ title: String) -> String { localized(
        zh: "“\(title)”仍在进行中。请先结束当前任务，再开始另一项。",
        en: "“\(title)” is still in progress. End the current task before starting another.") }
    static var flowStorageReadError: String { localized(
        zh: "任务记录无法读取，原数据已保留。请恢复存储后重新读取。",
        en: "Task records could not be read. The original data is preserved. Restore the storage, then reload.") }
    static var flowStorageWriteError: String { localized(
        zh: "任务未能保存，原数据未被覆盖。请检查存储后重试。",
        en: "The task could not be saved. Existing data was not overwritten. Check the storage and retry.") }
    static var flowResourceTaskMissing: String { localized(
        zh: "此任务已不可用，请关闭资料后重新打开。",
        en: "This task is no longer available. Close its resources and open it again.") }
    static var flowOpen: String { localized(zh: "打开", en: "Open") }
    static var flowUnlink: String { localized(zh: "解除关联", en: "Unlink") }
    static var flowClose: String { localized(zh: "关闭", en: "Close") }
    static var flowRetry: String { localized(zh: "重新读取", en: "Reload") }
    static var flowRecentTasks: String { localized(zh: "最近任务", en: "Recent tasks") }
    static func flowStarted(_ time: String) -> String { localized(zh: "开始 \(time)", en: "Started \(time)") }
}
