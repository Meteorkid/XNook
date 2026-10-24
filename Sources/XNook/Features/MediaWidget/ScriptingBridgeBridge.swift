import AppKit
import Carbon

// MARK: - 脚本桥接获取播放信息

enum ScriptingBridgeHelper {

    /// 支持的媒体应用枚举，从类型系统层面防止 AppleScript 注入
    enum SupportedApp: String, Sendable {
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

    typealias ScriptExecution = (String, SupportedApp) async -> NSAppleEventDescriptor?
    typealias HandlerExecution = (String, SupportedApp, MediaSeekArguments) async -> NSAppleEventDescriptor?

    static func isRunning(_ app: SupportedApp) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleIdentifier).isEmpty
    }

    // MARK: - AppleScript 执行

    /// 已编译脚本的复用容器。
    ///
    /// 脚本源码是常量，复用实例可避免每秒轮询都重新编译。
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

        func runHandler(_ source: String, arguments: MediaSeekArguments) async -> NSAppleEventDescriptor? {
            let cancellation = ScriptCancellation()
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    queue.async {
                        guard !cancellation.isCancelled,
                              let script = self.compiled[source] ?? NSAppleScript(source: source) else {
                            continuation.resume(returning: nil)
                            return
                        }
                        self.compiled[source] = script
                        // Foundation 描述符只在执行队列内创建和使用，跨队列仅传值类型。
                        let event = ScriptingBridgeHelper.seekEvent(seconds: arguments.seconds, identity: arguments.identity)
                        var error: NSDictionary?
                        let result = script.executeAppleEvent(event, error: &error)
                        continuation.resume(returning: error == nil && !cancellation.isCancelled ? result : nil)
                    }
                }
            } onCancel: {
                cancellation.cancel()
            }
        }
    }

    private final class ScriptCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
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

    private static func runSeekHandler(_ source: String, on app: SupportedApp, arguments: MediaSeekArguments) async -> NSAppleEventDescriptor? {
        await scriptRunners[app]?.runHandler(source, arguments: arguments)
    }

    /// 单次脚本往返收集元数据；位置最后采样，封面走独立队列。
    static func snapshotScript(for app: SupportedApp) -> String {
        """
        with timeout of 2 seconds
            if application id "\(app.bundleIdentifier)" is not running then return missing value
            tell application id "\(app.bundleIdentifier)"
                set snapshotState to player state
                if snapshotState is stopped then return {"", "", "", 0, 0, missing value}
                set snapshotTrack to current track
                set snapshotTitle to name of snapshotTrack
                set snapshotArtist to artist of snapshotTrack
                set snapshotAlbum to album of snapshotTrack
                set snapshotDuration to duration of snapshotTrack
                set snapshotID to ""
                try
                    set snapshotID to (\(app == .music ? "persistent ID" : "id") of snapshotTrack) as text
                end try
                set snapshotRate to 0
                if snapshotState is playing then set snapshotRate to 1
                set snapshotPosition to player position
                if snapshotID is not "" then
                    if ((\(app == .music ? "persistent ID" : "id") of current track) as text) is not snapshotID then return missing value
                end if
                return {snapshotTitle, snapshotArtist, snapshotAlbum, snapshotDuration, snapshotRate, snapshotPosition, snapshotID}
            end tell
        end timeout
        """
    }

    /// AppleEvent 的 missing value / 文本不能被 doubleValue 静默转换成有效的 0 秒。
    private static func numericValue(_ descriptor: NSAppleEventDescriptor?) -> Double? {
        guard let descriptor else { return nil }
        switch descriptor.descriptorType {
        case typeSInt16, typeSInt32, typeUInt32, typeSInt64, typeUInt64,
             typeIEEE32BitFloatingPoint, typeIEEE64BitFloatingPoint, type128BitFloatingPoint:
            let value = descriptor.doubleValue
            return value.isFinite && value >= 0 ? value : nil
        default:
            return nil
        }
    }

    static func parseSnapshot(
        _ descriptor: NSAppleEventDescriptor,
        from app: SupportedApp,
        sampledAt: Date = Date()
    ) -> [String: Any]? {
        guard descriptor.descriptorType == typeAEList, (6...7).contains(descriptor.numberOfItems),
              let title = descriptor.atIndex(1)?.stringValue,
              let artist = descriptor.atIndex(2)?.stringValue,
              let album = descriptor.atIndex(3)?.stringValue,
              let rate = numericValue(descriptor.atIndex(5)), rate == 0 || rate == 1 else { return nil }
        guard !title.isEmpty || rate == 0 else { return nil }
        var info: [String: Any] = [
            "source": app.rawValue, "title": title, "artist": artist,
            "album": album, "playbackRate": rate,
        ]
        if let duration = numericValue(descriptor.atIndex(4)) {
            info["duration"] = app == .spotify ? duration / 1000 : duration
        }
        if let position = numericValue(descriptor.atIndex(6)) {
            info["playerPosition"] = position
            info["positionTimestamp"] = sampledAt
        }
        if let id = descriptor.atIndex(7)?.stringValue, !id.isEmpty { info["trackID"] = id }
        return info
    }

    /// 参数单独编码为 AppleEvent，秒数和曲目文本不进入已编译脚本的缓存键。
    static func seekEvent(seconds: TimeInterval, identity: MediaTrackIdentity) -> NSAppleEventDescriptor {
        let arguments = NSAppleEventDescriptor.list()
        arguments.insert(NSAppleEventDescriptor(double: seconds), at: 1)
        for (index, value) in [identity.id, identity.title, identity.artist, identity.album].enumerated() {
            arguments.insert(NSAppleEventDescriptor(string: value), at: index + 2)
        }
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kASAppleScriptSuite),
            eventID: AEEventID(kASSubroutineEvent), targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: "seektoposition"), forKeyword: AEKeyword(keyASSubroutineName))
        event.setParam(arguments, forKeyword: AEKeyword(keyDirectObject))
        return event
    }

    /// 写前重查与写后回读用于发现切歌；多个跨进程 AppleEvent 并非原子事务。
    static func seekScript(for app: SupportedApp) -> String {
        """
        on seekToPosition(targetSeconds, expectedID, expectedTitle, expectedArtist, expectedAlbum)
            with timeout of 2 seconds
                if application id "\(app.bundleIdentifier)" is not running then return missing value
                tell application id "\(app.bundleIdentifier)"
                    set targetTrack to current track
                    if ((\(app == .music ? "persistent ID" : "id") of targetTrack) as text) is not expectedID then return false
                    if name of targetTrack is not expectedTitle then return false
                    if artist of targetTrack is not expectedArtist then return false
                    if album of targetTrack is not expectedAlbum then return false
                    set trackSeconds to duration of targetTrack\(app == .spotify ? " / 1000" : "")
                    if trackSeconds is less than or equal to 0 then return missing value
                    if targetSeconds is greater than trackSeconds then set targetSeconds to trackSeconds
                    if ((\(app == .music ? "persistent ID" : "id") of current track) as text) is not expectedID then return false
                    set player position to targetSeconds
                    return true
                end tell
            end timeout
        end seekToPosition
        """
    }

    static func seek(
        to seconds: TimeInterval, context: MediaSeekContext,
        isRunning: (SupportedApp) -> Bool = isRunning,
        executeHandler: HandlerExecution = runSeekHandler,
        execute: ScriptExecution = runScript,
        sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: () -> Date = Date.init
    ) async -> MediaSeekResult {
        guard seconds.isFinite, seconds >= 0, context.duration.isFinite, context.duration > 0, context.duration < Double(Int.max),
              !context.identity.id.isEmpty, !Task.isCancelled, isRunning(context.identity.source) else {
            return .failed(.unavailable)
        }
        let target = min(seconds, context.duration)
        let app = context.identity.source
        let reply = await executeHandler(seekScript(for: app), app,
            MediaSeekArguments(seconds: target, identity: context.identity))
        guard !Task.isCancelled else { return .failed(.unavailable) }
        guard let reply, reply.descriptorType == typeBoolean else { return .failed(.commandFailed) }
        guard reply.booleanValue else { return .failed(.trackChanged) }
        let writeFinishedAt = now()
        for attempt in 0..<2 {
            if attempt > 0 {
                do { try await sleep(.milliseconds(200)) }
                catch { return .failed(.unconfirmed) }
            }
            guard !Task.isCancelled, isRunning(app) else { return .failed(.unavailable) }
            guard let descriptor = await execute(snapshotScript(for: app), app), !Task.isCancelled,
                  let info = parseSnapshot(descriptor, from: app, sampledAt: now()) else { continue }
            guard MediaTrackIdentity(info: info) == context.identity else { return .failed(.trackChanged) }
            if let confirmation = MediaSeekConfirmation(info: info, writeFinishedAt: writeFinishedAt),
               confirmation.confirms(target, since: writeFinishedAt) {
                return .confirmed(confirmation)
            }
        }
        return .failed(.unconfirmed)
    }

    static func getNowPlayingFromMusic(
        isRunning: (SupportedApp) -> Bool = isRunning,
        execute: ScriptExecution = runScript
    ) async -> [String: Any]? {
        await getSnapshot(from: .music, isRunning: isRunning, execute: execute)
    }

    static func getNowPlayingFromSpotify(
        isRunning: (SupportedApp) -> Bool = isRunning,
        execute: ScriptExecution = runScript
    ) async -> [String: Any]? {
        await getSnapshot(from: .spotify, isRunning: isRunning, execute: execute)
    }

    private static func getSnapshot(
        from app: SupportedApp,
        isRunning: (SupportedApp) -> Bool,
        execute: ScriptExecution
    ) async -> [String: Any]? {
        guard isRunning(app), let descriptor = await execute(snapshotScript(for: app), app) else { return nil }
        return parseSnapshot(descriptor, from: app, sampledAt: Date())
    }

    // MARK: - 封面缓存

    /// 封面失败也缓存短暂结果，避免无封面的流媒体每秒发送一次慢请求。
    actor ArtworkCache {
        private let retryDelay: TimeInterval
        private var entry: (trackKey: String, data: Data?, retryAfter: Date)?
        private var pending: [String: (requestID: Int, task: Task<Data?, Never>)] = [:]
        private var requestID = 0

        init(retryDelay: TimeInterval = 30) {
            self.retryDelay = retryDelay
        }

        func data(
            for trackKey: String,
            allowLoading: Bool = true,
            now: Date = Date(),
            load: @escaping () async -> Data?
        ) async -> Data? {
            guard !Task.isCancelled else { return nil }
            if let entry, entry.trackKey == trackKey {
                if let data = entry.data { return data }
                if now < entry.retryAfter { return nil }
            }
            guard allowLoading else { return nil }
            if let request = pending[trackKey], !request.task.isCancelled {
                let data = await request.task.value
                return Task.isCancelled || request.task.isCancelled ? nil : data
            }
            requestID &+= 1
            let generation = requestID
            let task = Task { await load() }
            pending[trackKey] = (generation, task)
            let data = await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
            // 快速切回同一首歌会替换已取消的任务，旧任务收尾不能移除新请求。
            if pending[trackKey]?.requestID == generation {
                pending[trackKey] = nil
            }
            guard !task.isCancelled else { return nil }
            // 旧曲目的慢请求不能把新曲目的缓存挤掉。
            if generation == requestID {
                entry = (trackKey, data, now.addingTimeInterval(retryDelay))
            }
            return Task.isCancelled ? nil : data
        }
    }

    private static let artworkCache = ArtworkCache()
    private static let artworkRunners: [SupportedApp: ScriptRunner] = [
        .music: ScriptRunner(label: "com.xnook.applescript.music.artwork"),
        .spotify: ScriptRunner(label: "com.xnook.applescript.spotify.artwork"),
    ]

    static func artworkCacheKey(title: String, artist: String, album: String, source: SupportedApp = .music) -> String {
        [source.rawValue, title, artist, album].joined(separator: "\u{1F}")
    }

    static let musicArtworkScript = """
    with timeout of 2 seconds
        if application id "com.apple.Music" is not running then return missing value
        tell application id "com.apple.Music"
            if player state is not playing then return missing value
            set artworkTrack to current track
            set beforeTitle to name of artworkTrack
            set beforeArtist to artist of artworkTrack
            set beforeAlbum to album of artworkTrack
            if (count of artwork of artworkTrack) is 0 then return missing value
            set artworkBytes to raw data of artwork 1 of artworkTrack
            set afterTrack to current track
            return {beforeTitle, beforeArtist, beforeAlbum, artworkBytes, name of afterTrack, artist of afterTrack, album of afterTrack}
        end tell
    end timeout
    """

    static let spotifyArtworkScript = """
    with timeout of 2 seconds
        if application id "com.spotify.client" is not running then return missing value
        tell application id "com.spotify.client"
            if player state is not playing then return missing value
            set artworkTrack to current track
            set beforeTitle to name of artworkTrack
            set beforeArtist to artist of artworkTrack
            set beforeAlbum to album of artworkTrack
            set artworkURL to artwork url of artworkTrack
            set afterTrack to current track
            return {beforeTitle, beforeArtist, beforeAlbum, artworkURL, name of afterTrack, artist of afterTrack, album of afterTrack}
        end tell
    end timeout
    """

    private static func artworkValue(
        _ descriptor: NSAppleEventDescriptor,
        expectedTrackKey: String,
        source: SupportedApp
    ) -> NSAppleEventDescriptor? {
        guard descriptor.descriptorType == typeAEList, descriptor.numberOfItems == 7,
              let beforeTitle = descriptor.atIndex(1)?.stringValue,
              let beforeArtist = descriptor.atIndex(2)?.stringValue,
              let beforeAlbum = descriptor.atIndex(3)?.stringValue,
              let afterTitle = descriptor.atIndex(5)?.stringValue,
              let afterArtist = descriptor.atIndex(6)?.stringValue,
              let afterAlbum = descriptor.atIndex(7)?.stringValue,
              artworkCacheKey(title: beforeTitle, artist: beforeArtist, album: beforeAlbum, source: source) == expectedTrackKey,
              artworkCacheKey(title: afterTitle, artist: afterArtist, album: afterAlbum, source: source) == expectedTrackKey else { return nil }
        return descriptor.atIndex(4)
    }

    static func parseArtwork(_ descriptor: NSAppleEventDescriptor, expectedTrackKey: String) -> Data? {
        guard let dataDescriptor = artworkValue(descriptor, expectedTrackKey: expectedTrackKey, source: .music),
              dataDescriptor.descriptorType != typeNull,
              dataDescriptor.descriptorType != typeType,
              !dataDescriptor.data.isEmpty else { return nil }
        return dataDescriptor.data
    }

    static func parseSpotifyArtworkURL(_ descriptor: NSAppleEventDescriptor, expectedTrackKey: String) -> URL? {
        guard let value = artworkValue(descriptor, expectedTrackKey: expectedTrackKey, source: .spotify)?.stringValue,
              let url = URL(string: value), ArtworkDownload.isAllowedURL(url) else { return nil }
        return url
    }

    private static func runArtworkScript(_ source: String, on app: SupportedApp) async -> NSAppleEventDescriptor? {
        await artworkRunners[app]?.run(source)
    }

    /// 元数据获取不等待封面；调用方需在接收结果时再次核对当前曲目。
    static func getArtwork(
        for info: [String: Any],
        cache: ArtworkCache = artworkCache,
        isRunning: (SupportedApp) -> Bool = isRunning,
        download: @escaping ArtworkDownload.LoadRequest = ArtworkDownload.loadBoundedResponse,
        execute: @escaping ScriptExecution = runArtworkScript
    ) async -> Data? {
        guard let app = supportedApp(from: info), isRunning(app), !Task.isCancelled,
              let title = info["title"] as? String, !title.isEmpty else { return nil }
        let key = artworkCacheKey(
            title: title, artist: info["artist"] as? String ?? "", album: info["album"] as? String ?? "", source: app
        )
        return await cache.data(for: key, allowLoading: (info["playbackRate"] as? Double ?? 0) > 0) {
            let script = app == .music ? musicArtworkScript : spotifyArtworkScript
            guard !Task.isCancelled, let descriptor = await execute(script, app), !Task.isCancelled else { return nil }
            switch app {
            case .music:
                return parseArtwork(descriptor, expectedTrackKey: key)
            case .spotify:
                guard let url = parseSpotifyArtworkURL(descriptor, expectedTrackKey: key) else { return nil }
                return await ArtworkDownload.data(from: url, load: download)
            }
        }
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
        if let music, let title = music["title"] as? String,
           !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return music
        }
        if let spotify, let title = spotify["title"] as? String,
           !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return spotify
        }
        return music ?? spotify ?? [:]
    }

    static func supportedApp(from info: [String: Any]) -> SupportedApp? {
        guard let source = info["source"] as? String else { return nil }
        return SupportedApp(rawValue: source)
    }

    /// 对当前来源应用执行控制命令。使用 AppleScript 可可靠命中 Music 和 Spotify。
    static func commandScript(_ command: PlaybackCommand, for app: SupportedApp) -> String {
        """
        with timeout of 2 seconds
            if application id "\(app.bundleIdentifier)" is not running then return missing value
            tell application id "\(app.bundleIdentifier)"
                \(command.appleScriptStatement)
            end tell
            return true
        end timeout
        """
    }

    static func sendCommand(_ command: PlaybackCommand, to app: SupportedApp) async -> Bool {
        guard isRunning(app) else { return false }
        return await runScript(commandScript(command, for: app), on: app)?.booleanValue == true
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

    /// 将暂时读取失败与播放器全部退出分开，避免短暂超时清空歌词和时间轴。
    static func getNowPlayingInfo(
        isRunning: (SupportedApp) -> Bool = isRunning,
        execute: ScriptExecution = runScript
    ) async -> [String: Any] {
        let musicRunning = isRunning(.music)
        let spotifyRunning = isRunning(.spotify)
        guard musicRunning || spotifyRunning else { return [:] }
        async let musicInfo = musicRunning ? getNowPlayingFromMusic(isRunning: isRunning, execute: execute) : nil
        async let spotifyInfo = spotifyRunning ? getNowPlayingFromSpotify(isRunning: isRunning, execute: execute) : nil
        let selected = await selectNowPlayingInfo(music: musicInfo, spotify: spotifyInfo)
        guard selected.isEmpty else { return selected }
        return isRunning(.music) || isRunning(.spotify) ? ["fetchFailed": true] : [:]
    }
}
