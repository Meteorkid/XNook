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

    // MARK: - AppleScript 执行

    /// 已编译脚本的复用容器。
    ///
    /// NSAppleScript 的主要开销在编译而非执行，而这里的脚本源码都是常量：
    /// 每秒轮询都重新 `NSAppleScript(source:)` 一次纯属浪费。
    ///
    /// NSAppleScript 不是线程安全的 —— 原先靠"每次新建实例"绕开，复用后必须自己
    /// 序列化。每个播放器一条独立串行队列：应用内部本来就是串行 await，不损失并发；
    /// Music 与 Spotify 之间仍可并行，不会让轮询延迟翻倍。
    /// 字典只在该队列上访问，因此 @unchecked Sendable 是成立的。
    private final class ScriptRunner: @unchecked Sendable {
        private let queue: DispatchQueue
        private var compiled: [String: NSAppleScript] = [:]

        init(label: String) {
            queue = DispatchQueue(label: label, qos: .userInitiated)
        }

        func run(_ source: String) async -> NSAppleEventDescriptor? {
            await withCheckedContinuation { continuation in
                queue.async {
                    guard let script = self.compiled[source] ?? NSAppleScript(source: source) else {
                        continuation.resume(returning: nil)
                        return
                    }
                    self.compiled[source] = script
                    var error: NSDictionary?
                    let result = script.executeAndReturnError(&error)
                    continuation.resume(returning: error == nil ? result : nil)
                }
            }
        }
    }

    private static let scriptRunners: [SupportedApp: ScriptRunner] = [
        .music: ScriptRunner(label: "com.xnook.applescript.music"),
        .spotify: ScriptRunner(label: "com.xnook.applescript.spotify"),
    ]

    /// 在目标应用对应的串行队列上执行脚本，复用已编译实例。出错返回 nil。
    private static func runScript(_ source: String, on app: SupportedApp) async -> NSAppleEventDescriptor? {
        guard let runner = scriptRunners[app] else { return nil }
        return await runner.run(source)
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

        // playerState 是 FourCC 枚举（playing=1800426320），ScriptingBridge 无法直接比较
        // 用 AppleScript 获取播放状态。必须排在封面之前：封面能否拉取取决于是否在播放。
        if let rate = await fetchPlaybackRateViaAppleScript(app: .music) {
            result["playbackRate"] = rate
        }

        // 用 AppleScript 获取封面（ScriptingBridge 的 artwork 属性不可用）
        // 封面 payload 大、传输慢，按曲目缓存，仅切歌时重新拉取
        let trackKey = artworkCacheKey(
            title: result["title"] as? String ?? "",
            artist: result["artist"] as? String ?? "",
            album: result["album"] as? String ?? ""
        )
        let isPlaying = (result["playbackRate"] as? Double ?? 0) > 0
        if let artworkData = await musicArtworkData(for: trackKey, isPlaying: isPlaying) {
            result["artworkData"] = artworkData
        }

        return result.isEmpty ? nil : result
    }

    /// 通过 AppleScript 获取指定应用的播放状态（异步执行，不阻塞调用线程）
    private static func fetchPlaybackRateViaAppleScript(app: SupportedApp) async -> Double? {
        let source = """
        tell application "\(app.rawValue)"
            if player state is playing then
                return 1
            else
                return 0
            end if
        end tell
        """
        return await runScript(source, on: app)?.doubleValue
    }

    /// 通过 AppleScript 获取指定应用的真实播放位置（秒）
    private static func fetchPlaybackPositionViaAppleScript(app: SupportedApp) async -> Double? {
        let source = """
        tell application "\(app.rawValue)"
            return player position
        end tell
        """
        guard let position = await runScript(source, on: app)?.doubleValue else { return nil }
        return position.isFinite && position >= 0 ? position : nil
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

    /// 获取 Music.app 封面：命中缓存直接返回；未命中且正在播放才走 AppleScript。
    ///
    /// 暂停时必须跳过：取封面的脚本自身带 `player state is playing` 判断，暂停时
    /// 必然返回空，而失败结果又不写缓存 —— 没有这道判断就会每秒重试一次注定失败的
    /// AppleScript 往返。暂停期间的封面由 MediaManager 保留上一次的结果。
    private static func musicArtworkData(for trackKey: String, isPlaying: Bool) async -> Data? {
        if let cached = await artworkCache.data(for: trackKey) { return cached }
        guard isPlaying else { return nil }
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
        guard let data = await runScript(source, on: .music)?.data, !data.isEmpty else { return nil }
        return data
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
        return await runScript(source, on: app) != nil
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
