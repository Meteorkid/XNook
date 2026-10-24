import SwiftUI
import AppKit
import CoreAudio
import Observation

private final class MediaManagerCleanup: @unchecked Sendable {
    private let lock = NSLock()
    private var infoObserver: NSObjectProtocol?
    private var playingObserver: NSObjectProtocol?
    private var preferencesObserver: NSObjectProtocol?
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

    func storePreferencesObserver(_ observer: NSObjectProtocol?) {
        lock.lock()
        preferencesObserver = observer
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
        let preferencesObserver = preferencesObserver
        let infoTimer = infoTimer
        let progressTimer = progressTimer
        self.infoObserver = nil
        self.playingObserver = nil
        self.preferencesObserver = nil
        self.infoTimer = nil
        self.progressTimer = nil
        lock.unlock()

        infoTimer?.invalidate()
        progressTimer?.invalidate()
        if let infoObserver { NotificationCenter.default.removeObserver(infoObserver) }
        if let playingObserver { NotificationCenter.default.removeObserver(playingObserver) }
        if let preferencesObserver { NotificationCenter.default.removeObserver(preferencesObserver) }
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

    mutating func invalidate() {
        currentRequestID &+= 1
        isInFlight = false
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
    private(set) var currentTrackIdentity: MediaTrackIdentity?
    private(set) var seekStatus: MediaSeekStatus = .idle
    private var playbackGeneration = 0
    @ObservationIgnored private var seekTask: Task<Void, Never>?

    var seekContext: MediaSeekContext? {
        guard let currentTrackIdentity, duration.isFinite, duration > 0, duration < Double(Int.max),
              hasAuthoritativePlaybackPosition, !seekStatus.isPending,
              isPlaying ? hasFreshPlaybackPosition : hasTrustedPausedPosition else { return nil }
        return MediaSeekContext(identity: currentTrackIdentity, generation: playbackGeneration, duration: duration)
    }

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
    private let commandSender: (@MainActor (MediaRemoteCommand) -> Void)?
    private let seekProvider: @MainActor (TimeInterval, MediaSeekContext) async -> MediaSeekResult

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
    /// 已确认或在新鲜采样上冻结的暂停位置，不随暂停时长继续外推。
    private var hasTrustedPausedPosition = false
    /// 用户手动操作播放控制后的保护截止时间（防止 ScriptingBridge 延迟覆盖）
    private var userActionDeadline: Date = .distantPast
    /// 本地播放态切换前取得的快照，即使仍在五秒内，也不能重新建立时间锚点。
    private var playbackSampleNotBefore: Date = .distantPast

    // MARK: - Init

    init(
        startMonitoring: Bool = true,
        defaults: UserDefaults = .standard,
        lyricsManager: LyricsManager? = nil,
        infoProvider: @escaping @MainActor () async -> [String: Any] = { await ScriptingBridgeHelper.getNowPlayingInfo() },
        artworkProvider: @escaping @MainActor ([String: Any]) async -> Data? = { await ScriptingBridgeHelper.getArtwork(for: $0) },
        clock: @escaping () -> Date = Date.init,
        commandSender: (@MainActor (MediaRemoteCommand) -> Void)? = nil,
        seekProvider: @escaping @MainActor (TimeInterval, MediaSeekContext) async -> MediaSeekResult = {
            await ScriptingBridgeHelper.seek(to: $0, context: $1)
        }
    ) {
        self.defaults = defaults
        self.lyricsManager = lyricsManager ?? LyricsManager(defaults: defaults)
        self.infoProvider = infoProvider
        self.artworkProvider = artworkProvider
        self.clock = clock
        self.commandSender = commandSender
        self.seekProvider = seekProvider
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
        cleanup.storePreferencesObserver(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshLyricsPreferences() }
        })
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
        seekTask?.cancel()
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
        if !lyricsManager.hasLyrics { currentLyricLine = "" }
        guard hasAuthoritativePlaybackPosition else { return }
        guard isPlaying ? hasFreshPlaybackPosition : hasTrustedPausedPosition else {
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

    private func freezePlaybackPosition() {
        guard isPlaying else { return }
        hasTrustedPausedPosition = hasFreshPlaybackPosition
        if hasTrustedPausedPosition { refreshLyricLine() }
    }

    private func refreshLyricsPreferences() {
        lyricsManager.refreshPreferences()
        let enabled = defaults.bool(forKey: "showLyrics")
        if enabled != lastLyricsEnabled {
            lastLyricsEnabled = enabled
            if enabled, !currentTitle.isEmpty {
                lyricsManager.fetchLyrics(title: currentTitle, artist: currentArtist,
                                          album: currentAlbum, duration: duration > 0 ? duration : nil)
            } else {
                lyricsManager.reset()
            }
        }
        refreshLyricLine()
        startProgressTimerIfNeeded()
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
        let generation = playbackGeneration
        let timeout = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: Self.infoFetchTimeoutNanoseconds) }
            catch { return }
            self?.infoFetchGate.timeout(requestID: requestID)
        }
        let info = await infoProvider()
        timeout.cancel()
        guard infoFetchGate.finish(requestID: requestID), generation == playbackGeneration else { return }
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
        let newIdentity = MediaTrackIdentity(info: info)
        let nativeTrackChanged = currentTrackIdentity != nil && newIdentity != nil
            && currentTrackIdentity?.id != newIdentity?.id
        let trackChanged = nativeTrackChanged || newSource != currentSource || Self.hasTrackIdentityChanged(
            title: newTitle,
            artist: newArtist,
            album: newAlbum,
            previousTitle: self.currentTitle,
            previousArtist: self.currentArtist,
            previousAlbum: self.currentAlbum
        )
        if trackChanged {
            cancelSeek()
            artworkRequestID += 1
            artworkTask?.cancel()
            artworkTask = nil
            nextArtworkRetry = .distantPast
            currentArtworkData = nil
            self.currentLyricLine = ""
            self.hasAuthoritativePlaybackPosition = false
            self.hasTrustedPausedPosition = false
            self.userActionDeadline = .distantPast
            self.playbackSampleNotBefore = .distantPast
            self.syncedElapsedTime = 0
            self.elapsedTime = 0
            self.duration = 0
            // 同步基准也要归零：否则 timer 会用上一首歌残留的 lastSyncTime
            // 外推，新歌开头就得到一个凭空累积出来的巨大 elapsedTime
            self.lastSyncTime = self.clock()
        } else if seekStatus.isPending, newIdentity != currentTrackIdentity {
            cancelSeek()
            seekStatus = .failed(.unconfirmed)
        }
        self.currentTitle = newTitle
        self.currentArtist = newArtist
        self.currentAlbum = newAlbum
        self.currentSource = newSource
        self.currentTrackIdentity = newIdentity

        // 定位期间同曲目的普通轮询不能抢先覆盖时间轴；切歌已在上方取消定位。
        if seekStatus.isPending { return }

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
        let sampledAt = info["positionTimestamp"] as? Date ?? self.clock()
        let sampledAfterAction = sampledAt >= self.playbackSampleNotBefore
        // 先更新播放速率，位置补偿计算依赖最新速率。
        if sampledAfterAction, let rate = info["playbackRate"] as? Double, rate.isFinite, rate >= 0 {
            // 用户手动操作后的保护期内，不覆盖状态
            if self.clock() > self.userActionDeadline {
                if self.isPlaying && rate == 0 {
                    self.freezePlaybackPosition()
                } else if !self.isPlaying && rate > 0 {
                    self.hasAuthoritativePlaybackPosition = false
                    self.hasTrustedPausedPosition = false
                }
                self.isPlaying = rate > 0
            }
            self.playbackRate = rate
        }
        // 用 playerPosition 校准播放位置（每秒同步一次，防止本地计时漂移）
        // lastSyncTime 取采样时刻，补偿调度和等待另一播放器的时间。
        if let pos = info["playerPosition"] as? TimeInterval, pos.isFinite, pos >= 0 {
            let isFresh = max(0, self.clock().timeIntervalSince(sampledAt)) <= 5
            // 暂停命令保护期内的旧“播放中”快照，不能把冻结位置向前推。
            if sampledAfterAction && isFresh && (self.isPlaying || self.playbackRate == 0) {
                self.hasAuthoritativePlaybackPosition = true
                self.syncedElapsedTime = pos
                self.lastSyncTime = sampledAt
                self.elapsedTime = Self.compensatedElapsedTime(
                    position: pos, sampledAt: sampledAt, now: self.clock(),
                    playbackRate: self.isPlaying ? self.playbackRate : 0
                )
                self.hasTrustedPausedPosition = !self.isPlaying
            }
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
        self.refreshLyricLine()

        // 根据当前状态决定是否需要 progressTimer
        self.startProgressTimerIfNeeded()
        requestArtworkIfNeeded(for: info)
    }

    func fetchPlaybackState() {
        fetchNowPlayingInfo()
    }

    private func requestArtworkIfNeeded(for info: [String: Any]) {
        guard currentSource != nil, isPlaying, !currentTitle.isEmpty,
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

    /// 停止的是待处理交互与回读；已经送达播放器的 AppleEvent 无法撤销。
    func cancelSeek() {
        playbackGeneration &+= 1
        infoFetchGate.invalidate()
        seekTask?.cancel()
        seekTask = nil
        seekStatus = .idle
    }

    @discardableResult
    func seek(to seconds: TimeInterval, context: MediaSeekContext) -> Task<Void, Never>? {
        guard !seekStatus.isPending else { return nil }
        guard seconds.isFinite, seconds >= 0, context == seekContext else {
            seekStatus = .failed(context.identity == currentTrackIdentity ? .unavailable : .trackChanged)
            return nil
        }
        let target = min(seconds, context.duration)
        refreshLyricLine()
        cancelSeek()
        let generation = playbackGeneration
        let startedAt = clock()
        playbackSampleNotBefore = startedAt
        hasAuthoritativePlaybackPosition = false
        hasTrustedPausedPosition = false
        stopProgressTimer()
        seekStatus = .pending(target)
        let provider = seekProvider
        let task = Task { [weak self] in
            let result = await provider(target, context)
            guard !Task.isCancelled, let self, self.playbackGeneration == generation,
                  self.currentTrackIdentity == context.identity else { return }
            self.seekTask = nil
            self.playbackGeneration &+= 1
            self.infoFetchGate.invalidate()
            switch result {
            case .confirmed(let confirmation):
                guard confirmation.identity == context.identity,
                      confirmation.writeFinishedAt >= startedAt,
                      self.clock().timeIntervalSince(confirmation.sampledAt) <= 5,
                      confirmation.sampledAt <= self.clock().addingTimeInterval(1),
                      confirmation.confirms(target, since: confirmation.writeFinishedAt) else {
                    self.seekStatus = .failed(.unconfirmed)
                    return
                }
                self.seekStatus = .idle
                self.playbackSampleNotBefore = confirmation.sampledAt
                // 只接收真实回读位置；不重新取歌词或封面，不向歌词缓存写入预览值。
                self.isPlaying = confirmation.rate > 0
                self.playbackRate = confirmation.rate
                self.duration = confirmation.duration
                self.syncedElapsedTime = confirmation.position
                self.lastSyncTime = confirmation.sampledAt
                self.elapsedTime = min(confirmation.duration, Self.compensatedElapsedTime(
                    position: confirmation.position, sampledAt: confirmation.sampledAt,
                    now: self.clock(), playbackRate: confirmation.rate))
                self.hasAuthoritativePlaybackPosition = true
                self.hasTrustedPausedPosition = !self.isPlaying
                self.userActionDeadline = .distantPast
                self.refreshLyricLine()
                self.startProgressTimerIfNeeded()
            case .failed(let failure):
                self.seekStatus = .failed(failure)
            }
        }
        seekTask = task
        return task
    }

    func play() {
        cancelSeek()
        playbackSampleNotBefore = clock()
        sendPlaybackCommand(.play, fallback: .play)
        if !isPlaying {
            hasAuthoritativePlaybackPosition = false
            hasTrustedPausedPosition = false
        }
        isPlaying = true
        userActionDeadline = clock().addingTimeInterval(2.0) // 2s 保护期
        startProgressTimerIfNeeded()
    }

    func pause() {
        freezePlaybackPosition()
        cancelSeek()
        playbackSampleNotBefore = clock()
        sendPlaybackCommand(.pause, fallback: .pause)
        isPlaying = false
        userActionDeadline = clock().addingTimeInterval(2.0)
        refreshLyricLine()
        startProgressTimerIfNeeded()
    }

    func togglePlayPause() {
        if isPlaying {
            freezePlaybackPosition()
        } else {
            hasAuthoritativePlaybackPosition = false
            hasTrustedPausedPosition = false
        }
        cancelSeek()
        playbackSampleNotBefore = clock()
        if let commandSender { commandSender(.togglePlayPause) }
        else { MediaRemoteBridge.sendCommand(.togglePlayPause) }
        isPlaying.toggle()
        userActionDeadline = clock().addingTimeInterval(2.0)
        refreshLyricLine()
        startProgressTimerIfNeeded()
    }

    func nextTrack() {
        cancelSeek()
        sendPlaybackCommand(.nextTrack, fallback: .nextTrack)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.fetchNowPlayingInfo()
        }
    }

    func previousTrack() {
        cancelSeek()
        sendPlaybackCommand(.previousTrack, fallback: .previousTrack)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.fetchNowPlayingInfo()
        }
    }

    func openCurrentPlayer(
        activate: @MainActor (ScriptingBridgeHelper.SupportedApp) -> Void = { ScriptingBridgeHelper.activate($0) }
    ) {
        // 尚无播放来源时，空态入口仍应能启动系统自带播放器。
        activate(currentSource ?? .music)
    }

    private func sendPlaybackCommand(
        _ command: ScriptingBridgeHelper.PlaybackCommand,
        fallback: MediaRemoteCommand
    ) {
        if let commandSender {
            commandSender(fallback)
            return
        }
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
        // 播放器时间属于外部输入；直接转 Int 会在无效或超界值上触发运行时陷阱。
        guard time.isFinite, time >= 0, time < Double(Int.max) else { return "--:--" }
        let seconds = Int(time)
        return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
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
