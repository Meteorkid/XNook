import SwiftUI
import AppKit
import CoreAudio
import Observation

private final class MediaManagerCleanup: @unchecked Sendable {
    private let lock = NSLock()
    private var infoObserver: NSObjectProtocol?
    private var playingObserver: NSObjectProtocol?
    private var infoTimer: Timer?
    private var progressTimer: Timer?

    func storeInfoObserver(_ observer: NSObjectProtocol?) {
        lock.lock()
        infoObserver = observer
        lock.unlock()
    }

    func storePlayingObserver(_ observer: NSObjectProtocol?) {
        lock.lock()
        playingObserver = observer
        lock.unlock()
    }

    func storeInfoTimer(_ timer: Timer?) {
        lock.lock()
        infoTimer = timer
        lock.unlock()
    }

    func hasProgressTimer() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return progressTimer != nil
    }

    func storeProgressTimer(_ timer: Timer?) {
        lock.lock()
        progressTimer = timer
        lock.unlock()
    }

    func invalidateProgressTimer() {
        lock.lock()
        let timer = progressTimer
        progressTimer = nil
        lock.unlock()
        timer?.invalidate()
    }

    func cleanUp() {
        lock.lock()
        let infoObserver = infoObserver
        let playingObserver = playingObserver
        let infoTimer = infoTimer
        let progressTimer = progressTimer
        self.infoObserver = nil
        self.playingObserver = nil
        self.infoTimer = nil
        self.progressTimer = nil
        lock.unlock()

        infoTimer?.invalidate()
        progressTimer?.invalidate()
        if let infoObserver { NotificationCenter.default.removeObserver(infoObserver) }
        if let playingObserver { NotificationCenter.default.removeObserver(playingObserver) }
    }
}

struct MediaInfoFetchGate {
    private(set) var isInFlight = false
    private var currentRequestID = 0

    mutating func begin() -> Int? {
        guard !isInFlight else { return nil }
        currentRequestID &+= 1
        isInFlight = true
        return currentRequestID
    }

    mutating func timeout(requestID: Int) {
        guard isInFlight, requestID == currentRequestID else { return }
        isInFlight = false
    }

    mutating func finish(requestID: Int) -> Bool {
        guard isInFlight, requestID == currentRequestID else { return false }
        isInFlight = false
        return true
    }
}

/// 媒体播放管理器 — 通过 MediaRemote 私有框架控制系统级播放器
@Observable @MainActor
final class MediaManager {
    // MARK: - Published Properties

    var isPlaying = false
    var playbackRate: Double = 0
    var currentTitle: String = ""
    var currentArtist: String = ""
    var currentAlbum: String = ""
    var currentLyricLine: String = ""
    /// 仅存储原始 Data，NSImage 按需创建，避免同时持有两份图像数据
    var currentArtworkData: Data?
    /// 封面版本号，每次切歌递增，用于 SwiftUI 强制刷新
    var artworkVersion: Int = 0
    var duration: TimeInterval = 0
    var elapsedTime: TimeInterval = 0
    var isAvailable = false
    private(set) var currentSource: ScriptingBridgeHelper.SupportedApp?

    /// 缓存的 NSImage 实例，仅在 currentArtworkData 变化时重建
    private var cachedArtworkImage: NSImage?
    private var cachedArtworkData: Data?

    /// 获取封面 NSImage（带缓存，避免每次访问都从 Data 重建）
    var currentArtwork: NSImage? {
        if currentArtworkData != cachedArtworkData {
            cachedArtworkData = currentArtworkData
            cachedArtworkImage = currentArtworkData.flatMap { NSImage(data: $0) }
        }
        return cachedArtworkImage
    }

    /// 歌词管理器
    let lyricsManager = LyricsManager()

    // MARK: - Private Properties

    /// 存储 MediaRemote 是否可用（不使用 @Published，避免 deinit 问题）
    private let mediaRemoteAvailable: Bool
    /// 为非隔离 deinit 保留的线程安全资源容器。
    private let cleanup = MediaManagerCleanup()
    /// 上次 ScriptingBridge 同步时的时间戳
    private var lastSyncTime: Date = Date()
    /// 上次同步时的播放位置
    private var syncedElapsedTime: TimeInterval = 0
    /// 仅在播放器提供真实位置后才推进歌词时间轴，避免从 0 秒伪造同步。
    private var hasAuthoritativePlaybackPosition = false
    /// 用户手动操作播放控制后的保护截止时间（防止 ScriptingBridge 延迟覆盖）
    private var userActionDeadline: Date = .distantPast

    // MARK: - Init

    init() {
        let available = MediaRemoteBridge.isAvailable
        isAvailable = available
        mediaRemoteAvailable = available
        // MediaRemote 可用时注册系统通知（快速响应）
        // 不可用时仍可通过 ScriptingBridge 轮询获取信息
        if available {
            registerNotifications()
        }
        // 立即获取一次（ScriptingBridge 不依赖 MediaRemote）
        fetchNowPlayingInfo()
        // 延迟再获取一次
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.fetchNowPlayingInfo()
        }
        // 启动定时器轮询 ScriptingBridge（始终运行）
        startTimers()
    }

    deinit {
        cleanup.cleanUp()
        if mediaRemoteAvailable {
            MediaRemoteBridge.unregisterForNotifications()
        }
    }

    // MARK: - 双定时器架构

    private func startTimers() {
        // 慢速轮询：拉取 ScriptingBridge（歌曲信息 + 封面 + 位置校准）
        // .common mode：菜单跟踪、拖拽等 event tracking 期间保持歌词推进不冻结
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.fetchNowPlayingInfo()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        cleanup.storeInfoTimer(timer)
        // 快速轮询：0.05s 本地计时，更新歌词（无 IPC 开销）
        // 仅在有播放内容时启动，节省 CPU 和电量
        startProgressTimerIfNeeded()
    }

    /// 根据当前播放状态决定是否启动/停止 progressTimer
    private func startProgressTimerIfNeeded() {
        let lyricsEnabled = UserDefaults.standard.bool(forKey: "showLyrics")
        let needsTimer = Self.shouldAdvanceLyricTimeline(
            isPlaying: isPlaying,
            lyricsEnabled: lyricsEnabled,
            hasAuthoritativePlaybackPosition: hasAuthoritativePlaybackPosition
        )

        if needsTimer && !cleanup.hasProgressTimer() {
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    let now = Date()
                    let delta = now.timeIntervalSince(self.lastSyncTime) * self.playbackRate
                    self.elapsedTime = self.syncedElapsedTime + delta
                    // 先根据时间推进更新歌词行，再比较避免无意义赋值触发重绘
                    self.lyricsManager.updateCurrentLine(elapsedTime: self.elapsedTime)
                    if self.lyricsManager.currentLine != self.currentLyricLine {
                        self.currentLyricLine = self.lyricsManager.currentLine
                    }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            cleanup.storeProgressTimer(timer)
        } else if !needsTimer && cleanup.hasProgressTimer() {
            cleanup.invalidateProgressTimer()
        }
    }

    /// 停止 progressTimer（用于无播放内容时彻底停止）
    private func stopProgressTimer() {
        cleanup.invalidateProgressTimer()
    }

    // MARK: - 通知注册

    private func registerNotifications() {
        MediaRemoteBridge.registerForNotifications()

        cleanup.storeInfoObserver(NotificationCenter.default.addObserver(
            forName: NSNotification.Name(MediaRemoteBridge.nowPlayingInfoDidChange as String),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.fetchNowPlayingInfo()
            }
        })

        cleanup.storePlayingObserver(NotificationCenter.default.addObserver(
            forName: NSNotification.Name(MediaRemoteBridge.nowPlayingApplicationIsPlayingDidChange as String),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.fetchPlaybackState()
            }
        })
    }

    // MARK: - 获取 Now Playing 信息

    private var lastFetchedTitle = ""
    private var lastFetchedArtist = ""
    private var lastFetchedAlbum = ""
    private var lastFetchedDuration: TimeInterval?
    private var lastLyricsEnabled = false

    static func hasTrackIdentityChanged(
        title: String,
        artist: String,
        album: String,
        previousTitle: String,
        previousArtist: String,
        previousAlbum: String
    ) -> Bool {
        title != previousTitle || artist != previousArtist || album != previousAlbum
    }

    static func shouldSyncLyrics(
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval?,
        isEnabled: Bool,
        previousTitle: String,
        previousArtist: String,
        previousAlbum: String,
        previousDuration: TimeInterval?,
        wasEnabled: Bool
    ) -> Bool {
        hasTrackIdentityChanged(
            title: title,
            artist: artist,
            album: album,
            previousTitle: previousTitle,
            previousArtist: previousArtist,
            previousAlbum: previousAlbum
        )
            || duration != previousDuration
            || isEnabled != wasEnabled
    }

    static func shouldAdvanceLyricTimeline(
        isPlaying: Bool,
        lyricsEnabled: Bool,
        hasAuthoritativePlaybackPosition: Bool
    ) -> Bool {
        isPlaying && lyricsEnabled && hasAuthoritativePlaybackPosition
    }

    /// 用位置的采样时刻补偿 AppleScript 取值到应用之间的延迟，
    /// 使歌词时间轴以真实播放进度为基准而非收到数据的时刻
    static func compensatedElapsedTime(
        position: TimeInterval,
        sampledAt: Date,
        now: Date,
        playbackRate: Double
    ) -> TimeInterval {
        let latency = max(0, now.timeIntervalSince(sampledAt))
        return max(0, position + latency * max(0, playbackRate))
    }

    /// 防止 AppleScript 偶发慢于轮询间隔时请求堆积、旧位置乱序覆盖新位置。
    private var infoFetchGate = MediaInfoFetchGate()
    private static let infoFetchTimeoutNanoseconds: UInt64 = 5_000_000_000

    func fetchNowPlayingInfo() {
        guard let requestID = infoFetchGate.begin() else { return }

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.infoFetchTimeoutNanoseconds)
            guard !Task.isCancelled else { return }
            self?.infoFetchGate.timeout(requestID: requestID)
        }

        Task.detached { [weak self] in
            // ScriptingBridge 获取（MediaRemote 在非沙盒环境中返回空）
            let info = await ScriptingBridgeHelper.getNowPlayingInfo()
            guard let self else { return }

            await MainActor.run {
                guard self.infoFetchGate.finish(requestID: requestID) else { return }
                let newTitle = info["title"] as? String ?? ""
                let newArtist = info["artist"] as? String ?? ""
                let newAlbum = info["album"] as? String ?? ""
                let trackChanged = Self.hasTrackIdentityChanged(
                    title: newTitle,
                    artist: newArtist,
                    album: newAlbum,
                    previousTitle: self.currentTitle,
                    previousArtist: self.currentArtist,
                    previousAlbum: self.currentAlbum
                )
                if trackChanged {
                    self.currentLyricLine = ""
                    self.hasAuthoritativePlaybackPosition = false
                    self.syncedElapsedTime = 0
                    self.elapsedTime = 0
                    self.duration = 0
                }
                self.currentTitle = newTitle
                self.currentArtist = newArtist
                self.currentAlbum = newAlbum
                self.currentSource = ScriptingBridgeHelper.supportedApp(from: info)

                // 封面提取 — 有新数据才更新，暂停时保留当前封面
                let oldArtworkData = self.currentArtworkData
                if let data = info["artworkData"] as? Data, !data.isEmpty {
                    self.currentArtworkData = data
                } else if let data = Self.extractArtworkData(from: info) {
                    self.currentArtworkData = data
                }
                // 切歌或封面变化时递增版本号，强制 SwiftUI 刷新
                if trackChanged || self.currentArtworkData != oldArtworkData {
                    self.artworkVersion += 1
                }

                if let dur = info["duration"] as? TimeInterval {
                    self.duration = dur
                }
                // 先更新播放速率，位置补偿计算依赖最新速率
                if let rate = info["playbackRate"] as? Double {
                    self.playbackRate = rate
                    // 用户手动操作后的保护期内，不覆盖状态
                    if Date() > self.userActionDeadline {
                        self.isPlaying = rate > 0
                    }
                }
                // 用 playerPosition 校准播放位置（每秒同步一次，防止本地计时漂移）
                // lastSyncTime 取采样时刻：封面等后续 AppleScript 耗时不再拖累时间轴
                if let pos = info["playerPosition"] as? TimeInterval {
                    let sampledAt = info["positionTimestamp"] as? Date ?? Date()
                    self.hasAuthoritativePlaybackPosition = true
                    self.syncedElapsedTime = pos
                    self.lastSyncTime = sampledAt
                    self.elapsedTime = Self.compensatedElapsedTime(
                        position: pos,
                        sampledAt: sampledAt,
                        now: Date(),
                        playbackRate: self.playbackRate
                    )
                }

                // 切歌或歌词开关变化时同步歌词状态
                let lyricsEnabled = UserDefaults.standard.bool(forKey: "showLyrics")
                let lyricDuration = self.duration > 0 ? self.duration : nil
                if Self.shouldSyncLyrics(
                    title: self.currentTitle,
                    artist: self.currentArtist,
                    album: self.currentAlbum,
                    duration: lyricDuration,
                    isEnabled: lyricsEnabled,
                    previousTitle: self.lastFetchedTitle,
                    previousArtist: self.lastFetchedArtist,
                    previousAlbum: self.lastFetchedAlbum,
                    previousDuration: self.lastFetchedDuration,
                    wasEnabled: self.lastLyricsEnabled
                ) {
                    self.lastFetchedTitle = self.currentTitle
                    self.lastFetchedArtist = self.currentArtist
                    self.lastFetchedAlbum = self.currentAlbum
                    self.lastFetchedDuration = lyricDuration
                    self.lastLyricsEnabled = lyricsEnabled
                    if lyricsEnabled && !self.currentTitle.isEmpty {
                        self.lyricsManager.fetchLyrics(
                            title: self.currentTitle,
                            artist: self.currentArtist,
                            album: self.currentAlbum,
                            duration: lyricDuration
                        )
                    } else {
                        self.lyricsManager.reset()
                    }
                }

                // 更新歌词当前行
                if self.hasAuthoritativePlaybackPosition {
                    self.lyricsManager.updateCurrentLine(elapsedTime: self.elapsedTime)
                } else {
                    self.currentLyricLine = ""
                }

                // 根据当前状态决定是否需要 progressTimer
                self.startProgressTimerIfNeeded()
            }
        }
    }

    private func fetchPlaybackState() {
        Task.detached { [weak self] in
            let info = await ScriptingBridgeHelper.getNowPlayingInfo()
            guard let self else { return }

            await MainActor.run {
                if let rate = info["playbackRate"] as? Double {
                    self.playbackRate = rate
                    // 用户手动操作后的保护期内，不覆盖状态
                    if Date() > self.userActionDeadline {
                        self.isPlaying = rate > 0
                    }
                }
                // 播放/暂停切换时重新校准进度
                if let pos = info["playerPosition"] as? TimeInterval {
                    let sampledAt = info["positionTimestamp"] as? Date ?? Date()
                    self.hasAuthoritativePlaybackPosition = true
                    self.syncedElapsedTime = pos
                    self.lastSyncTime = sampledAt
                    self.elapsedTime = Self.compensatedElapsedTime(
                        position: pos,
                        sampledAt: sampledAt,
                        now: Date(),
                        playbackRate: self.playbackRate
                    )
                }
                self.startProgressTimerIfNeeded()
            }
        }
    }

    // MARK: - 播放控制

    func play() {
        sendPlaybackCommand(.play, fallback: .play)
        isPlaying = true
        userActionDeadline = Date().addingTimeInterval(2.0) // 2s 保护期
        startProgressTimerIfNeeded()
    }

    func pause() {
        sendPlaybackCommand(.pause, fallback: .pause)
        isPlaying = false
        userActionDeadline = Date().addingTimeInterval(2.0)
        startProgressTimerIfNeeded()
    }

    func togglePlayPause() {
        MediaRemoteBridge.sendCommand(.togglePlayPause)
        isPlaying.toggle()
        userActionDeadline = Date().addingTimeInterval(2.0)
        startProgressTimerIfNeeded()
    }

    func nextTrack() {
        sendPlaybackCommand(.nextTrack, fallback: .nextTrack)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.fetchNowPlayingInfo()
        }
    }

    func previousTrack() {
        sendPlaybackCommand(.previousTrack, fallback: .previousTrack)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.fetchNowPlayingInfo()
        }
    }

    func openCurrentPlayer() {
        guard let currentSource else { return }
        ScriptingBridgeHelper.activate(currentSource)
    }

    private func sendPlaybackCommand(
        _ command: ScriptingBridgeHelper.PlaybackCommand,
        fallback: MediaRemoteCommand
    ) {
        guard let currentSource else {
            MediaRemoteBridge.sendCommand(fallback)
            return
        }

        Task {
            let succeeded = await ScriptingBridgeHelper.sendCommand(command, to: currentSource)
            if !succeeded {
                MediaRemoteBridge.sendCommand(fallback)
            }
        }
    }

    func setVolume(_ volume: Float) {
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)

        var vol = volume
        var volAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(deviceID, &volAddress, 0, nil, UInt32(MemoryLayout<Float>.size), &vol)
    }

    /// 格式化时间 mm:ss
    func formatTime(_ time: TimeInterval) -> String {
        let mins = Int(time) / 60
        let secs = Int(time) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    /// 从 Now Playing 信息中提取封面 Data
    private static func extractArtworkData(from info: [String: Any]) -> Data? {
        // 尝试常见的封面键名
        let possibleKeys = [
            "artworkData",
            "kMRMediaRemoteNowPlayingInfoArtworkData",
        ]

        for key in possibleKeys {
            if let data = info[key] as? Data, !data.isEmpty {
                return data
            }
            if let nsData = info[key] as? NSData {
                return Data(referencing: nsData)
            }
        }
        return nil
    }
}
