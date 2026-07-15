import AppKit
import ScriptingBridge

// MARK: - 脚本桥接获取播放信息

enum ScriptingBridgeHelper {

    /// 支持的媒体应用枚举，从类型系统层面防止 AppleScript 注入
    enum SupportedApp: String {
        case music = "Music"
        case spotify = "Spotify"

        var bundleIdentifier: String {
            switch self {
            case .music: "com.apple.Music"
            case .spotify: "com.spotify.client"
            }
        }
    }

    enum PlaybackCommand {
        case play
        case pause
        case nextTrack
        case previousTrack

        var appleScriptStatement: String {
            switch self {
            case .play: "play"
            case .pause: "pause"
            case .nextTrack: "next track"
            case .previousTrack: "previous track"
            }
        }
    }

    /// 安全获取 NSObject 的值
    private static func safeValue(_ object: NSObject?, key: String) -> Any? {
        guard let obj = object, obj.responds(to: NSSelectorFromString(key)) else { return nil }
        return obj.value(forKey: key)
    }

    /// 从 Music.app 获取当前播放信息
    static func getNowPlayingFromMusic() async -> [String: Any]? {
        guard let app = SBApplication(bundleIdentifier: "com.apple.Music") else { return nil }

        var result: [String: Any] = ["source": SupportedApp.music.rawValue]

        guard app.responds(to: NSSelectorFromString("currentTrack")),
              let track = app.value(forKey: "currentTrack") as? NSObject else { return nil }

        if let name = safeValue(track, key: "name") as? String {
            result["title"] = name
        }
        if let artist = safeValue(track, key: "artist") as? String {
            result["artist"] = artist
        }
        if let album = safeValue(track, key: "album") as? String {
            result["album"] = album
        }
        if let duration = safeValue(track, key: "duration") as? Double {
            result["duration"] = duration
        }

        // playerPosition 是真实的播放位置（秒），用于同步歌词时间轴。
        // Music 的 ScriptingBridge 可能持续返回 0，优先用 AppleScript 的真实位置。
        let scriptingBridgePosition = app.value(forKey: "playerPosition") as? Double
        let appleScriptPosition = await fetchPlaybackPositionViaAppleScript(app: .music)
        if let position = resolvedPlaybackPosition(
            scriptingBridgePosition: scriptingBridgePosition,
            appleScriptPosition: appleScriptPosition
        ) {
            result["playerPosition"] = position
            // 采样时间戳：后续封面/播放状态的 AppleScript 调用耗时数百毫秒，
            // 消费方须以采样时刻（而非收到时刻）为基准补偿，否则歌词时间轴滞后
            result["positionTimestamp"] = Date()
        }

        // 用 AppleScript 获取封面（ScriptingBridge 的 artwork 属性不可用）
        // 封面 payload 大、传输慢，按曲目缓存，仅切歌时重新拉取
        let trackKey = artworkCacheKey(
            title: result["title"] as? String ?? "",
            artist: result["artist"] as? String ?? "",
            album: result["album"] as? String ?? ""
        )
        if let artworkData = await musicArtworkData(for: trackKey) {
            result["artworkData"] = artworkData
        }

        // playerState 是 FourCC 枚举（playing=1800426320），ScriptingBridge 无法直接比较
        // 用 AppleScript 获取播放状态
        if let rate = await fetchPlaybackRateViaAppleScript(app: .music) {
            result["playbackRate"] = rate
        }

        return result.isEmpty ? nil : result
    }

    /// 通过 AppleScript 获取指定应用的播放状态（异步执行，不阻塞调用线程）
    private static func fetchPlaybackRateViaAppleScript(app: SupportedApp) async -> Double? {
        let appName = app.rawValue
        let source = """
        tell application "\(appName)"
            if player state is playing then
                return 1
            else
                return 0
            end if
        end tell
        """
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                var error: NSDictionary?
                guard let script = NSAppleScript(source: source) else {
                    continuation.resume(returning: nil)
                    return
                }
                let result = script.executeAndReturnError(&error)
                guard error == nil else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: result.doubleValue)
            }
        }
    }

    /// 通过 AppleScript 获取指定应用的真实播放位置（秒）
    private static func fetchPlaybackPositionViaAppleScript(app: SupportedApp) async -> Double? {
        let appName = app.rawValue
        let source = """
        tell application "\(appName)"
            return player position
        end tell
        """
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                var error: NSDictionary?
                guard let script = NSAppleScript(source: source) else {
                    continuation.resume(returning: nil)
                    return
                }
                let result = script.executeAndReturnError(&error)
                guard error == nil else {
                    continuation.resume(returning: nil)
                    return
                }
                let position = result.doubleValue
                continuation.resume(returning: position.isFinite && position >= 0 ? position : nil)
            }
        }
    }

    // MARK: - 封面缓存

    private struct ArtworkCacheEntry: Sendable {
        let trackKey: String
        let data: Data
    }

    private actor ArtworkCache {
        private var entry: ArtworkCacheEntry?

        func data(for trackKey: String) -> Data? {
            guard entry?.trackKey == trackKey else { return nil }
            return entry?.data
        }

        func store(_ data: Data, for trackKey: String) {
            entry = ArtworkCacheEntry(trackKey: trackKey, data: data)
        }
    }

    private static let artworkCache = ArtworkCache()

    /// 曲目标识，用于判断是否需要重新拉取封面
    static func artworkCacheKey(title: String, artist: String, album: String) -> String {
        // 用不可见分隔符拼接，避免字段内容串位导致 key 冲突
        [title, artist, album].joined(separator: "\u{1F}")
    }

    /// 获取 Music.app 封面：命中缓存直接返回；未命中才走 AppleScript
    private static func musicArtworkData(for trackKey: String) async -> Data? {
        if let cached = await artworkCache.data(for: trackKey) { return cached }
        // 拉取失败（如暂停时脚本返回空）不写缓存，下个轮询周期重试
        guard let data = await fetchMusicArtwork() else { return nil }
        await artworkCache.store(data, for: trackKey)
        return data
    }

    /// 通过 AppleScript 获取 Music.app 当前曲目封面（异步执行，不阻塞调用线程）
    private static func fetchMusicArtwork() async -> Data? {
        let source = """
        tell application "Music"
            if player state is playing then
                set t to current track
                if (count of artwork of t) > 0 then
                    return raw data of artwork 1 of t
                end if
            end if
        end tell
        """
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                var error: NSDictionary?
                guard let script = NSAppleScript(source: source) else {
                    continuation.resume(returning: nil)
                    return
                }
                let result = script.executeAndReturnError(&error)
                guard error == nil else {
                    continuation.resume(returning: nil)
                    return
                }
                let data = result.data
                continuation.resume(returning: data.isEmpty ? nil : data)
            }
        }
    }

    /// 从 Spotify 获取当前播放信息
    static func getNowPlayingFromSpotify() async -> [String: Any]? {
        guard let app = SBApplication(bundleIdentifier: "com.spotify.client") else { return nil }

        var result: [String: Any] = ["source": SupportedApp.spotify.rawValue]

        guard app.responds(to: NSSelectorFromString("currentTrack")),
              let track = app.value(forKey: "currentTrack") as? NSObject else { return nil }

        if let name = safeValue(track, key: "name") as? String {
            result["title"] = name
        }
        if let artist = safeValue(track, key: "artist") as? String {
            result["artist"] = artist
        }
        if let album = safeValue(track, key: "album") as? String {
            result["album"] = album
        }
        if let duration = safeValue(track, key: "duration") as? Double {
            result["duration"] = duration / 1000.0
        }

        // playerPosition 是真实的播放位置（秒），用于同步歌词时间轴。
        // 优先用 AppleScript 的真实位置，避免 ScriptingBridge 的静态值阻塞歌词时间轴。
        let scriptingBridgePosition = app.value(forKey: "playerPosition") as? Double
        let appleScriptPosition = await fetchPlaybackPositionViaAppleScript(app: .spotify)
        if let position = resolvedPlaybackPosition(
            scriptingBridgePosition: scriptingBridgePosition,
            appleScriptPosition: appleScriptPosition
        ) {
            result["playerPosition"] = position
            result["positionTimestamp"] = Date()
        }

        // playerState 是 FourCC 枚举（playing=1800426320），ScriptingBridge 无法直接比较
        // 用 AppleScript 获取播放状态
        if let rate = await fetchPlaybackRateViaAppleScript(app: .spotify) {
            result["playbackRate"] = rate
        }

        return result.isEmpty ? nil : result
    }

    static func selectNowPlayingInfo(
        music: [String: Any]?,
        spotify: [String: Any]?
    ) -> [String: Any] {
        if let music, (music["playbackRate"] as? Double ?? 0) > 0 {
            return music
        }
        if let spotify, (spotify["playbackRate"] as? Double ?? 0) > 0 {
            return spotify
        }
        return music ?? spotify ?? [:]
    }

    static func supportedApp(from info: [String: Any]) -> SupportedApp? {
        guard let source = info["source"] as? String else { return nil }
        return SupportedApp(rawValue: source)
    }

    /// 对当前来源应用执行控制命令。使用 AppleScript 可可靠命中 Music 和 Spotify。
    static func sendCommand(_ command: PlaybackCommand, to app: SupportedApp) async -> Bool {
        let source = """
        tell application "\(app.rawValue)"
            \(command.appleScriptStatement)
        end tell
        """
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                var error: NSDictionary?
                guard let script = NSAppleScript(source: source) else {
                    continuation.resume(returning: false)
                    return
                }
                _ = script.executeAndReturnError(&error)
                continuation.resume(returning: error == nil)
            }
        }
    }

    @MainActor
    static func activate(_ app: SupportedApp) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleIdentifier) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
    }

    /// 优先使用 AppleScript 的真实位置；不可用时回退到 ScriptingBridge。
    static func resolvedPlaybackPosition(
        scriptingBridgePosition: Double?,
        appleScriptPosition: Double?
    ) -> Double? {
        if let appleScriptPosition,
           appleScriptPosition.isFinite,
           appleScriptPosition >= 0 {
            return appleScriptPosition
        }
        if let scriptingBridgePosition,
           scriptingBridgePosition.isFinite,
           scriptingBridgePosition >= 0 {
            return scriptingBridgePosition
        }
        return nil
    }

    /// 获取当前播放信息（优先选择正在播放的来源）
    static func getNowPlayingInfo() async -> [String: Any] {
        let musicRunning = !NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.Music"
        ).isEmpty
        let spotifyRunning = !NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.spotify.client"
        ).isEmpty

        // 并行获取两个播放器的信息
        async let musicInfo: [String: Any]? = musicRunning ? getNowPlayingFromMusic() : nil
        async let spotifyInfo: [String: Any]? = spotifyRunning ? getNowPlayingFromSpotify() : nil

        return selectNowPlayingInfo(music: await musicInfo, spotify: await spotifyInfo)
    }
}
