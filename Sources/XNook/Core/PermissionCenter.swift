import AppKit
import CoreGraphics
import EventKit
import Foundation
import Observation
import ServiceManagement
import Speech

/// 单项权限的状态。这里刻意区分「已授权」与「已授权但需要重启」——
/// 屏幕录制就是典型：系统开关已经打开，但当前进程仍拿不到捕获能力。
enum PermissionStatus: Equatable, Sendable {
    case allowed
    case needsRestart
    case denied
    case notRequested
    case writeOnly
    case restricted
    case notInstalled
    case notRunning
    case unknown

    var isSatisfied: Bool { self == .allowed }
    /// 需要用户在系统设置里动手，或需要重启应用。
    var needsAttention: Bool { self != .allowed }

    var title: String {
        switch self {
        case .allowed: L10n.localized(zh: "已授权", en: "Granted")
        case .needsRestart: L10n.localized(zh: "已授权 · 需重启", en: "Granted · restart")
        case .denied: L10n.localized(zh: "未授权", en: "Not granted")
        case .notRequested: L10n.localized(zh: "尚未请求", en: "Not requested")
        case .writeOnly: L10n.localized(zh: "仅写入", en: "Write only")
        case .restricted: L10n.localized(zh: "受系统限制", en: "Restricted")
        case .notInstalled: L10n.localized(zh: "未安装", en: "Not installed")
        case .notRunning: L10n.localized(zh: "未运行", en: "Not running")
        case .unknown: L10n.localized(zh: "待确认", en: "Unknown")
        }
    }
}

enum PermissionKind: String, CaseIterable, Identifiable, Sendable {
    case screenRecording
    case speechRecognition
    case calendar
    case automationMusic
    case automationSpotify
    case loginItems

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenRecording:
            L10n.localized(zh: "屏幕与系统音频录制", en: "Screen & System Audio Recording")
        case .speechRecognition:
            L10n.localized(zh: "语音识别", en: "Speech Recognition")
        case .calendar:
            L10n.localized(zh: "日历", en: "Calendars")
        case .automationMusic:
            L10n.localized(zh: "自动化 · Apple Music", en: "Automation · Apple Music")
        case .automationSpotify:
            L10n.localized(zh: "自动化 · Spotify", en: "Automation · Spotify")
        case .loginItems:
            L10n.localized(zh: "开机启动（登录项）", en: "Launch at Login")
        }
    }

    /// 一句话说清「没有它会怎样」，避免用户对着开关猜。
    var purpose: String {
        switch self {
        case .screenRecording:
            L10n.localized(
                zh: "实时字幕只订阅系统音频、不录画面，用于本机转写。授权后必须重启应用才会生效。",
                en: "Live captions subscribe to system audio only (no video) for on-device transcription. Restart the app after granting."
            )
        case .speechRecognition:
            L10n.localized(
                zh: "把捕获到的音频在本机转成文字，识别过程不联网。",
                en: "Turns captured audio into text on device. Recognition never leaves your Mac."
            )
        case .calendar:
            L10n.localized(
                zh: "读取日程并在灵动岛提醒。需要「完全访问」，仅写入权限读不到日程。",
                en: "Reads events to show reminders. Full access is required; write-only cannot read events."
            )
        case .automationMusic:
            L10n.localized(zh: "向 Apple Music 发送播放、暂停、下一首指令。", en: "Sends play, pause and skip commands to Apple Music.")
        case .automationSpotify:
            L10n.localized(zh: "向 Spotify 发送播放、暂停、下一首指令。", en: "Sends play, pause and skip commands to Spotify.")
        case .loginItems:
            L10n.localized(zh: "登录后在后台启动 X Nook。若系统要求批准，请在「登录项」中允许。", en: "Starts X Nook in the background after login. Approve it in Login Items if macOS asks.")
        }
    }

    var symbol: String {
        switch self {
        case .screenRecording: "rectangle.dashed.badge.record"
        case .speechRecognition: "waveform.badge.mic"
        case .calendar: "calendar"
        case .automationMusic: "music.note"
        case .automationSpotify: "music.note.list"
        case .loginItems: "power"
        }
    }

    var pane: SystemPrivacySettings.Pane {
        switch self {
        case .screenRecording: .screenRecording
        case .speechRecognition: .speechRecognition
        case .calendar: .calendars
        case .automationMusic, .automationSpotify: .automation
        case .loginItems: .loginItems
        }
    }

    /// 系统设置的隐私列表是否接受「把 App 拖进去」。
    /// 日历、语音识别的列表只显示已经申请过的 App，拖进去不会被接受，
    /// 所以这些行不提供拖拽入口，只给准确的文字指引，避免用户白试一次。
    var acceptsDrop: Bool { self == .screenRecording }

    /// `tccutil reset` 用的服务名。
    var tccService: String? {
        switch self {
        case .screenRecording: "ScreenCapture"
        case .speechRecognition: "SpeechRecognition"
        case .calendar: "Calendar"
        case .automationMusic, .automationSpotify: "AppleEvents"
        case .loginItems: nil
        }
    }
}

/// 权限状态中心：所有 TCC 读取集中在这里，界面只消费结论。
///
/// 关键设计：屏幕录制单独记录「启动时的快照」。系统授权后当前进程仍需重启才能捕获，
/// 只报告「未授权」会让用户以为授权失败——这正是「明明授权了却显示未授权」的来源。
@Observable
@MainActor
final class PermissionCenter {

    static let shared = PermissionCenter()

    private(set) var statuses: [PermissionKind: PermissionStatus] = [:]
    private(set) var lastRefresh: Date = .distantPast
    private(set) var isRefreshing = false

    /// 进程启动那一刻的屏幕录制授权状态。之后的变化都意味着「需要重启」。
    private static let screenGrantedAtLaunch: Bool = CGPreflightScreenCaptureAccess()

    var hasAnyIssue: Bool { statuses.values.contains { $0.needsAttention } }
    var issueCount: Int { statuses.values.filter(\.needsAttention).count }
    var grantedCount: Int { statuses.values.filter(\.isSatisfied).count }

    func status(for kind: PermissionKind) -> PermissionStatus {
        statuses[kind] ?? .unknown
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        refreshSynchronously()

        let automation = [
            (PermissionKind.automationMusic, SettingsAutomationApp.music),
            (.automationSpotify, .spotify),
        ]
        for (kind, app) in automation {
            let state = await Task.detached { app.permissionState() }.value
            statuses[kind] = Self.mapAutomation(state)
        }
        lastRefresh = Date()
    }

    /// Automation 的探测会启动子任务，页面首次出现时先用同步部分铺满，避免大面积「待确认」。
    func refreshSynchronously() {
        statuses[.screenRecording] = screenRecordingStatus()
        statuses[.speechRecognition] = speechStatus()
        statuses[.calendar] = calendarStatus()
        statuses[.loginItems] = loginItemStatus()
        lastRefresh = Date()
    }

    /// 字幕区只需要捕获与识别两项，避免每刷新一次就去做 AppleEvents 探测。
    func refreshCaptionStatuses() {
        statuses[.screenRecording] = screenRecordingStatus()
        statuses[.speechRecognition] = speechStatus()
        lastRefresh = Date()
    }

    // MARK: - 单项读取

    private func screenRecordingStatus() -> PermissionStatus {
        if Self.screenGrantedAtLaunch { return .allowed }
        // 启动时没有、现在有了：授权已写入 TCC，但 ScreenCaptureKit 需要新进程。
        if CGPreflightScreenCaptureAccess() { return .needsRestart }
        return .denied
    }

    private func speechStatus() -> PermissionStatus {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: .allowed
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notRequested
        @unknown default: .unknown
        }
    }

    private func calendarStatus() -> PermissionStatus {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .allowed
        case .writeOnly: .writeOnly
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notRequested
        @unknown default: .unknown
        }
    }

    private func loginItemStatus() -> PermissionStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .allowed
        case .requiresApproval: .notRequested
        case .notRegistered: .notRequested
        case .notFound: .notInstalled
        @unknown default: .unknown
        }
    }

    private static func mapAutomation(_ state: SettingsPermissionState) -> PermissionStatus {
        switch state {
        case .allowed: .allowed
        case .denied: .denied
        case .notRequested: .notRequested
        case .notInstalled: .notInstalled
        case .notRunning: .notRunning
        case .restricted: .restricted
        default: .unknown
        }
    }

    // MARK: - 修复动作

    /// 主动发起一次系统授权请求。
    ///
    /// 屏幕录制只能靠真正发起捕获来登记应用（`CGRequestScreenCaptureAccess` 会让系统把应用加进列表）；
    /// 日历与语音识别有各自的请求接口。这些调用会弹出系统对话框，所以只允许用户点按钮触发，
    /// 绝不在刷新状态时隐式调用。
    func requestAccess(for kind: PermissionKind) async {
        switch kind {
        case .screenRecording:
            // 探测本身就会让系统把应用加进「屏幕与系统音频录制」列表并弹窗。
            _ = await SystemAudioTap.hasPermission()
        case .speechRecognition:
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
            }
        case .calendar:
            let store = EKEventStore()
            _ = try? await store.requestFullAccessToEvents()
        case .automationMusic, .automationSpotify, .loginItems:
            // 自动化由第一次发送 AppleEvent 时由系统询问；登录项由「开机启动」开关驱动。
            break
        }
        refreshSynchronously()
    }

    /// 只有「被拒绝」或「仅写入」这类确实存在旧记录的状态才值得重置；
    /// 「尚未请求」时重置没有意义，直接请求授权才是正解。
    func canReset(_ kind: PermissionKind) -> Bool {
        guard kind.tccService != nil else { return false }
        switch status(for: kind) {
        case .denied, .writeOnly, .needsRestart: return true
        default: return false
        }
    }

    func canRequest(_ kind: PermissionKind) -> Bool {
        switch status(for: kind) {
        case .denied, .notRequested, .writeOnly: break
        default: return false
        }
        switch kind {
        case .screenRecording, .speechRecognition, .calendar: return true
        default: return false
        }
    }

    /// 清掉本应用在该服务下的授权记录。
    ///
    /// 用于「系统设置里的开关已经是打开的、应用仍然报未授权」：更新应用后签名身份变化，
    /// 旧记录绑在旧身份上，开关看着是开的却对这个二进制无效。重置后系统会重新请求授权。
    @discardableResult
    func resetAuthorization(for kind: PermissionKind) -> Bool {
        let services = Self.resetServices(for: kind)
        guard !services.isEmpty else { return false }

        var primarySucceeded = false
        for (index, service) in services.enumerated() {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            process.arguments = ["reset", service, Bundle.main.bundleIdentifier ?? "com.meteorkid.xnook"]
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                continue
            }
            // 第一条是本项的主服务；随附服务（如音频捕获）可缺可无，失败不影响结论。
            if index == 0 { primarySucceeded = process.terminationStatus == 0 }
        }
        refreshSynchronously()
        return primarySucceeded
    }

    /// 清一项授权要连带清掉的服务。
    ///
    /// 屏幕录制在 Sequoia 之后拆成两条 TCC 记录：`ScreenCapture` 管画面、`AudioCapture` 管系统音频。
    /// 只清前者会留下「屏幕已重新授权、音频仍绑在旧 cdhash 上」的半新半旧组合，
    /// 表现为字幕能起来但没有声音。所以这一项必须成对清。
    static func resetServices(for kind: PermissionKind) -> [String] {
        switch kind {
        case .screenRecording: ["ScreenCapture", "AudioCapture"]
        default: kind.tccService.map { [$0] } ?? []
        }
    }

    /// 重启自身：先让 LaunchServices 起一个新实例，再退出当前进程。
    /// 屏幕录制授权必须在新进程里才生效，所以这是「已授权但要重启」的唯一出路。
    static func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", Bundle.main.bundlePath]
        do {
            try process.run()
        } catch {
            return
        }
        NSApp.terminate(nil)
    }
}
