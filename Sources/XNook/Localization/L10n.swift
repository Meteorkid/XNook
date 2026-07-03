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

    // MARK: - 菜单栏

    static var showXNook: String { localized(zh: "显示 X Nook", en: "Show X Nook") }
    static var xnookSettings: String { localized(zh: "X Nook 设置", en: "X Nook Settings") }

    // MARK: - 设置面板标签

    static var general: String { localized(zh: "通用", en: "General") }
    static var display: String { localized(zh: "显示", en: "Display") }
    static var about: String { localized(zh: "关于", en: "About") }

    // MARK: - 设置分组标题

    static var sectionStartup: String { localized(zh: "启动与行为", en: "Startup & Behavior") }
    static var sectionInteraction: String { localized(zh: "交互", en: "Interaction") }
    static var sectionIslandSize: String { localized(zh: "灵动岛尺寸", en: "Island Size") }
    static var sectionPanelSize: String { localized(zh: "面板尺寸", en: "Panel Size") }
    static var sectionWidgets: String { localized(zh: "Widget 选择", en: "Widgets") }
    static var sectionAccessibility: String { localized(zh: "辅助功能", en: "Accessibility") }
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

    static var panelWidth: String { localized(zh: "面板宽度", en: "Panel width") }
    static var panelWidthDesc: String { localized(
        zh: "展开面板的宽度（单位：点）。",
        en: "Width of the expanded panel in points.") }

    static var panelMaxHeight: String { localized(zh: "面板最大高度", en: "Panel max height") }
    static var panelMaxHeightDesc: String { localized(
        zh: "展开面板的最大高度（单位：点）。",
        en: "Maximum height of the expanded panel in points.") }

    static var reduceMotion: String { localized(zh: "减弱动画", en: "Reduce motion") }
    static var reduceMotionDesc: String { localized(
        zh: "禁用展开/收起过渡的弹簧动画。",
        en: "Disable spring animations for the expand/collapse transitions.") }

    static var jellyIntensity: String { localized(zh: "果冻动画强度", en: "Jelly animation intensity") }
    static var jellyIntensityDesc: String { localized(
        zh: "鼠标进入灵动岛时的弹跳动画强度。",
        en: "Intensity of the bounce animation when cursor enters the pill.") }

    static var jellyWeak: String { localized(zh: "弱", en: "Weak") }
    static var jellyMedium: String { localized(zh: "中", en: "Medium") }
    static var jellyStrong: String { localized(zh: "强", en: "Strong") }

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
