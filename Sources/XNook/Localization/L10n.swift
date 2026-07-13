import Foundation

/// 轻量级纯代码本地化，支持中文/英文。
/// 语言检测：Locale.preferredLanguages + UserDefaults["appLanguage"] 手动覆盖。
enum L10n {
    // MARK: - 可用语言

    static let availableLanguages: [(code: String, name: String)] = [
        ("auto", "Auto"),
        ("zh", "中文"),
        ("en", "English"),
    ]

    static var currentLanguageName: String {
        availableLanguages.first { $0.code == effectiveLanguage }?.name ?? "English"
    }

    // MARK: - 语言检测

    static var effectiveLanguage: String {
        if let manual = UserDefaults.standard.string(forKey: "appLanguage"),
           manual != "auto",
           availableLanguages.contains(where: { $0.code == manual }) {
            return manual
        }
        guard let lang = Locale.preferredLanguages.first else { return "en" }
        return lang.hasPrefix("zh") ? "zh" : "en"
    }

    static var isChinese: Bool { effectiveLanguage == "zh" }

    // MARK: - Helper

    private static func localized(zh: String, en: String) -> String {
        effectiveLanguage == "zh" ? zh : en
    }

    // MARK: - 通用

    static var ready: String { localized(zh: "就绪", en: "Ready") }
    static var quit: String { localized(zh: "退出", en: "Quit") }
    static var preferences: String { localized(zh: "设置…", en: "Preferences…") }
    static var back: String { localized(zh: "返回", en: "Back") }
    static var save: String { localized(zh: "保存", en: "Save") }
    static var open: String { localized(zh: "打开", en: "Open") }
    static var version: String { localized(zh: "版本", en: "Version") }
    static var github: String { localized(zh: "GitHub", en: "GitHub") }
    static var statusLabel: String { localized(zh: "状态", en: "Status") }
    static var disabled: String { localized(zh: "已禁用", en: "Disabled") }

    // MARK: - 菜单栏

    static var showXNook: String { localized(zh: "显示 X Nook", en: "Show X Nook") }
    static var xnookSettings: String { localized(zh: "X Nook 设置", en: "X Nook Settings") }

    // MARK: - 设置面板标签

    static var general: String { localized(zh: "通用", en: "General") }
    static var display: String { localized(zh: "显示", en: "Display") }
    static var integration: String { localized(zh: "联动", en: "Integration") }
    static var about: String { localized(zh: "关于", en: "About") }

    // MARK: - 设置分组标题

    static var sectionStartup: String { localized(zh: "启动与行为", en: "Startup & Behavior") }
    static var sectionInteraction: String { localized(zh: "交互", en: "Interaction") }
    static var sectionIslandSize: String { localized(zh: "灵动岛尺寸", en: "Island Size") }
    static var sectionPanelSize: String { localized(zh: "面板尺寸", en: "Panel Size") }
    static var sectionNookFlow: String { localized(zh: "NookFlow", en: "NookFlow") }
    static var sectionWidgets: String { localized(zh: "Widget 选择", en: "Widgets") }
    static var sectionAppearance: String { localized(zh: "外观", en: "Appearance") }
    static var sectionAccessibility: String { localized(zh: "辅助功能", en: "Accessibility") }
    static var sectionMacPrivacy: String { localized(zh: "权限与系统设置", en: "Permissions & System Settings") }
    static var sectionQuietHours: String { localized(zh: "静音时段", en: "Quiet Hours") }
    static var sectionCalendarReminders: String { localized(zh: "日历提醒音", en: "Calendar Reminder Sound") }
    static var sectionSwitching: String { localized(zh: "灵动岛切换", en: "Island Switching") }
    static var sectionCompanionIsland: String { localized(zh: "对方灵动岛", en: "Companion Island") }
    static var sectionUpdates: String { localized(zh: "更新", en: "Updates") }
    static var sectionCredits: String { localized(zh: "致谢", en: "Credits") }

    // MARK: - 设置项标签

    static var launchAtLogin: String { localized(zh: "开机自启动", en: "Launch at login") }
    static var launchAtLoginDesc: String { localized(
        zh: "登录时自动启动 X Nook。",
        en: "Automatically start X Nook when you log in.") }

    static var showOnAllSpaces: String { localized(zh: "所有桌面空间可见", en: "Show on all Spaces") }
    static var showOnAllSpacesDesc: String { localized(
        zh: "灵动岛在所有桌面空间中保持可见。",
        en: "Keep the island visible across all desktop spaces.") }

    static var hideInFullscreen: String { localized(zh: "全屏时隐藏", en: "Hide in full screen") }
    static var hideInFullscreenDesc: String { localized(
        zh: "应用进入全屏时隐藏灵动岛。",
        en: "Hide the island when an app enters full screen.") }

    static var hoverToExpand: String { localized(zh: "悬停展开", en: "Hover to expand") }
    static var hoverToExpandDesc: String { localized(
        zh: "鼠标悬停在灵动岛上时展开面板。",
        en: "Expand the panel when hovering over the island.") }

    static var scrollDownToExpand: String { localized(zh: "双指下滑展开", en: "Scroll down to expand") }
    static var scrollDownToExpandDesc: String { localized(
        zh: "在药丸上双指下滑展开面板。",
        en: "Two-finger scroll down on the pill to expand the panel.") }

    static var expandedInactivityHide: String { localized(zh: "无操作隐藏", en: "Expanded inactivity hide") }
    static var expandedInactivityHideDesc: String { localized(
        zh: "展开后无操作自动隐藏面板（0 = 禁用）。",
        en: "Hide the expanded panel after inactivity (0 = disabled).") }

    static var hoverExitCollapseDelay: String { localized(zh: "移出收起延迟", en: "Hover exit collapse delay") }
    static var hoverExitCollapseDelayDesc: String { localized(
        zh: "鼠标移出面板后延迟收起的时间。",
        en: "Delay before collapsing when mouse leaves the panel.") }

    static var enableSwipeSwitch: String { localized(zh: "启用双指横滑切换", en: "Enable two-finger swipe switching") }
    static var enableSwipeSwitchDesc: String { localized(
        zh: "仅在灵动岛收起时响应双指左右滑动，切换到另一个灵动岛应用。",
        en: "When the island is collapsed, switch to the other island app with a two-finger horizontal swipe.") }

    static var switchSensitivity: String { localized(zh: "切换灵敏度", en: "Switch sensitivity") }
    static var switchSensitivityDesc: String { localized(
        zh: "调整横滑切换所需的水平位移与方向判定强度。",
        en: "Adjust how much horizontal movement is required before a swipe switch is triggered.") }

    static var startupDisplay: String { localized(zh: "启动时显示", en: "Show on launch") }
    static var startupDisplayDesc: String { localized(
        zh: "控制冷启动后默认显示哪个灵动岛；“上次使用”会记住最近一次显示的应用。",
        en: "Choose which island appears after a cold launch. “Last used” remembers the app that was shown most recently.") }

    static var startupLastUsed: String { localized(zh: "上次使用", en: "Last used") }
    static var sensitivityLow: String { localized(zh: "低", en: "Low") }
    static var sensitivityMedium: String { localized(zh: "中", en: "Medium") }
    static var sensitivityHigh: String { localized(zh: "高", en: "High") }

    static var counterpartInstalled: String { localized(zh: "应用安装状态", en: "App installation") }
    static var counterpartInstalledDesc: String { localized(
        zh: "检查对方灵动岛应用是否已安装在当前 Mac 上。",
        en: "Check whether the other island app is installed on this Mac.") }

    static var counterpartProtocol: String { localized(zh: "协议状态", en: "Protocol status") }
    static var counterpartProtocolDesc: String { localized(
        zh: "检查切换使用的 URL Scheme 是否仍由对方灵动岛正确处理。",
        en: "Check whether the URL scheme used for switching is still handled by the other island app.") }

    static var testSwitch: String { localized(zh: "立即切换测试", en: "Switch test") }
    static var testSwitchDesc: String { localized(
        zh: "立即请求切换到对方灵动岛，用来验证联动配置与显示接管是否正常。",
        en: "Immediately switch to the other island app to verify the integration settings and takeover flow.") }
    static var testSwitchButton: String { localized(zh: "切换到对方", en: "Switch now") }

    static var statusInstalled: String { localized(zh: "已安装", en: "Installed") }
    static var statusMissing: String { localized(zh: "未安装", en: "Missing") }
    static var statusRunning: String { localized(zh: "运行中", en: "Running") }
    static var statusStopped: String { localized(zh: "未运行", en: "Stopped") }
    static var statusReady: String { localized(zh: "协议正常", en: "Ready") }
    static var statusMisconfigured: String { localized(zh: "协议异常", en: "Misconfigured") }

    static var panelWidth: String { localized(zh: "面板宽度", en: "Panel width") }
    static var panelWidthDesc: String { localized(
        zh: "展开面板的宽度（单位：点）。",
        en: "Width of the expanded panel in points.") }

    static var nookFlowHistoryDisplayLimit: String { localized(zh: "最近任务显示条数", en: "Recent tasks shown") }
    static var nookFlowHistoryDisplayLimitDesc: String { localized(
        zh: "控制展开面板中最近任务的显示数量（1–5 条）。",
        en: "Choose how many recent tasks appear in the expanded panel (1–5).") }
    static func nookFlowHistoryDisplayCount(_ count: Int) -> String {
        localized(zh: "\(count) 条", en: "\(count) items")
    }

    static var reduceMotion: String { localized(zh: "减弱动画", en: "Reduce motion") }
    static var reduceMotionDesc: String { localized(
        zh: "禁用展开/收起过渡的弹簧动画。",
        en: "Disable spring animations for the expand/collapse transitions.") }

    static var appearanceDark: String { localized(zh: "深色", en: "Dark") }
    static var appearanceLight: String { localized(zh: "浅色", en: "Light") }
    static var appearanceSystem: String { localized(zh: "系统", en: "System") }

    static var jellyIntensity: String { localized(zh: "果冻动画强度", en: "Jelly animation intensity") }
    static var jellyIntensityDesc: String { localized(
        zh: "鼠标进入灵动岛时的弹跳动画强度。",
        en: "Intensity of the bounce animation when cursor enters the pill.") }

    static var jellyWeak: String { localized(zh: "弱", en: "Weak") }
    static var jellyMedium: String { localized(zh: "中", en: "Medium") }
    static var jellyStrong: String { localized(zh: "强", en: "Strong") }

    static var macPrivacyIntro: String { localized(
        zh: "如果媒体控制、日历显示或开机启动没有按预期工作，可以直接打开对应的系统设置页。",
        en: "If media control, calendar access, or launch at login is not behaving as expected, jump straight to the matching System Settings page.") }
    static var openPrivacySecurityButton: String { localized(zh: "隐私与安全性", en: "Privacy & Security") }
    static var openCalendarsButton: String { localized(zh: "日历权限", en: "Calendars") }
    static var openAutomationButton: String { localized(zh: "自动化权限", en: "Automation") }
    static var openAccessibilityButton: String { localized(zh: "辅助功能权限", en: "Accessibility") }
    static var openLoginItemsButton: String { localized(zh: "登录项", en: "Login Items") }

    static var enableQuietHours: String { localized(zh: "启用静音时段", en: "Enable quiet hours") }
    static var enableQuietHoursDesc: String { localized(
        zh: "在指定时间段内静音日历提醒音；不会影响媒体播放。",
        en: "Mute calendar reminder sounds during the selected time range. Media playback is unaffected.") }
    static var fromTime: String { localized(zh: "开始时间", en: "From") }
    static var fromTimeDesc: String { localized(
        zh: "静音时段的起始时间。",
        en: "Start time for quiet hours.") }
    static var toTime: String { localized(zh: "结束时间", en: "To") }
    static var toTimeDesc: String { localized(
        zh: "静音时段的结束时间；支持跨午夜。",
        en: "End time for quiet hours. Overnight ranges are supported.") }
    static var quietHoursActive: String { localized(zh: "当前处于静音时段", en: "Quiet hours are active right now") }
    static var quietHoursInactive: String { localized(zh: "当前不在静音时段", en: "Outside quiet hours") }

    static var enableCalendarReminderSound: String { localized(zh: "启用日历提醒音", en: "Enable calendar reminder sound") }
    static var enableCalendarReminderSoundDesc: String { localized(
        zh: "在即将开始的日历事件进入提醒窗口时播放系统提示音。",
        en: "Play a system sound when an upcoming calendar event enters the reminder window.") }
    static var calendarReminderLeadTime: String { localized(zh: "提前提醒时间", en: "Reminder lead time") }
    static var calendarReminderLeadTimeDesc: String { localized(
        zh: "事件开始前多久播放提醒音。",
        en: "How long before an event starts the reminder sound should play.") }
    static var calendarReminderSoundName: String { localized(zh: "提醒音", en: "Reminder sound") }
    static var calendarReminderSoundNameDesc: String { localized(
        zh: "选择提醒日历事件时使用的系统提示音。",
        en: "Choose the system sound used for calendar reminders.") }
    static var testReminderSound: String { localized(zh: "测试提醒音", en: "Test reminder sound") }
    static var testReminderSoundDesc: String { localized(
        zh: "立即播放一次当前选中的提醒音，便于确认效果。",
        en: "Play the currently selected reminder sound right away so you can confirm how it feels.") }
    static var playTestSound: String { localized(zh: "播放测试音", en: "Play Test Sound") }

    static var latestRelease: String { localized(zh: "最新版本", en: "Latest release") }
    static var lastChecked: String { localized(zh: "上次检查", en: "Last checked") }
    static var checkForUpdates: String { localized(zh: "检查更新", en: "Check for updates") }
    static var checkForUpdatesDesc: String { localized(
        zh: "从 GitHub 查询 X Nook 的最新发布版本。",
        en: "Query GitHub for the latest X Nook release.") }
    static var autoCheckForUpdates: String { localized(zh: "自动检查更新", en: "Auto check for updates") }
    static var autoCheckForUpdatesDesc: String { localized(
        zh: "启动应用时自动检查是否有新版本。",
        en: automaticallyCheckForUpdatesDescription) }
    private static var automaticallyCheckForUpdatesDescription: String {
        localized(zh: "启动应用时自动检查是否有新版本。", en: "Automatically check for new versions when the app starts.")
    }
    static var openLatestRelease: String { localized(zh: "打开发布页", en: "Open release page") }
    static var openLatestReleaseDesc: String { localized(
        zh: "在浏览器中打开最新发布页，下载或查看更新说明。",
        en: "Open the latest release page in your browser to download the update or read the notes.") }
    static var notCheckedYet: String { localized(zh: "尚未检查", en: "Not checked yet") }
    static var updateStatusIdle: String { localized(zh: "尚未开始", en: "Idle") }
    static var updateStatusChecking: String { localized(zh: "检查中", en: "Checking") }
    static var updateStatusUpToDate: String { localized(zh: "已是最新", en: "Up to date") }
    static var updateStatusFailed: String { localized(zh: "检查失败", en: "Failed") }
    static var updateCheckFailed: String { localized(zh: "无法检查更新。", en: "Unable to check for updates.") }
    static var checkForUpdatesButtonChecking: String { localized(zh: "检查中…", en: "Checking...") }
    static func updateStatusAvailable(_ version: String) -> String {
        localized(zh: "发现新版本 \(version)", en: "Version \(version) available")
    }
    static func malformedReleaseVersion(_ version: String) -> String {
        localized(zh: "发布版本号格式无效：\(version)", en: "Malformed release version: \(version)")
    }
    static var installUpdate: String { localized(zh: "安装更新", en: "Install Update") }
    static var installUpdateDesc: String { localized(
        zh: "下载并安装最新版本，安装完成后应用将自动重启。",
        en: "Download and install the latest version. The app will restart after installation.") }
    static var install: String { localized(zh: "安装", en: "Install") }
    static func updateInstalling(_ stage: String) -> String {
        localized(zh: "安装中（\(stage)）", en: "Installing (\(stage))")
    }
    static var updateInstallingDetail: String {
        localized(zh: "正在下载并安装更新，请勿关闭应用。", en: "Downloading and installing update. Please do not close the app.")
    }
    static func minutesBefore(_ minutes: Int) -> String {
        localized(zh: "提前 \(minutes) 分钟", en: "\(minutes) min before")
    }

    // MARK: - 灵动岛尺寸

    static var sectionIslandSizeWithLyrics: String { localized(zh: "歌词灵动岛尺寸", en: "Island Size (Lyrics)") }

    static var islandWidth: String { localized(zh: "岛宽度", en: "Island width") }
    static var islandWidthDesc: String { localized(
        zh: "收起状态下灵动岛的宽度（单位：点）。",
        en: "Width of the collapsed island in points.") }

    static var islandHeight: String { localized(zh: "岛高度", en: "Island height") }
    static var islandHeightDesc: String { localized(
        zh: "收起状态下灵动岛的高度（单位：点）。",
        en: "Height of the collapsed island in points.") }

    static var islandWidthWithLyrics: String { localized(zh: "歌词岛宽度", en: "Island width (lyrics)") }
    static var islandWidthWithLyricsDesc: String { localized(
        zh: "开启歌词时灵动岛的宽度（单位：点）。",
        en: "Width of the collapsed island when lyrics are enabled (in points).") }

    static var islandHeightWithLyrics: String { localized(zh: "歌词岛高度", en: "Island height (lyrics)") }
    static var islandHeightWithLyricsDesc: String { localized(
        zh: "开启歌词时灵动岛的高度（单位：点）。",
        en: "Height of the collapsed island when lyrics are enabled (in points).") }

    // MARK: - 设置界面

    static var language: String { localized(zh: "语言", en: "Language") }
    static var languageDesc: String { localized(
        zh: "切换界面显示语言，修改后需重启应用。",
        en: "Switch the display language. Restart required after change.") }
    static var inspiredBy: String { localized(zh: "灵感来源", en: "Inspired by") }

    // MARK: - Widget 标签

    static var widgetMedia: String { localized(zh: "媒体", en: "Media") }
    static var widgetCalendar: String { localized(zh: "日历", en: "Calendar") }
    static var widgetNotes: String { localized(zh: "笔记", en: "Notes") }
    static var widgetTray: String { localized(zh: "文件托盘", en: "Tray") }

    // MARK: - Media Widget

    static var noTrack: String { localized(zh: "无曲目", en: "No Track") }
    static var unknownArtist: String { localized(zh: "未知艺术家", en: "Unknown Artist") }

    // MARK: - Ticker Line

    static var showTickerLine: String { localized(zh: "显示曲目信息", en: "Show track info") }
    static var showTickerLineDesc: String { localized(
        zh: "在收起状态的灵动岛下方显示当前播放的曲目信息。",
        en: "Show current track info below the collapsed island pill.") }

    static var showLyrics: String { localized(zh: "显示歌词", en: "Show lyrics") }
    static var showLyricsDesc: String { localized(
        zh: "在曲目信息中显示实时歌词（需歌曲支持）。",
        en: "Show real-time lyrics in the track info line (requires song support).") }

    static var tickerSpeed: String { localized(zh: "滚动速度", en: "Scroll speed") }
    static var tickerSpeedDesc: String { localized(
        zh: "曲目信息文字的滚动速度（单位：点/秒）。",
        en: "Scrolling speed of the track info text in points per second.") }

    static var nowPlaying: String { localized(zh: "正在播放", en: "Now Playing") }

    static var sectionTicker: String { localized(zh: "曲目信息", en: "Track Info") }

    // MARK: - Custom GIF

    static var customGif: String { localized(zh: "自定义 GIF", en: "Custom GIF") }
    static var customGifDesc: String { localized(
        zh: "选择一个 GIF 文件作为药丸右侧的动画。未选择时使用默认音频波形。",
        en: "Choose a GIF file for the pill animation. Uses default audio visualizer when none selected.") }
    static var chooseGif: String { localized(zh: "选择 GIF", en: "Choose GIF") }
    static var clearGif: String { localized(zh: "清除", en: "Clear") }

    // MARK: - Calendar Widget

    static var monthSuffix: String { localized(zh: "月", en: "") }
    static var upcomingEvents: String { localized(zh: "即将到来的日程", en: "Upcoming Events") }
    static var calendarAccessRequired: String { localized(zh: "需要日历访问权限", en: "Calendar access required") }
    static var noUpcomingEvents: String { localized(zh: "无即将到来的日程", en: "No upcoming events") }
    static var untitled: String { localized(zh: "无标题", en: "Untitled") }

    // MARK: - Notes Widget

    static var noNotes: String { localized(zh: "无笔记", en: "No notes") }
    static var markdown: String { localized(zh: "Markdown", en: "Markdown") }
    static var plainText: String { localized(zh: "纯文本", en: "Plain Text") }

    // MARK: - Tray Widget

    static var dropFilesHere: String { localized(zh: "将文件拖放到此处", en: "Drop files here") }

    static func fileCount(_ count: Int) -> String {
        localized(zh: "\(count) 个文件", en: "\(count) files")
    }

    static func showAllFiles(_ remaining: Int) -> String {
        localized(zh: "显示剩余 \(remaining) 个文件…", en: "Show \(remaining) more…")
    }

    static var collapseFiles: String { localized(zh: "收起", en: "Collapse") }

    static var openFile: String { localized(zh: "打开", en: "Open") }

    static var revealInFinder: String { localized(zh: "在 Finder 中显示", en: "Reveal in Finder") }

    static var copyToClipboard: String { localized(zh: "复制到剪贴板", en: "Copy to Clipboard") }

    static var removeFile: String { localized(zh: "移除", en: "Remove") }
}
