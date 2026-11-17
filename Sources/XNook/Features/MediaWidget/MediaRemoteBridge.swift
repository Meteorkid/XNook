import AppKit
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

    private typealias MRMediaRemoteGetApplicationPIDFunction =
        @convention(c) (DispatchQueue, @escaping (Int32) -> Void) -> Void

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

    private static let _getApplicationPID: MRMediaRemoteGetApplicationPIDFunction? = {
        guard let sym = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationPID") else { return nil }
        return unsafeBitCast(sym, to: MRMediaRemoteGetApplicationPIDFunction.self)
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

    /// 当前 Now Playing 应用的进程号。0 表示没有播放器在发布播放信息。
    static func getNowPlayingApplicationPID(completion: @escaping (Int32) -> Void) {
        if let fn = _getApplicationPID {
            fn(DispatchQueue.main, completion)
        } else {
            completion(0)
        }
    }

    /// 系统级播放快照：任意接入 Now Playing 的播放器（音乐、视频、浏览器）都适用。
    ///
    /// 优先走 Perl 桥接：ad-hoc 签名的 app 直接调 MediaRemote 读接口会被系统返回空，
    /// 而 Apple 平台签名的 /usr/bin/perl 能读到完整信息。桥接的 get 命令在单次回调中
    /// 同时取得元数据、PID 和播放态，天然避免了原先两次 IPC 之间的竞态。
    /// 桥接不可用时（如开发态未打包 dylib）回退到进程内直连 + 前后 PID 校验。
    static func snapshot(now: Date = Date()) async -> [String: Any] {
        if PerlMediaRemote.isAvailable, let track = await PerlMediaRemote.get() {
            return normalizePerl(track, now: now)
        }
        guard isAvailable else { return [:] }
        let pidBefore = await fetchApplicationPID()
        let rawInfo = await fetchNowPlayingInfo()
        let pidAfter = await fetchApplicationPID()
        return resolveSnapshot(rawInfo, pidBefore: pidBefore, pidAfter: pidAfter, now: now)
    }

    /// 把 Perl 桥接快照归一化为内部字段格式（与 normalize 对齐）。
    static func normalizePerl(_ track: PerlTrackPayload, now: Date = Date()) -> [String: Any] {
        var info: [String: Any] = [
            "title": track.title ?? "",
            "artist": track.artist ?? "",
            "album": track.album ?? "",
            "sourceKind": "mediaRemote",
        ]
        if let artwork = track.artworkData, !artwork.isEmpty {
            info["artworkData"] = artwork
        }
        if let duration = track.durationMicros, duration >= 0 {
            info["duration"] = duration / 1_000_000
        }
        if let rate = track.playbackRate, rate >= 0 {
            info["playbackRate"] = rate
        }
        if let position = track.elapsedTime(at: now) {
            info["playerPosition"] = position
            info["positionTimestamp"] = now
        }
        if let bundleID = track.bundleIdentifier, !bundleID.isEmpty {
            info["sourceBundleID"] = bundleID
        }
        if let name = track.applicationName, !name.isEmpty {
            info["sourceName"] = name
        }
        // 脚本增强只识别 Music / Spotify；其他来源（含 B 站）靠桥接的精确位置即可。
        return info
    }

    /// 私有框架回调偶尔不到达时，1s 后无条件兜底，避免轮询任务永久挂起。
    private static func fetchNowPlayingInfo() async -> [String: Any] {
        await withCheckedContinuation { continuation in
            let lock = NSLock()
            var finished = false
            let finish: ([String: Any]) -> Void = { value in
                lock.lock()
                guard !finished else { lock.unlock(); return }
                finished = true
                lock.unlock()
                continuation.resume(returning: value)
            }
            getNowPlayingInfo { finish($0) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { finish([:]) }
        }
    }

    private static func fetchApplicationPID() async -> Int32 {
        await withCheckedContinuation { continuation in
            let lock = NSLock()
            var finished = false
            let finish: (Int32) -> Void = { value in
                lock.lock()
                guard !finished else { lock.unlock(); return }
                finished = true
                lock.unlock()
                continuation.resume(returning: value)
            }
            getNowPlayingApplicationPID { finish($0) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { finish(0) }
        }
    }

    /// 前后 PID 不一致说明取元数据的瞬间播放器发生切换，这一帧的来源不可信。
    /// 返回 fetchFailed 让上层保留最后一次可靠内容，等下一轮轮询校准。
    static func resolveSnapshot(
        _ raw: [String: Any],
        pidBefore: Int32,
        pidAfter: Int32,
        now: Date = Date()
    ) -> [String: Any] {
        guard pidBefore == pidAfter else { return ["fetchFailed": true] }
        return normalize(raw, pid: pidAfter, now: now)
    }

    /// 把 MediaRemote 的私有键名转换成项目内部统一的字段。
    /// 标题为空视为没有播放内容；其余字段缺失时保持键不存在，交给上层保留旧值。
    static func normalize(_ raw: [String: Any], pid: Int32, now: Date = Date()) -> [String: Any] {
        guard let title = raw[InfoKey.title] as? String, !title.isEmpty else { return [:] }

        var info: [String: Any] = [
            "title": title,
            "artist": raw[InfoKey.artist] as? String ?? "",
            "album": raw[InfoKey.album] as? String ?? "",
            "sourceKind": "mediaRemote",
        ]

        if let artwork = raw[InfoKey.artworkData] as? Data, !artwork.isEmpty {
            info["artworkData"] = artwork
        } else if let artwork = raw[InfoKey.artworkData] as? NSData, artwork.length > 0 {
            info["artworkData"] = Data(referencing: artwork)
        }
        if let duration = nonNegativeNumber(raw[InfoKey.duration]) {
            info["duration"] = duration
        }
        if let rate = nonNegativeNumber(raw[InfoKey.playbackRate]) {
            info["playbackRate"] = rate
        }
        if let position = nonNegativeNumber(raw[InfoKey.elapsedTime]) {
            info["playerPosition"] = position
            info["positionTimestamp"] = now
        }
        if pid > 0, let app = NSRunningApplication(processIdentifier: pid) {
            info["sourceBundleID"] = app.bundleIdentifier ?? ""
            info["sourceName"] = app.localizedName ?? ""
        }
        return info
    }

    private static func nonNegativeNumber(_ value: Any?) -> Double? {
        let number: Double?
        if let value = value as? NSNumber {
            number = value.doubleValue
        } else {
            number = value as? Double
        }
        guard let number, number.isFinite, number >= 0 else { return nil }
        return number
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
