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
    @Published var currentArtwork: NSImage?
    @Published var currentArtworkData: Data?
    /// 封面版本号，每次切歌递增，用于 SwiftUI 强制刷新
    @Published var artworkVersion: Int = 0
    @Published var duration: TimeInterval = 0
    @Published var elapsedTime: TimeInterval = 0
    @Published var isAvailable = false

    /// 歌词管理器
    let lyricsManager = LyricsManager()

    // MARK: - Private Properties

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
        isAvailable = MediaRemoteBridge.isAvailable
        guard isAvailable else { return }
        registerNotifications()
        // 立即获取一次
        fetchNowPlayingInfo()
        // 延迟再获取一次
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.fetchNowPlayingInfo()
        }
        startTimers()
    }

    deinit {
        infoTimer?.invalidate()
        progressTimer?.invalidate()
        if let obs = infoObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = playingObserver { NotificationCenter.default.removeObserver(obs) }
        MediaRemoteBridge.unregisterForNotifications()
    }

    // MARK: - 双定时器架构

    private func startTimers() {
        // 慢速轮询：1s 拉取 ScriptingBridge（歌曲信息 + 封面 + 位置校准）
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

    func fetchNowPlayingInfo() {
        // ScriptingBridge 获取（MediaRemote 在非沙盒环境中返回空）
        let info = ScriptingBridgeHelper.getNowPlayingInfo()

        let newTitle = info["title"] as? String ?? ""
        let newArtist = info["artist"] as? String ?? ""
        let trackChanged = newTitle != currentTitle || newArtist != currentArtist
        currentTitle = newTitle
        currentArtist = newArtist
        currentAlbum = info["album"] as? String ?? ""

        // 封面提取 — 有新数据才更新，暂停时保留当前封面
        let oldArtworkData = currentArtworkData
        if let data = info["artworkData"] as? Data, !data.isEmpty {
            currentArtworkData = data
            currentArtwork = NSImage(data: data)
        } else if let data = Self.extractArtwork(from: info) {
            currentArtworkData = nil
            currentArtwork = data
        }
        // 切歌或封面变化时递增版本号，强制 SwiftUI 刷新
        if trackChanged || currentArtworkData != oldArtworkData {
            artworkVersion += 1
        }

        if let dur = info["duration"] as? TimeInterval {
            duration = dur
        }
        // 用 playerPosition 校准播放位置（每秒同步一次，防止本地计时漂移）
        // 用 playerPosition 校准播放位置（每秒同步一次，防止本地计时漂移）
        if let pos = info["playerPosition"] as? TimeInterval {
            syncedElapsedTime = pos
            lastSyncTime = Date()
            elapsedTime = pos
        }
        if let rate = info["playbackRate"] as? Double {
            playbackRate = rate
            // 用户手动操作后的保护期内，不覆盖状态
            if Date() > userActionDeadline {
                isPlaying = rate > 0
            }
        }

        // 切歌时获取歌词
        if currentTitle != lastFetchedTitle || currentArtist != lastFetchedArtist {
            lastFetchedTitle = currentTitle
            lastFetchedArtist = currentArtist
            if !currentTitle.isEmpty {
                lyricsManager.fetchLyrics(title: currentTitle, artist: currentArtist)
            } else {
                lyricsManager.reset()
            }
        }

        // 更新歌词当前行
        lyricsManager.updateCurrentLine(elapsedTime: elapsedTime)
    }

    private func fetchPlaybackState() {
        let info = ScriptingBridgeHelper.getNowPlayingInfo()
        if let rate = info["playbackRate"] as? Double {
            playbackRate = rate
            // 用户手动操作后的保护期内，不覆盖状态
            if Date() > userActionDeadline {
                isPlaying = rate > 0
            }
        }
        // 播放/暂停切换时重新校准进度
        if let pos = info["playerPosition"] as? TimeInterval {
            syncedElapsedTime = pos
            lastSyncTime = Date()
            elapsedTime = pos
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

    /// 从 Now Playing 信息中提取封面图片
    private static func extractArtwork(from info: [String: Any]) -> NSImage? {
        // 尝试常见的封面键名
        let possibleKeys = [
            "artworkData",
            "kMRMediaRemoteNowPlayingInfoArtworkData",
        ]

        for key in possibleKeys {
            if let data = info[key] as? Data, !data.isEmpty {
                if let img = NSImage(data: data) { return img }
            }
            if let nsData = info[key] as? NSData {
                let data = Data(referencing: nsData)
                if let img = NSImage(data: data) { return img }
            }
        }
        return nil
    }
}
