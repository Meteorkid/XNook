import Foundation

/// 媒体来源偏好：自动跟随系统，或锁定到指定应用。
///
/// 系统 MediaRemote 只能读「当前 Now Playing」，不能主动读取任意后台应用。
/// 因此锁定 Apple Music / Spotify 时走 AppleScript 独立取值；锁定其他应用时
/// 只接受来源匹配的系统快照，不匹配则进入等待状态，绝不显示或控制别的播放器。
enum MediaSourcePreference {
    static let modeKey = "mediaSourceMode"
    static let customKey = "mediaSourceCustomBundleID"

    static let autoMode = "auto"
    static let customMode = "custom"

    struct Option: Identifiable, Hashable {
        let id: String
        let title: String
        let bundleID: String?

        init(id: String, title: String, bundleID: String? = nil) {
            self.id = id
            self.title = title
            self.bundleID = bundleID
        }
    }

    static var options: [Option] {
        [
            Option(id: autoMode, title: L10n.mediaSourceAuto),
            Option(id: ScriptingBridgeHelper.SupportedApp.music.bundleIdentifier,
                   title: "Apple Music",
                   bundleID: ScriptingBridgeHelper.SupportedApp.music.bundleIdentifier),
            Option(id: ScriptingBridgeHelper.SupportedApp.spotify.bundleIdentifier,
                   title: "Spotify",
                   bundleID: ScriptingBridgeHelper.SupportedApp.spotify.bundleIdentifier),
            Option(id: "com.tencent.QQMusicMac", title: "QQ音乐", bundleID: "com.tencent.QQMusicMac"),
            Option(id: "com.netease.163music", title: "网易云音乐", bundleID: "com.netease.163music"),
            Option(id: "com.bilibili.bilibiliPC", title: "哔哩哔哩", bundleID: "com.bilibili.bilibiliPC"),
            Option(id: customMode, title: L10n.mediaSourceCustom),
        ]
    }

    /// 解析当前锁定的 bundle identifier；自动模式返回 nil。
    static func resolvedBundleID(defaults: UserDefaults = .standard) -> String? {
        let mode = defaults.string(forKey: modeKey) ?? autoMode
        if mode == autoMode { return nil }
        if mode == customMode {
            let custom = defaults.string(forKey: customKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return custom.isEmpty ? nil : custom
        }
        return mode
    }

    static func displayName(for bundleID: String) -> String {
        options.first { $0.bundleID == bundleID }?.title ?? bundleID
    }
}
