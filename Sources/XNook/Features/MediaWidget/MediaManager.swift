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

/// 聚合播放器快照与歌词时间轴，MediaRemote 提供通知和控制兜底。
@Observable @MainActor
final class MediaManager {
    // MARK: - Published Properties

    var isPlaying = false
    var playbackRate: Double = 0
    var currentTitle: String = ""
    var currentArtist: String = ""
    var currentAlbum: String = ""
    var currentLyricLine: String = ""
    /// 当 LRCLIB 仅返回纯歌词（无同步时间轴）时的预览首句。
    /// 仅在 currentLyricLine 为空时由 UI 兜底使用，避免误以为是同步歌词。
    var plainLyricPreview: String { lyricsManager.plainLyricPreview }
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

    /// 从封面提取的强调色。切歌时后台计算，避免在轮询路径上做图像处理。
    private(set) var artworkPalette: AlbumArtworkPalette?
    /// 取色任务的请求号，防止旧封面的结果覆盖新封面
    private var paletteRequestID = 0
    private var paletteTask: Task<Void, Never>?

    /// 获取封面 NSImage（带缓存，避免每次访问都从 Data 重建）
    var currentArtwork: NSImage? {
        if currentArtworkData != cachedArtworkData {
            cachedArtworkData = currentArtworkData
            cachedArtworkImage = currentArtworkData.flatMap { NSImage(data: $0) }
        }
        return cachedArtworkImage
    }

    /// 歌词管理器
    let lyricsManager: LyricsManager
    private let defaults: UserDefaults
    private let infoProvider: @MainActor () async -> [String: Any]
    private let artworkProvider: @MainActor ([String: Any]) async -> Data?
    private let clock: () -> Date
    private let timersEnabled: Bool

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

    init(
        startMonitoring: Bool = true,
        defaults: UserDefaults = .standard,
        lyricsManager: LyricsManager? = nil,
        infoProvider: @escaping @MainActor () async -> [String: Any] = { await ScriptingBridgeHelper.getNowPlayingInfo() },
        artworkProvider: @escaping @MainActor ([String: Any]) async -> Data? = { await ScriptingBridgeHelper.getArtwork(for: $0) },
        clock: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.lyricsManager = lyricsManager ?? LyricsManager(defaults: defaults)
        self.infoProvider = infoProvider
        self.artworkProvider = artworkProvider
        self.clock = clock
        timersEnabled = startMonitoring
        let available = startMonitoring && MediaRemoteBridge.isAvailable
        isAvailable = available
        mediaRemoteAvailable = available
        // 歌词状态变化时重新评估 progressTimer：
        // 歌词加载完成后立刻启动 timer 推进，避免歌词卡在第一行不滚动
        self.lyricsManager.onLyricsStateChanged = { [weak self] in
            self?.refreshLyricLine()
            self?.startProgressTimerIfNeeded()
        }
        guard startMonitoring else { return }
        // MediaRemote 可用时注册系统通知（快速响应）
        // 不可用时仍可通过 AppleScript 轮询获取信息
        if available {
            registerNotifications()
        }
        // 立即获取一次（AppleScript 不依赖 MediaRemote）
        fetchNowPlayingInfo()
        // 延迟再获取一次
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.fetchNowPlayingInfo()
        }
        // 启动播放器快照轮询
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
        // 慢速轮询：获取歌曲信息并校准位置，封面独立读取。
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
        guard timersEnabled else { return }
        let lyricsEnabled = defaults.bool(forKey: "showLyrics")
        let needsTimer = Self.shouldAdvanceLyricTimeline(
            isPlaying: isPlaying,
            lyricsEnabled: lyricsEnabled,
            hasLyrics: lyricsManager.hasLyrics,
            hasAuthoritativePlaybackPosition: hasFreshPlaybackPosition
        )

        if needsTimer && !cleanup.hasProgressTimer() {
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.refreshLyricLine()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            cleanup.storeProgressTimer(timer)
        } else if !needsTimer && cleanup.hasProgressTimer() {
            cleanup.invalidateProgressTimer()
        }
    }

    func refreshLyricLine() {
        guard hasAuthoritativePlaybackPosition else { return }
        guard !isPlaying || hasFreshPlaybackPosition else {
            stopProgressTimer()
            return
        }
        if isPlaying {
            let estimated = Self.compensatedElapsedTime(position: syncedElapsedTime,
                sampledAt: lastSyncTime, now: clock(), playbackRate: playbackRate)
            elapsedTime = duration > 0 ? min(estimated, duration) : estimated
        }
        lyricsManager.updateCurrentLine(elapsedTime: elapsedTime)
        if lyricsManager.currentLine != currentLyricLine {
            currentLyricLine = lyricsManager.currentLine
        }
    }

    private var hasFreshPlaybackPosition: Bool {
        hasAuthoritativePlaybackPosition && max(0, clock().timeIntervalSince(lastSyncTime)) <= 5
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
        hasLyrics: Bool,
        hasAuthoritativePlaybackPosition: Bool
    ) -> Bool {
        // 同步歌词 + 已知播放进度：本地 0.05s 推进。
        //
        // hasAuthoritativePlaybackPosition 是必要条件，不能放宽：timer 用
        // syncedElapsedTime + (now - lastSyncTime) * rate 外推，没有权威位置时
        // 基准是陈旧的，误差只会单调累积而永远得不到校准，表现为歌词行乱跳、
        // 进度条乱走，同时 20Hz timer 持续空转耗电。
        //
        // 一次取值失败不清空已有位置；调用方会检查采样新鲜度，限制外推时间。
        return isPlaying && lyricsEnabled && hasLyrics && hasAuthoritativePlaybackPosition
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
    private var artworkTask: Task<Void, Never>?
    private var artworkRequestID = 0
    private var nextArtworkRetry = Date.distantPast
    private static let infoFetchTimeoutNanoseconds: UInt64 = 5_000_000_000

    func fetchNowPlayingInfo() {
        Task { [weak self] in await self?.refreshNowPlayingInfo() }
    }

    /// 与定时器、播放通知共享的可等待入口，便于复现完整取值链路。
    func refreshNowPlayingInfo() async {
        guard let requestID = infoFetchGate.begin() else { return }
        let timeout = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: Self.infoFetchTimeoutNanoseconds) }
            catch { return }
            self?.infoFetchGate.timeout(requestID: requestID)
        }
        let info = await infoProvider()
        timeout.cancel()
        guard infoFetchGate.finish(requestID: requestID) else { return }
        applyNowPlayingInfo(info)
    }

    private func applyNowPlayingInfo(_ info: [String: Any]) {
        // 临时超时不是“播放器已关闭”，保留最后一次可靠内容，等下次轮询校准。
        if info["fetchFailed"] as? Bool == true {
            if !defaults.bool(forKey: "showLyrics") {
                lyricsManager.reset()
                currentLyricLine = ""
                lastLyricsEnabled = false
            }
            refreshLyricLine()
            startProgressTimerIfNeeded()
            return
        }
        if info.isEmpty {
            isPlaying = false
            playbackRate = 0
        }
        let newTitle = info["title"] as? String ?? ""
        let newArtist = info["artist"] as? String ?? ""
        let newAlbum = info["album"] as? String ?? ""
        let newSource = ScriptingBridgeHelper.supportedApp(from: info)
        let trackChanged = newSource != currentSource || Self.hasTrackIdentityChanged(
            title: newTitle,
            artist: newArtist,
            album: newAlbum,
            previousTitle: self.currentTitle,
            previousArtist: self.currentArtist,
            previousAlbum: self.currentAlbum
        )
        if trackChanged {
            artworkRequestID += 1
            artworkTask?.cancel()
            artworkTask = nil
            nextArtworkRetry = .distantPast
            currentArtworkData = nil
            self.currentLyricLine = ""
            self.hasAuthoritativePlaybackPosition = false
            self.syncedElapsedTime = 0
            self.elapsedTime = 0
            self.duration = 0
            // 同步基准也要归零：否则 timer 会用上一首歌残留的 lastSyncTime
            // 外推，新歌开头就得到一个凭空累积出来的巨大 elapsedTime
            self.lastSyncTime = self.clock()
        }
        self.currentTitle = newTitle
        self.currentArtist = newArtist
        self.currentAlbum = newAlbum
        self.currentSource = newSource

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
            self.refreshArtworkPalette()
        }

        if let dur = info["duration"] as? TimeInterval, dur.isFinite, dur >= 0 {
            self.duration = dur
        }
        // 先更新播放速率，位置补偿计算依赖最新速率
        if let rate = info["playbackRate"] as? Double, rate.isFinite, rate >= 0 {
            self.playbackRate = rate
            // 用户手动操作后的保护期内，不覆盖状态
            if self.clock() > self.userActionDeadline {
                self.isPlaying = rate > 0
            }
        }
        // 用 playerPosition 校准播放位置（每秒同步一次，防止本地计时漂移）
        // lastSyncTime 取采样时刻，补偿调度和等待另一播放器的时间。
        if let pos = info["playerPosition"] as? TimeInterval, pos.isFinite, pos >= 0 {
            let sampledAt = info["positionTimestamp"] as? Date ?? self.clock()
            self.hasAuthoritativePlaybackPosition = true
            self.syncedElapsedTime = pos
            self.lastSyncTime = sampledAt
            self.elapsedTime = Self.compensatedElapsedTime(
                position: pos,
                sampledAt: sampledAt,
                now: self.clock(),
                playbackRate: self.playbackRate
            )
        }

        // 切歌或歌词开关变化时同步歌词状态
        let lyricsEnabled = self.defaults.bool(forKey: "showLyrics")
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
        ) || (isPlaying && lyricsManager.shouldRetryCurrentTrack) {
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
        // 注意：没有权威播放位置时不要清空 currentLyricLine。
        // AppleScript 取 player position 偶发失败/超时会导致一次返回空，
        // 一旦清空就会让 ticker 闪烁回标题再恢复下一帧 —— 视觉上"歌词不显示"。
        // 保留上一行内容，等下一次成功采样再校准。
        if self.hasAuthoritativePlaybackPosition {
            self.lyricsManager.updateCurrentLine(elapsedTime: self.elapsedTime)
            if self.lyricsManager.currentLine != self.currentLyricLine {
                self.currentLyricLine = self.lyricsManager.currentLine
            }
        }

        // 根据当前状态决定是否需要 progressTimer
        self.startProgressTimerIfNeeded()
        requestArtworkIfNeeded(for: info)
    }

    func fetchPlaybackState() {
        fetchNowPlayingInfo()
    }

    private func requestArtworkIfNeeded(for info: [String: Any]) {
        guard currentSource == .music, isPlaying, !currentTitle.isEmpty,
              currentArtworkData == nil, artworkTask == nil, clock() >= nextArtworkRetry else { return }
        artworkRequestID += 1
        let requestID = artworkRequestID
        let provider = artworkProvider
        artworkTask = Task { [weak self] in
            let data = await provider(info)
            guard !Task.isCancelled, let self, self.artworkRequestID == requestID else { return }
            self.artworkTask = nil
            if let data, !data.isEmpty {
                self.currentArtworkData = data
                self.artworkVersion += 1
                self.refreshArtworkPalette()
            } else {
                self.nextArtworkRetry = self.clock().addingTimeInterval(30)
            }
        }
    }

    // MARK: - 封面取色

    /// 按当前封面重新提取强调色。
    ///
    /// 取色要解码图像并跑一遍 CoreImage，放在 1s 轮询路径上会周期性卡顿，
    /// 因此丢到后台任务里算，只把结果带回主线程。请求号保证旧封面的
    /// 迟到结果不会覆盖新封面。
    private func refreshArtworkPalette() {
        paletteRequestID += 1
        let requestID = paletteRequestID
        paletteTask?.cancel()
        paletteTask = nil

        guard let data = currentArtworkData, !data.isEmpty else {
            artworkPalette = nil
            return
        }

        paletteTask = Task { [weak self] in
            let palette = await Task.detached(priority: .utility) { () -> AlbumArtworkPalette? in
                guard let image = NSImage(data: data) else { return nil }
                return AlbumArtworkColorExtractor.palette(from: image)
            }.value
            guard !Task.isCancelled, let self, self.paletteRequestID == requestID else { return }
            self.paletteTask = nil
            self.artworkPalette = palette
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
