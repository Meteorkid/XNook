import Foundation

struct MediaTrackIdentity: Equatable, Sendable {
    let source: ScriptingBridgeHelper.SupportedApp
    let id: String
    let title: String
    let artist: String
    let album: String

    init?(info: [String: Any]) {
        guard let source = ScriptingBridgeHelper.supportedApp(from: info),
              let id = info["trackID"] as? String, !id.isEmpty,
              let title = info["title"] as? String, !title.isEmpty else { return nil }
        self.source = source
        self.id = id
        self.title = title
        artist = info["artist"] as? String ?? ""
        album = info["album"] as? String ?? ""
    }
}

struct MediaSeekArguments: Sendable {
    let seconds: TimeInterval
    let identity: MediaTrackIdentity
}

struct MediaSeekContext: Equatable {
    let identity: MediaTrackIdentity
    let generation: Int
    let duration: TimeInterval
}

enum MediaSeekFailure: Equatable {
    case unavailable, trackChanged, commandFailed, unconfirmed
}

enum MediaSeekStatus: Equatable {
    case idle
    case pending(TimeInterval)
    case failed(MediaSeekFailure)

    var isPending: Bool {
        if case .pending = self { return true }
        return false
    }
}

struct MediaSeekConfirmation {
    let identity: MediaTrackIdentity
    let position: TimeInterval
    let duration: TimeInterval
    let rate: Double
    let sampledAt: Date
    let writeFinishedAt: Date

    init?(info: [String: Any], writeFinishedAt: Date? = nil) {
        guard let identity = MediaTrackIdentity(info: info),
              let position = info["playerPosition"] as? Double, position.isFinite, position >= 0,
              let duration = info["duration"] as? Double, duration.isFinite, duration > 0, duration < Double(Int.max),
              let rate = info["playbackRate"] as? Double, rate == 0 || rate == 1,
              let sampledAt = info["positionTimestamp"] as? Date,
              sampledAt.timeIntervalSinceReferenceDate.isFinite else { return nil }
        self.identity = identity
        self.position = position
        self.duration = duration
        self.rate = rate
        self.sampledAt = sampledAt
        self.writeFinishedAt = writeFinishedAt ?? sampledAt
    }

    func confirms(_ target: TimeInterval, since writeFinishedAt: Date) -> Bool {
        guard sampledAt >= writeFinishedAt else { return false }
        let expected = min(duration, target + sampledAt.timeIntervalSince(writeFinishedAt) * rate)
        return abs(position - expected) <= 1
    }
}

enum MediaSeekResult {
    case confirmed(MediaSeekConfirmation)
    case failed(MediaSeekFailure)
}

/// 与 Slider 共用的编辑状态；预览从不写入播放器或歌词时钟。
struct MediaSeekInteraction {
    private(set) var context: MediaSeekContext?
    private(set) var previewTime: TimeInterval?
    private(set) var isEditing = false

    mutating func begin(context: MediaSeekContext?, elapsedTime: TimeInterval) {
        cancel()
        isEditing = true
        guard let context, elapsedTime.isFinite else { return }
        self.context = context
        previewTime = min(context.duration, max(0, elapsedTime))
    }

    mutating func update(to seconds: TimeInterval, currentContext: MediaSeekContext?) {
        guard let context, context == currentContext, seconds.isFinite else { invalidate(); return }
        previewTime = min(context.duration, max(0, seconds))
    }

    mutating func finish(currentContext: MediaSeekContext?) -> (seconds: TimeInterval, context: MediaSeekContext)? {
        defer { cancel() }
        guard let context, context == currentContext, let previewTime else { return nil }
        return (previewTime, context)
    }

    mutating func cancel() {
        isEditing = false
        invalidate()
    }

    /// 保留当前手势已开始的标记，切歌后的后续拖动不能自动绑定到新曲目。
    mutating func invalidate() {
        context = nil
        previewTime = nil
    }
}
