import AppKit
import ScriptingBridge

// MARK: - 脚本桥接获取播放信息

enum ScriptingBridgeHelper {

    /// 安全获取 NSObject 的值
    private static func safeValue(_ object: NSObject?, key: String) -> Any? {
        guard let obj = object, obj.responds(to: NSSelectorFromString(key)) else { return nil }
        return obj.value(forKey: key)
    }

    /// 从 Music.app 获取当前播放信息
    static func getNowPlayingFromMusic() async -> [String: Any]? {
        guard let app = SBApplication(bundleIdentifier: "com.apple.Music") else { return nil }

        var result: [String: Any] = [:]

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

        // playerPosition 是真实的播放位置（秒），用于同步歌词时间轴
        if let pos = app.value(forKey: "playerPosition") as? Double {
            result["playerPosition"] = pos
        }

        // 用 AppleScript 获取封面（ScriptingBridge 的 artwork 属性不可用）
        if let artworkData = await fetchMusicArtwork() {
            result["artworkData"] = artworkData
        }

        // playerState 是 FourCC 枚举（playing=1800426320），ScriptingBridge 无法直接比较
        // 用 AppleScript 获取播放状态
        if let rate = await fetchPlaybackRateViaAppleScript(appName: "Music") {
            result["playbackRate"] = rate
        }

        return result.isEmpty ? nil : result
    }

    /// 通过 AppleScript 获取指定应用的播放状态（异步执行，不阻塞调用线程）
    private static func fetchPlaybackRateViaAppleScript(appName: String) async -> Double? {
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

        var result: [String: Any] = [:]

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

        // playerPosition 是真实的播放位置（秒），用于同步歌词时间轴
        if let pos = app.value(forKey: "playerPosition") as? Double {
            result["playerPosition"] = pos
        }

        // playerState 是 FourCC 枚举（playing=1800426320），ScriptingBridge 无法直接比较
        // 用 AppleScript 获取播放状态
        if let rate = await fetchPlaybackRateViaAppleScript(appName: "Spotify") {
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
