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
    static var settingsAutomationHelp: String { localized(zh: "Apple Music 和 Spotify 分别需要自动化授权。请先运行播放器再刷新状态；此处检查不会启动播放器或弹出授权请求。", en: "Apple Music and Spotify need separate Automation permission. Run a player, then refresh its status. This check does not launch players or request permission.") }
    static var settingsLoginHelp: String { localized(zh: "开关反映系统中的注册状态。等待批准时尚不会开机启动，请在系统设置中允许；刷新状态不会自动注册。", en: "The switch reflects system registration. A login item awaiting approval will not launch at login until allowed in System Settings. Refreshing never registers it automatically.") }
    static var settingsLoginUpdateFailed: String { localized(zh: "无法更改登录项，请在系统设置中检查。", en: "Could not change the login item. Check System Settings.") }
    static var settingsNumberInvalid: String { localized(zh: "请输入范围内的有效数值", en: "Enter a valid number within the range") }
}
