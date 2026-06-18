import Foundation

/// MediaRemote 私有框架动态桥接（dlopen/dlsym）
/// 用于非 App Store 分发，获取系统级播放器的 Now Playing 信息
enum MediaRemoteBridge {
    private static let handle = dlopen(
        "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
        RTLD_NOW
    )

    // MARK: - Function Pointer Types

    private typealias MRMediaRemoteGetNowPlayingInfoFunction =
        @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void

    private typealias MRMediaRemoteSendCommandFunction =
        @convention(c) (UInt32, [String: Any]?) -> Bool

    private typealias MRMediaRemoteRegisterFunction =
        @convention(c) (DispatchQueue) -> Void

    private typealias MRMediaRemoteUnregisterFunction =
        @convention(c) () -> Void

    // MARK: - Resolved Function Pointers

    private static let _getNowPlayingInfo: MRMediaRemoteGetNowPlayingInfoFunction? = {
        guard let sym = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") else { return nil }
        return unsafeBitCast(sym, to: MRMediaRemoteGetNowPlayingInfoFunction.self)
    }()

    private static let _sendCommand: MRMediaRemoteSendCommandFunction? = {
        guard let sym = dlsym(handle, "MRMediaRemoteSendCommand") else { return nil }
        return unsafeBitCast(sym, to: MRMediaRemoteSendCommandFunction.self)
    }()

    private static let _register: MRMediaRemoteRegisterFunction? = {
        guard let sym = dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications") else { return nil }
        return unsafeBitCast(sym, to: MRMediaRemoteRegisterFunction.self)
    }()

    private static let _unregister: MRMediaRemoteUnregisterFunction? = {
        guard let sym = dlsym(handle, "MRMediaRemoteUnregisterForNowPlayingNotifications") else { return nil }
        return unsafeBitCast(sym, to: MRMediaRemoteUnregisterFunction.self)
    }()

    // MARK: - Public API

    /// 获取当前播放信息
    static func getNowPlayingInfo(completion: @escaping ([String: Any]) -> Void) {
        if let fn = _getNowPlayingInfo {
            fn(DispatchQueue.main, completion)
        } else {
            completion([:])
        }
    }

    /// 发送播放控制命令
    @discardableResult
    static func sendCommand(_ command: MediaRemoteCommand, options: [String: Any]? = nil) -> Bool {
        _sendCommand?(command.rawValue, options) ?? false
    }

    /// 注册播放变更通知
    static func registerForNotifications() {
        _register?(DispatchQueue.main)
    }

    /// 取消注册
    static func unregisterForNotifications() {
        _unregister?()
    }

    /// 检查 MediaRemote 是否可用
    static var isAvailable: Bool {
        handle != nil && _getNowPlayingInfo != nil && _sendCommand != nil
    }

    // MARK: - 通知名称

    static let nowPlayingInfoDidChange = "kMRMediaRemoteNowPlayingInfoDidChangeNotification" as CFString
    static let nowPlayingApplicationIsPlayingDidChange = "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification" as CFString

    // MARK: - Now Playing Info Keys

    enum InfoKey {
        static let title = kMRMediaRemoteNowPlayingInfoTitle as String
        static let artist = kMRMediaRemoteNowPlayingInfoArtist as String
        static let album = kMRMediaRemoteNowPlayingInfoAlbum as String
        static let artworkData = kMRMediaRemoteNowPlayingInfoArtworkData as String
        static let duration = kMRMediaRemoteNowPlayingInfoDuration as String
        static let elapsedTime = kMRMediaRemoteNowPlayingInfoElapsedTime as String
        static let playbackRate = kMRMediaRemoteNowPlayingInfoPlaybackRate as String
    }
}

// MARK: - MediaRemote Command Constants

enum MediaRemoteCommand: UInt32 {
    case play = 0
    case pause = 1
    case togglePlayPause = 2
    case stop = 3
    case nextTrack = 4
    case previousTrack = 5
    case toggleRecord = 8
    case seekForward = 10
    case seekBackward = 11
}

// MARK: - MediaRemote Key Constants (私有 API 字符串常量)

private let kMRMediaRemoteNowPlayingInfoTitle = "kMRMediaRemoteNowPlayingInfoTitle"
private let kMRMediaRemoteNowPlayingInfoArtist = "kMRMediaRemoteNowPlayingInfoArtist"
private let kMRMediaRemoteNowPlayingInfoAlbum = "kMRMediaRemoteNowPlayingInfoAlbum"
private let kMRMediaRemoteNowPlayingInfoArtworkData = "kMRMediaRemoteNowPlayingInfoArtworkData"
private let kMRMediaRemoteNowPlayingInfoDuration = "kMRMediaRemoteNowPlayingInfoDuration"
private let kMRMediaRemoteNowPlayingInfoElapsedTime = "kMRMediaRemoteNowPlayingInfoElapsedTime"
private let kMRMediaRemoteNowPlayingInfoPlaybackRate = "kMRMediaRemoteNowPlayingInfoPlaybackRate"
