/// 播放信息聚合：系统 MediaRemote 为主，AppleScript 只做 Music / Spotify 增强。
///
/// 旧链路只问 Music 和 Spotify 两个播放器，因此 QQ 音乐、哔哩哔哩等应用即使接入了
/// 系统 Now Playing 也不会被显示。现在先读系统快照：任何发布 Now Playing 的应用都能
/// 直接提供标题、艺人、封面和进度；只有识别到 Music / Spotify 时才额外跑 AppleScript，
/// 用它的精确播放位置覆盖系统估算值。两个来源都空才返回空，让上层清空状态。
///
/// 锁定来源时不会读取或控制其他播放器：
/// - Music / Spotify 有脚本词典，直接独立取值，不依赖谁占据系统 Now Playing；
/// - 其余应用只能读系统快照，来源不匹配时返回等待标记，由上层显示提示。
enum NowPlayingProvider {
    typealias SnapshotProvider = @MainActor () async -> [String: Any]
    typealias DirectProvider = @MainActor () async -> [String: Any]?

    /// 等待标记：来源尚未成为系统 Now Playing，或尚未开始播放。
    static let waitingKey = "waitingForSource"

    static func getNowPlayingInfo(
        preferredBundleID: String? = nil,
        remote: @escaping SnapshotProvider = { await MediaRemoteBridge.snapshot() },
        scripted: @escaping SnapshotProvider = { await ScriptingBridgeHelper.getNowPlayingInfo() },
        scriptedMusic: @escaping DirectProvider = { await ScriptingBridgeHelper.getNowPlayingFromMusic() },
        scriptedSpotify: @escaping DirectProvider = { await ScriptingBridgeHelper.getNowPlayingFromSpotify() }
    ) async -> [String: Any] {
        if let preferredBundleID {
            return await lockedInfo(
                bundleID: preferredBundleID,
                remote: remote,
                scriptedMusic: scriptedMusic,
                scriptedSpotify: scriptedSpotify
            )
        }
        return await automaticInfo(remote: remote, scripted: scripted)
    }

    // MARK: - 自动模式

    private static func automaticInfo(
        remote: @escaping SnapshotProvider,
        scripted: @escaping SnapshotProvider
    ) async -> [String: Any] {
        let remoteInfo = await remote()

        if !remoteInfo.isEmpty,
           let source = MediaSource.from(info: remoteInfo),
           source.scriptingApp != nil {
            let scriptedInfo = await scripted()
            if canUse(scriptedInfo, for: source) {
                return merge(remote: remoteInfo, scripted: scriptedInfo)
            }
            // 脚本读取失败不影响系统上已经有效的播放信息
            return remoteInfo
        }

        if !remoteInfo.isEmpty { return remoteInfo }
        return await scripted()
    }

    // MARK: - 锁定模式

    private static func lockedInfo(
        bundleID: String,
        remote: @escaping SnapshotProvider,
        scriptedMusic: @escaping DirectProvider,
        scriptedSpotify: @escaping DirectProvider
    ) async -> [String: Any] {
        // 脚本可直读的应用：不依赖系统 Now Playing 归属，也不会被别的播放器抢占。
        if let app = scriptingApp(for: bundleID) {
            let info = await (app == .music ? scriptedMusic() : scriptedSpotify())
            guard var info, !info.isEmpty else { return waitingInfo(for: bundleID) }
            info["sourceBundleID"] = bundleID
            info["sourceName"] = MediaSourcePreference.displayName(for: bundleID)
            return info
        }

        // 其余应用只能读系统快照；来源不匹配时宁可等待，也不显示别人的内容。
        let remoteInfo = await remote()
        guard !remoteInfo.isEmpty,
              remoteInfo["sourceBundleID"] as? String == bundleID else {
            return waitingInfo(for: bundleID)
        }
        return remoteInfo
    }

    private static func scriptingApp(for bundleID: String) -> ScriptingBridgeHelper.SupportedApp? {
        switch bundleID {
        case ScriptingBridgeHelper.SupportedApp.music.bundleIdentifier: .music
        case ScriptingBridgeHelper.SupportedApp.spotify.bundleIdentifier: .spotify
        default: nil
        }
    }

    private static func waitingInfo(for bundleID: String) -> [String: Any] {
        [
            waitingKey: true,
            "sourceBundleID": bundleID,
            "sourceName": MediaSourcePreference.displayName(for: bundleID),
        ]
    }

    // MARK: - 合并

    /// 脚本结果必须属于同一个来源，否则两个播放器同时运行时会把标题和位置拼错。
    static func canUse(_ scripted: [String: Any], for source: MediaSource) -> Bool {
        guard !scripted.isEmpty, (scripted["fetchFailed"] as? Bool) != true,
              let scriptedSource = MediaSource.from(info: scripted) else { return false }
        return scriptedSource == source
    }

    /// 以脚本快照为基础（位置更精确），补上 MediaRemote 的来源身份与封面。
    static func merge(remote: [String: Any], scripted: [String: Any]) -> [String: Any] {
        var result = scripted
        if result["artworkData"] == nil, let artwork = remote["artworkData"] {
            result["artworkData"] = artwork
        }
        for key in ["sourceBundleID", "sourceName"] {
            if result[key] == nil, let value = remote[key] { result[key] = value }
        }
        return result
    }
}
