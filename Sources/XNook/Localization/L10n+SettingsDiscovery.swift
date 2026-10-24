import Foundation

extension L10n {
    static var settingsLayoutEditor: String { localized(zh: "打开布局编辑器", en: "Open Layout Editor") }
    static var settingsGlassDepthRequiresGlass: String { localized(zh: "选择玻璃背景后可调整深浅。", en: "Select the glass background to adjust its depth.") }
    static var settingsSearch: String { localized(zh: "搜索设置", en: "Search settings") }
    static var settingsSearchHint: String { localized(zh: "例如：高度、歌词延迟、日历权限", en: "Try height, lyric delay, calendar access") }
    static var settingsSearchEmpty: String { localized(zh: "没有匹配的设置", en: "No matching settings") }
    static var settingsSearchClear: String { localized(zh: "清除搜索", en: "Clear search") }
    static var settingsRefreshPermissions: String { localized(zh: "刷新权限状态", en: "Refresh permission status") }
    static func settingsResults(_ count: Int) -> String { localized(zh: "找到 \(count) 项设置", en: "\(count) settings found") }
    static var settingsCalendarHelp: String { localized(zh: "读取日程和提供提醒需要日历完全访问。仅写入权限不能读取日程；没有日程也可能是未选择日历或当天没有安排。", en: "Reading events and showing reminders need full Calendar access. Write-only access cannot read events. An empty list can also mean no calendars are selected or no events are scheduled.") }
    static var settingsAutomationHelp: String { localized(zh: "Apple Music、Spotify 的部分播放控制需要分别允许自动化。请在使用控制功能时响应系统提示；没有播放信息并不代表权限被拒绝。", en: "Some Apple Music and Spotify controls need Automation permission for each player. Respond to the system prompt when using those controls. Missing playback information does not establish that permission was denied.") }
    static var settingsLoginHelp: String { localized(zh: "开机启动需要登录项已启用；已注册但等待批准时，请在系统设置中允许。此页只读取状态，不会自动注册或申请权限。", en: "Launch at login requires an enabled login item. If approval is pending, allow it in System Settings. This page only reads status; it never registers services or requests permission.") }
    static var settingsNumberInvalid: String { localized(zh: "请输入范围内的有效数值", en: "Enter a valid number within the range") }
}
