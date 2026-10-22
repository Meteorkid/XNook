import Foundation

extension L10n {
    static var calendarEnableAccess: String { localized(zh: "允许读取日历", en: "Allow calendar access") }
    static var calendarOpenSettings: String { localized(zh: "打开权限设置", en: "Open privacy settings") }
    static var calendarAccessFailed: String { localized(zh: "未能获取日历权限，请重试。", en: "Calendar access failed. Please try again.") }
    static var calendarAccessRestricted: String { localized(zh: "日历访问受到系统限制", en: "Calendar access is restricted") }
    static var calendarAllDone: String { localized(zh: "今天的日程已全部结束", en: "All events for today have ended") }
    static var calendarNoEventsForDay: String { localized(zh: "这一天没有日程", en: "No events on this day") }
    static var calendarNoCalendarsSelected: String { localized(zh: "尚未选择日历，可在设置中启用", en: "No calendars selected. Enable one in settings.") }
    static var calendarAllEvents: String { localized(zh: "查看全部日程", en: "View all events") }
    static func calendarMoreEvents(_ count: Int) -> String { localized(zh: "还有 \(count) 条 · 查看全部", en: "\(count) more · View all") }
    static var calendarOpenApp: String { localized(zh: "打开系统日历", en: "Open Calendar") }
    static var calendarOpenFailed: String { localized(zh: "无法打开系统日历", en: "Could not open Calendar") }
    static var calendarAllDay: String { localized(zh: "全天", en: "All day") }
    static var calendarInProgress: String { localized(zh: "进行中", en: "In progress") }
    static var calendarEnded: String { localized(zh: "已结束", en: "Ended") }
    static var calendarStartTask: String { localized(zh: "开始此日程任务", en: "Start task for this event") }
}
