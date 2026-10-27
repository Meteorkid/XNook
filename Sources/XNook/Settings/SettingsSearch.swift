import Foundation
import SwiftUI
import Observation

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, display, integration, license, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: L10n.general
        case .display: L10n.display
        case .integration: L10n.integration
        case .license: L10n.license
        case .about: L10n.about
        }
    }
    var icon: String {
        switch self {
        case .general: "gearshape.fill"
        case .display: "paintbrush.fill"
        case .integration: "rectangle.connected.to.line.below"
        case .license: "checkmark.seal.fill"
        case .about: "info.circle.fill"
        }
    }
}

struct SettingsSearchEntry: Identifiable, Equatable {
    let id: String
    let pane: SettingsPane
    let title: String
    let keywords: String

    static var all: [Self] { [
        .init(id: "softwareLicense", pane: .license, title: L10n.license, keywords: "授权 邀请码 激活 购买 试用 续费 设备 license activation trial purchase renew device"),
        .init(id: "globalPanelShortcut", pane: .general, title: L10n.globalPanelShortcut, keywords: "全局快捷唤出 快捷键 键盘 组合 唤出 global shortcut hotkey keyboard summon reveal panel"),
        .init(id: "applicationAppearance", pane: .display, title: L10n.applicationAppearance, keywords: "应用外观 系统 深色 浅色 appearance system dark light theme"),
        .init(id: "islandBackgroundStyle", pane: .display, title: L10n.islandBackgroundStyle, keywords: "岛背景 跟随外观 黑色 浅色 玻璃 island background black light glass preset"),
        .init(id: "islandGlassDepth", pane: .display, title: L10n.islandGlassDepth, keywords: "玻璃深浅 玻璃 深浅 透明度 glass depth tint transparency"),
        .init(id: "panelLayoutEditor", pane: .display, title: L10n.settingsLayoutEditor, keywords: "网格 布局 编辑 组件 组合 grid layout editor widget modules"),
        .init(id: "panelAutoSize", pane: .display, title: L10n.panelAutoSize, keywords: "面板 自动 尺寸 宽度 收窄 panel automatic auto size width narrow"),
        .init(id: "panelHeightMode", pane: .display, title: L10n.panelHeightMode, keywords: "面板 高度 自动 手动 自定义 上限 最大 最大高度 贴合 内容 留白 panel height automatic manual custom limit maximum max fit content blank space"),
        .init(id: "panelBaseHeight", pane: .display, title: L10n.panelBaseHeight, keywords: "面板 最大高度 高度 尺寸 panel max maximum height size"),
        .init(id: "panelWidth", pane: .display, title: L10n.panelWidth, keywords: "面板 宽度 尺寸 panel width size"),
        .init(id: "lyricsOffset", pane: .display, title: L10n.lyricsOffset, keywords: "歌词延迟 歌词偏移 歌词校正 提前 延后 慢半拍 lyrics lyric offset delay timing sync"),
        .init(id: "showLyrics", pane: .display, title: L10n.showLyrics, keywords: "显示歌词 歌词不显示 lyrics lyric show missing enable"),
        .init(id: "expandedInactivity", pane: .general, title: L10n.expandedInactivityHide, keywords: "自动隐藏 自动收起 无操作 超时 auto hide inactivity timeout collapse"),
        .init(id: "hoverExit", pane: .general, title: L10n.hoverExitCollapseDelay, keywords: "自动隐藏 鼠标移出 收起延迟 hover exit delay collapse"),
        .init(id: "hideInFullscreen", pane: .general, title: L10n.hideInFullscreen, keywords: "全屏隐藏 自动隐藏 fullscreen full screen hide"),
        .init(id: "permissionCalendar", pane: .general, title: L10n.openCalendarsButton, keywords: "日历权限 日历不显示 授权 隐私 calendar permission access authorization privacy"),
        .init(id: "permissionAutomation", pane: .general, title: L10n.openAutomationButton, keywords: "自动化权限 音乐控制 Apple Music Spotify automation permission media playback"),
        .init(id: "permissionLoginItems", pane: .general, title: L10n.openLoginItemsButton, keywords: "登录项权限 开机启动批准 login items approval permission startup"),
        .init(id: "launchAtLogin", pane: .general, title: L10n.launchAtLogin, keywords: "开机启动 登录启动 launch login startup"),
        .init(id: "language", pane: .general, title: L10n.language, keywords: "语言 中文 英文 language chinese english"),
        .init(id: "showOnAllSpaces", pane: .general, title: L10n.showOnAllSpaces, keywords: "所有桌面空间 多桌面 all spaces desktops"),
        .init(id: "hoverToExpand", pane: .general, title: L10n.hoverToExpand, keywords: "悬停展开 hover expand"),
        .init(id: "scrollDownToExpand", pane: .general, title: L10n.scrollDownToExpand, keywords: "下滑展开 scroll expand"),
        .init(id: "activityNotificationsEnabled", pane: .general, title: L10n.activityEnabled, keywords: "提示 通知 到时提醒 完成任务 activity notification deadline reminder"),
        .init(id: "quietHoursEnabled", pane: .general, title: L10n.enableQuietHours, keywords: "静默 静音 勿扰 时段 quiet hours silent mute"),
        .init(id: "calendarReminderActivityEnabled", pane: .general, title: L10n.activityCalendarEnabled, keywords: "日历文字 提醒 calendar visual reminder"),
        .init(id: "calendarReminderSoundEnabled", pane: .general, title: L10n.enableCalendarReminderSound, keywords: "日历声音 提醒 calendar sound reminder"),
        .init(id: "islandHeight", pane: .display, title: L10n.islandHeight, keywords: "岛高度 尺寸 island height size"),
        .init(id: "islandWidth", pane: .display, title: L10n.islandWidth, keywords: "岛宽度 尺寸 island width size"),
        .init(id: "islandHeightWithLyrics", pane: .display, title: L10n.islandHeightWithLyrics, keywords: "歌词岛高度 尺寸 island lyrics height size"),
        .init(id: "islandWidthWithLyrics", pane: .display, title: L10n.islandWidthWithLyrics, keywords: "歌词岛宽度 尺寸 island lyrics width size"),
        .init(id: "showTickerLine", pane: .display, title: L10n.showTickerLine, keywords: "曲目信息 滚动 ticker track info"),
        .init(id: "tickerSpeed", pane: .display, title: L10n.tickerSpeed, keywords: "滚动速度 ticker scroll speed"),
        .init(id: "reduceMotion", pane: .display, title: L10n.reduceMotion, keywords: "减少动态 减弱动画 无障碍 reduce motion accessibility animation"),
        .init(id: "showNookFlowHistory", pane: .display, title: L10n.showNookFlowHistory, keywords: "任务历史 最近任务 nookflow recent task history"),
        .init(id: "nookFlowHistoryDisplayLimit", pane: .display, title: L10n.nookFlowHistoryDisplayLimit, keywords: "任务历史 数量 nookflow history limit count"),
        .init(id: "autoCheckForUpdates", pane: .about, title: L10n.autoCheckForUpdates, keywords: "自动检查更新 automatic check update"),
        .init(id: "checkForUpdates", pane: .about, title: L10n.checkForUpdates, keywords: "检查更新 check update"),
        .init(id: "claudeCompletionEnabled", pane: .integration, title: L10n.claudeCompletion, keywords: "Claude Code AI 人工智能 完成提示 stop hook completion notification")
    ] }

    static func matches(_ query: String) -> [Self] {
        let text = normalized(query).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 200 else { return [] }
        let terms = text.split(whereSeparator: \.isWhitespace)
        return all.enumerated().compactMap { index, entry -> (Int, Int, Self)? in
            let title = normalized(entry.title), id = normalized(entry.id)
            let searchable = title + " " + id + " " + normalized(entry.keywords)
            guard terms.allSatisfy({ searchable.contains($0) }) else { return nil }
            let score = (title == text || id == text) ? 0 : (title.contains(text) ? 1 : 2)
            return (score, index, entry)
        }.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map(\.2)
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}

@Observable @MainActor
final class SettingsSearchState {
    var query = "" {
        didSet { if isSearching { targetID = nil } }
    }
    private(set) var pane: SettingsPane = .general
    private(set) var targetID: String?
    var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var results: [SettingsSearchEntry] { SettingsSearchEntry.matches(query) }

    func navigate(to entry: SettingsSearchEntry) {
        guard SettingsSearchEntry.all.contains(where: { $0.id == entry.id && $0.pane == entry.pane }) else { return }
        pane = entry.pane
        query = ""
        targetID = entry.id
    }

    func selectPane(_ selection: SettingsPane) {
        pane = selection
        query = ""
        targetID = nil
    }
}


extension View {
    /// 搜索结果与真实设置行共用同一个稳定锚点；定位不会修改设置值。
    func settingsSearchTarget(id: String, highlightedID: String?) -> some View {
        background {
            if highlightedID == id {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.12))
                    .expandedPanelDebugFrame(id: "setting-highlight-" + id)
            }
        }
        .id(id)
        .accessibilityIdentifier("setting-" + id)
        .expandedPanelDebugFrame(id: "setting-" + id)
    }
}
