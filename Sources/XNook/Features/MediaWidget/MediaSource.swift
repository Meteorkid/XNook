import AppKit

/// 当前正在播放的来源应用。
///
/// 与只覆盖 Music / Spotify 的 `SupportedApp` 不同，这里不依赖固定枚举：
/// MediaRemote 会给出播放进程的 PID，运行时用 `NSRunningApplication` 反查真实的
/// bundle identifier 和显示名，因此任何接入系统 Now Playing 的播放器都能被识别。
struct MediaSource: Equatable, Hashable, Sendable {
    let bundleIdentifier: String
    let displayName: String
    let kind: Kind

    enum Kind: String, Sendable {
        case music
        case video
        case browser
        case other
    }

    /// 已知来源的展示信息。只收录已核实的 bundle identifier；
    /// 其余应用一律使用系统返回的显示名，避免猜错 ID 反而显示错误名称。
    private static let catalog: [String: (name: String, kind: Kind)] = [
        "com.apple.Music": ("音乐", .music),
        "com.spotify.client": ("Spotify", .music),
        "com.tencent.QQMusicMac": ("QQ音乐", .music),
        "com.netease.163music": ("网易云音乐", .music),
        "com.bilibili.bilibiliPC": ("哔哩哔哩", .video),
        "com.apple.Safari": ("Safari", .browser),
        "com.google.Chrome": ("Chrome", .browser),
        "com.microsoft.edgemac": ("Edge", .browser),
        "org.mozilla.firefox": ("Firefox", .browser),
    ]

    static let appleMusic = MediaSource(
        bundleIdentifier: ScriptingBridgeHelper.SupportedApp.music.bundleIdentifier,
        displayName: "音乐",
        kind: .music
    )

    static let spotify = MediaSource(
        bundleIdentifier: ScriptingBridgeHelper.SupportedApp.spotify.bundleIdentifier,
        displayName: "Spotify",
        kind: .music
    )

    /// 只有这两个播放器有 AppleScript 词典，其余播放器走 MediaRemote 控制。
    var scriptingApp: ScriptingBridgeHelper.SupportedApp? {
        switch bundleIdentifier {
        case ScriptingBridgeHelper.SupportedApp.music.bundleIdentifier: .music
        case ScriptingBridgeHelper.SupportedApp.spotify.bundleIdentifier: .spotify
        default: nil
        }
    }

    /// 从聚合后的播放信息中解析来源。
    ///
    /// - MediaRemote 链路提供 `sourceBundleID` / `sourceName`，是唯一可靠的身份来源；
    /// - AppleScript 链路只提供 `source`（"Music" / "Spotify"），用于无 MediaRemote 时兜底。
    static func from(info: [String: Any]) -> MediaSource? {
        let bundleID = info["sourceBundleID"] as? String ?? ""
        if !bundleID.isEmpty {
            if let known = catalog[bundleID] {
                return MediaSource(bundleIdentifier: bundleID, displayName: known.name, kind: known.kind)
            }
            let name = info["sourceName"] as? String ?? ""
            return MediaSource(
                bundleIdentifier: bundleID,
                displayName: name.isEmpty ? bundleID : name,
                kind: .other
            )
        }

        guard let rawSource = info["source"] as? String, !rawSource.isEmpty else { return nil }
        switch rawSource {
        case ScriptingBridgeHelper.SupportedApp.music.rawValue:
            return appleMusic
        case ScriptingBridgeHelper.SupportedApp.spotify.rawValue:
            return spotify
        default:
            return MediaSource(bundleIdentifier: "", displayName: rawSource, kind: .other)
        }
    }

    /// 跳转到来源应用。使用 bundle identifier 查应用 URL，未知应用同样适用。
    @MainActor
    func activate() {
        guard !bundleIdentifier.isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
    }
}
