import SwiftUI
import MediaPlayer

/// 媒体播放管理器
@MainActor
final class MediaManager: ObservableObject {
    // MARK: - Published Properties

    @Published var isPlaying = false
    @Published var currentTitle: String = ""
    @Published var currentArtist: String = ""
    @Published var currentArtwork: NSImage?
    @Published var volume: Float = 0.5

    // MARK: - Private Properties

    private var nowPlayingInfo: [String: Any]?

    // MARK: - Init

    init() {
        setupRemoteCommandCenter()
        startListeningForNowPlayingNotifications()
    }

    // MARK: - Setup

    private func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.isPlaying = true
            return .success
        }

        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.isPlaying = false
            return .success
        }

        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.isPlaying.toggle()
            return .success
        }

        commandCenter.nextTrackCommand.addTarget { _ in
            // TODO: 实现下一曲
            return .success
        }

        commandCenter.previousTrackCommand.addTarget { _ in
            // TODO: 实现上一曲
            return .success
        }
    }

    private func startListeningForNowPlayingNotifications() {
        // 注意：MPMusicPlayerControllerNowPlayingItemDidChange 在 macOS 上不可用
        // 需要使用 MediaRemote 私有框架（App Store 有限制）
        // 这里使用定时轮询作为备选方案
    }

    // MARK: - Public Methods

    func play() {
        isPlaying = true
        // TODO: 发送播放命令
    }

    func pause() {
        isPlaying = false
        // TODO: 发送暂停命令
    }

    func nextTrack() {
        // TODO: 实现
    }

    func previousTrack() {
        // TODO: 实现
    }

    func setVolume(_ volume: Float) {
        self.volume = volume
        // TODO: 设置系统音量
    }

    // MARK: - Private Methods

    private func updateNowPlayingInfo() {
        // TODO: 从 MediaRemote 获取当前播放信息
        // 这需要使用私有 API，App Store 版本有限制
    }
}
