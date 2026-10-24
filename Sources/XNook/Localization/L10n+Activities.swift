import Foundation

extension L10n {
    static var activitySection: String { localized(zh: "短提示", en: "Brief notices") }
    static var activityEnabled: String { localized(zh: "显示短提示", en: "Show brief notices") }
    static var activityEnabledHelp: String {
        localized(zh: "显示任务完成等提示；编辑、弹窗和静默时段暂缓，不自动展开面板。",
                  en: "Show task completion notices. Defer during editing, dialogs, and quiet hours without opening the panel.")
    }
    static var activityCalendarEnabled: String { localized(zh: "显示日历文字提醒", en: "Show calendar notices") }
    static var activityCalendarHelp: String {
        localized(zh: "需开启短提示。开启后，提醒音随文字展示；关闭时保留原声音提醒。",
                  en: "Requires brief notices. When enabled, reminder sounds follow the notice; otherwise sound reminders keep their usual behavior.")
    }
    static var activityDismiss: String { localized(zh: "关闭这条提示", en: "Dismiss this notice") }
    static var activityDismissShort: String { localized(zh: "知道了", en: "Dismiss") }
    static var activityOpenCalendar: String { localized(zh: "查看日历", en: "Open Calendar") }
    static func activityTaskCompleted(_ title: String) -> String { localized(zh: "已完成：\(title)", en: "Completed: \(title)") }
    static func activityCalendarDue(_ title: String) -> String { localized(zh: "日程即将开始：\(title)", en: "Upcoming: \(title)") }
    static func activityExpandHint(_ title: String) -> String { localized(zh: "展开查看提示：\(title)", en: "Expand to view notice: \(title)") }
}
