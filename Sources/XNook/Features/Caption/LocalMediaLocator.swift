import AppKit
import Foundation

/// 正在播放的本地媒体。
struct LocalMediaPlayback: Equatable {
    let fileURL: URL
    /// 播放器自报的当前位置（媒体时间，秒）。
    let position: TimeInterval
    let isPlaying: Bool
}

/// 找出「此刻正在播放哪个本地文件、播到哪」。
///
/// 只做本地文件：这些音频在磁盘上，播放前沿之后的样本可以直接读，
/// 才谈得上预转写。浏览器里的流媒体缓冲在对方进程内，没有接口可取。
@MainActor
protocol LocalMediaLocator: AnyObject {
    var identifier: String { get }
    /// 取不到（没在播、没有权限、播放器不支持）时返回 nil。
    ///
    /// 异步是必须的：底层要发 AppleEvent，首次调用可能弹出系统授权框并一直等，
    /// 播放器无响应时更会阻塞数十秒。这条链路的调用方在主线程上跑调度器，不能被它拖住。
    func currentPlayback() async -> LocalMediaPlayback?
}

/// QuickTime Player 适配器。
///
/// 走 AppleScript 取文档路径与 `current time`：这是唯一稳定的公开接口。
/// 三条纪律：
/// 1. 播放器没在运行时**绝不发脚本**——`tell application` 会把 QuickTime 拉起来；
/// 2. 拿到 -1743（未授权自动化）后永久停用本适配器，不反复弹系统授权框；
/// 3. 脚本只在专用串行队列上执行，且自带超时——首次调用可能弹出授权框并一直等，
///    不能让它把主线程（字幕调度器所在）一起拖住。
@MainActor
final class QuickTimeMediaLocator: LocalMediaLocator {

    let identifier = "quicktime"

    private static let bundleID = "com.apple.QuickTimePlayerX"
    /// NSAppleScript 实例只能在一个线程上用，串行队列天然满足这一点。
    private static let scriptQueue = DispatchQueue(
        label: "com.meteorkid.xnook.qt-applescript", qos: .utility
    )
    /// 超时看门狗要独立于脚本队列：串行队列在脚本阻塞时排不进新任务。
    private static let watchdogQueue = DispatchQueue(
        label: "com.meteorkid.xnook.qt-watchdog", qos: .utility
    )
    /// 正常往返 < 50 ms；超过这个数基本就是在等授权框，或播放器已经卡住。
    private static let scriptTimeout: TimeInterval = 4

    private var isDisabled = false
    private var reportedFailure = false
    private var consecutiveTimeouts = 0
    private var loggedEnter = false
    private var lastDebug = ""

    var onDiagnostics: ((String) -> Void)?

    /// 成功时返回 `路径\n当前位置\n是否播放中`；取不到时返回以 `diag:` 开头的原因，
    /// 便于在日志里区分「没有文档」「文档没有文件」「取路径报错」。
    static let script = """
    tell application id "com.apple.QuickTimePlayerX"
        if (count of documents) is 0 then return ""
        set d to missing value
        repeat with doc in documents
            try
                if playing of doc is true then
                    set d to doc
                    exit repeat
                end if
            end try
        end repeat
        if d is missing value then set d to document 1
        set p to ""
        try
            set f to file of d
            set p to POSIX path of f
        on error msg number num
            return "diag: nofile code=" & num
        end try
        if p is "" then return ""
        return p & "\\n" & ((current time of d) as string) & "\\n" & ((playing of d) as string)
    end tell
    """

    private func debug(_ message: String) {
        guard lastDebug != message else { return }
        lastDebug = message
        onDiagnostics?("pretranscript: qt \(message)")
    }

    func currentPlayback() async -> LocalMediaPlayback? {
        if !loggedEnter {
            loggedEnter = true
            debug("probe enter disabled=\(isDisabled)")
        }
        guard !isDisabled else { return nil }
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty else {
            debug("probe skip: QuickTime 未运行")
            return nil
        }

        switch await Self.runScript() {
        case .timedOut:
            consecutiveTimeouts += 1
            if consecutiveTimeouts >= 3 {
                // 三次都拿不到回应，说明播放器卡死或授权框一直挂着。
                // 继续每 1.5 秒发一次只会堆积阻塞线程，直接停用。
                isDisabled = true
                onDiagnostics?("pretranscript: QuickTime 连续 \(consecutiveTimeouts) 次无响应，已停用本地预转写")
            } else {
                debug("probe timeout #\(consecutiveTimeouts)")
            }
            return nil

        case .failed(let code):
            if code == -1743 || code == -1744 {
                // 用户没给「控制 QuickTime」的权限；不再重试，也不再弹框。
                isDisabled = true
                if !reportedFailure {
                    reportedFailure = true
                    onDiagnostics?("pretranscript: 未获得控制 QuickTime 的自动化权限，已停用本地预转写")
                }
            } else {
                debug("probe error code=\(code)")
            }
            return nil

        case .succeeded(let rawValue):
            consecutiveTimeouts = 0
            if rawValue.hasPrefix("diag:") {
                debug("probe \(rawValue)")
                return nil
            }
            debug("probe raw=\(rawValue.debugDescription)")
            return Self.parse(rawValue)
        }
    }

    // MARK: - 脚本执行

    private static func runScript() async -> ScriptOutcome {
        let source = script
        let box = OutcomeBox()
        return await withCheckedContinuation { continuation in
            scriptQueue.async {
                let appleScript = NSAppleScript(source: source)
                var error: NSDictionary?
                let descriptor = appleScript?.executeAndReturnError(&error)
                if let error {
                    let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
                    box.finish(.failed(code), continuation)
                } else {
                    box.finish(.succeeded(descriptor?.stringValue ?? ""), continuation)
                }
            }
            watchdogQueue.asyncAfter(deadline: .now() + scriptTimeout) {
                box.finish(.timedOut, continuation)
            }
        }
    }

    private static func parse(_ rawValue: String) -> LocalMediaPlayback? {
        guard !rawValue.isEmpty else { return nil }
        // 正常只会是 \n，但 AppleScript 在不同本地化下可能给 \r。
        let normalized = rawValue
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let parts = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return nil }
        let path = String(parts[0])
        guard !path.isEmpty else { return nil }
        let position = TimeInterval(String(parts[1]).trimmingCharacters(in: .whitespaces)) ?? 0
        let playing = String(parts[2]).trimmingCharacters(in: .whitespaces).lowercased() == "true"
        return LocalMediaPlayback(
            fileURL: URL(fileURLWithPath: path),
            position: max(0, position),
            isPlaying: playing
        )
    }
}

private enum ScriptOutcome {
    case succeeded(String)
    case failed(Int)
    case timedOut
}

/// 保证「脚本返回」与「超时」之间只有一个结果被采用：contination 恢复两次会崩溃。
private final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    func finish(
        _ outcome: ScriptOutcome,
        _ continuation: CheckedContinuation<ScriptOutcome, Never>
    ) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        lock.unlock()
        continuation.resume(returning: outcome)
    }
}
