import SwiftUI
import AppKit
import CoreAudio

/// 媒体播放管理器 — 通过 MediaRemote 私有框架控制系统级播放器
@MainActor
final class MediaManager: ObservableObject {
    // MARK: - Published Properties

    @Published var isPlaying = false
    @Published var playbackRate: Double = 0
    @Published var currentTitle: String = ""
    @Published var currentArtist: String = ""
    @Published var currentAlbum: String = ""
    @Published var currentLyricLine: String = ""
    /// 仅存储原始 Data，NSImage 按需创建，避免同时持有两份图像数据
    @Published var currentArtworkData: Data?
    /// 封面版本号，每次切歌递增，用于 SwiftUI 强制刷新
    @Published var artworkVersion: Int = 0
    @Published var duration: TimeInterval = 0
    @Published var elapsedTime: TimeInterval = 0
    @Published var isAvailable = false

    /// 按需从 Data 创建 NSImage，避免同时持有两份图像数据
    var currentArtwork: NSImage? {
        guard let data = currentArtworkData, !data.isEmpty else { return nil }
        return NSImage(data: data)
    }

    /// 歌词管理器
    let lyricsManager = LyricsManager()

    // MARK: - Private Properties

    /// 存储 MediaRemote 是否可用（不使用 @Published，避免 deinit 问题）
    private let mediaRemoteAvailable: Bool
    private var infoObserver: NSObjectProtocol?
    private var playingObserver: NSObjectProtocol?
    /// 慢速轮询：获取歌曲信息、封面（1s 间隔，避免 IPC 卡顿）
    private var infoTimer: Timer?
    /// 快速轮询：本地计时更新进度 + 歌词（0.05s 间隔，无 IPC 开销）
    private var progressTimer: Timer?
    /// 上次 ScriptingBridge 同步时的时间戳
    private var lastSyncTime: Date = Date()
    /// 上次同步时的播放位置
    private var syncedElapsedTime: TimeInterval = 0
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
        infoTimer?.invalidate()
        progressTimer?.invalidate()
        if let obs = infoObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = playingObserver { NotificationCenter.default.removeObserver(obs) }
        if mediaRemoteAvailable {
            MediaRemoteBridge.unregisterForNotifications()
        }
    }

    // MARK: - 双定时器架构

    private func startTimers() {
        // 慢速轮询：拉取 ScriptingBridge（歌曲信息 + 封面 + 位置校准）
        // 有播放器时 1s，无播放器时 5s，减少不必要的 IPC 开销
        infoTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.fetchNowPlayingInfo()
            }
        }
        // 快速轮询：0.05s 本地计时，更新歌词（无 IPC 开销）
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let now = Date()
                if self.isPlaying {
                    // 播放中：根据 playbackRate 推算进度
                    let delta = now.timeIntervalSince(self.lastSyncTime) * self.playbackRate
                    self.elapsedTime = self.syncedElapsedTime + delta
                } else {
                    // 暂停中：保持 elapsedTime 在同步点，不推进
                    self.elapsedTime = self.syncedElapsedTime
                }
                // 始终更新歌词当前行
                self.lyricsManager.updateCurrentLine(elapsedTime: self.elapsedTime)
                // 同步到 @Published 属性，触发 SwiftUI 重绘
                self.currentLyricLine = self.lyricsManager.currentLine
            }
        }
    }

    // MARK: - 通知注册

    private func registerNotifications() {
        MediaRemoteBridge.registerForNotifications()

        infoObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name(MediaRemoteBridge.nowPlayingInfoDidChange as String),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.fetchNowPlayingInfo()
            }
        }

        playingObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name(MediaRemoteBridge.nowPlayingApplicationIsPlayingDidChange as String),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.fetchPlaybackState()
            }
        }
    }

    // MARK: - 获取 Now Playing 信息

    private var lastFetchedTitle = ""
    private var lastFetchedArtist = ""
    private var lastLyricsEnabled = false

    static func shouldSyncLyrics(
        title: String,
        artist: String,
        isEnabled: Bool,
        previousTitle: String,
        previousArtist: String,
        wasEnabled: Bool
    ) -> Bool {
        title != previousTitle
            || artist != previousArtist
            || isEnabled != wasEnabled
    }

    func fetchNowPlayingInfo() {
        Task.detached { [weak self] in
            // ScriptingBridge 获取（MediaRemote 在非沙盒环境中返回空）
            let info = await ScriptingBridgeHelper.getNowPlayingInfo()
            guard let self else { return }

            await MainActor.run {
                let newTitle = info["title"] as? String ?? ""
                let newArtist = info["artist"] as? String ?? ""
                let trackChanged = newTitle != self.currentTitle || newArtist != self.currentArtist
                self.currentTitle = newTitle
                self.currentArtist = newArtist
                self.currentAlbum = info["album"] as? String ?? ""

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
                // 用 playerPosition 校准播放位置（每秒同步一次，防止本地计时漂移）
                if let pos = info["playerPosition"] as? TimeInterval {
                    self.syncedElapsedTime = pos
                    self.lastSyncTime = Date()
                    self.elapsedTime = pos
                }
                if let rate = info["playbackRate"] as? Double {
                    self.playbackRate = rate
                    // 用户手动操作后的保护期内，不覆盖状态
                    if Date() > self.userActionDeadline {
                        self.isPlaying = rate > 0
                    }
                }

                // 切歌或歌词开关变化时同步歌词状态
                let lyricsEnabled = UserDefaults.standard.bool(forKey: "showLyrics")
                if Self.shouldSyncLyrics(
                    title: self.currentTitle,
                    artist: self.currentArtist,
                    isEnabled: lyricsEnabled,
                    previousTitle: self.lastFetchedTitle,
                    previousArtist: self.lastFetchedArtist,
                    wasEnabled: self.lastLyricsEnabled
                ) {
                    self.lastFetchedTitle = self.currentTitle
                    self.lastFetchedArtist = self.currentArtist
                    self.lastLyricsEnabled = lyricsEnabled
                    if lyricsEnabled && !self.currentTitle.isEmpty {
                        self.lyricsManager.fetchLyrics(
                            title: self.currentTitle,
                            artist: self.currentArtist,
                            duration: self.duration > 0 ? self.duration : nil
                        )
                    } else {
                        self.lyricsManager.reset()
                    }
                }

                // 更新歌词当前行
                self.lyricsManager.updateCurrentLine(elapsedTime: self.elapsedTime)
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
                    self.syncedElapsedTime = pos
                    self.lastSyncTime = Date()
                    self.elapsedTime = pos
                }
            }
        }
    }

    // MARK: - 播放控制

    func play() {
        MediaRemoteBridge.sendCommand(.play)
        isPlaying = true
        userActionDeadline = Date().addingTimeInterval(2.0) // 2s 保护期
    }

    func pause() {
        MediaRemoteBridge.sendCommand(.pause)
        isPlaying = false
        userActionDeadline = Date().addingTimeInterval(2.0)
    }

    func togglePlayPause() {
        MediaRemoteBridge.sendCommand(.togglePlayPause)
        isPlaying.toggle()
        userActionDeadline = Date().addingTimeInterval(2.0)
    }

    func nextTrack() {
        MediaRemoteBridge.sendCommand(.nextTrack)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.fetchNowPlayingInfo()
        }
    }

    func previousTrack() {
        MediaRemoteBridge.sendCommand(.previousTrack)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.fetchNowPlayingInfo()
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
