import AppKit
import Carbon
import EventKit
import ServiceManagement
import Observation

enum SettingsPermissionState: Equatable, Sendable {
    case unknown, notRequested, allowed, writeOnly, denied, restricted, disabled, requiresApproval, unavailable
    case notInstalled, notRunning
    var title: String {
        switch self {
        case .unknown: L10n.localized(zh: "尚未确认", en: "Not confirmed")
        case .notRequested: L10n.localized(zh: "尚未请求", en: "Not requested")
        case .allowed: L10n.localized(zh: "已允许", en: "Allowed")
        case .writeOnly: L10n.localized(zh: "仅可写入，无法读取", en: "Write-only, cannot read")
        case .denied: L10n.localized(zh: "已拒绝", en: "Denied")
        case .restricted: L10n.localized(zh: "受系统限制", en: "Restricted")
        case .disabled: L10n.localized(zh: "未启用", en: "Not enabled")
        case .requiresApproval: L10n.localized(zh: "等待系统批准", en: "Approval required")
        case .unavailable: L10n.localized(zh: "系统未找到此登录项", en: "Login item not found")
        case .notInstalled: L10n.localized(zh: "未安装", en: "Not installed")
        case .notRunning: L10n.localized(zh: "未运行，暂无法检查", en: "Not running; cannot check yet")
        }
    }
}

enum SettingsAutomationApp: String, CaseIterable, Sendable {
    case music = "com.apple.Music"
    case spotify = "com.spotify.client"

    var title: String { self == .music ? "Apple Music" : "Spotify" }

    func permissionState(
        isInstalled: (String) -> Bool = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil },
        runningProcessIdentifier: (String) -> pid_t? = {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0).first?.processIdentifier
        },
        determinePermission: (pid_t, Bool) -> OSStatus = { processIdentifier, askUserIfNeeded in
            let target = NSAppleEventDescriptor(processIdentifier: processIdentifier)
            return AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, askUserIfNeeded)
        }
    ) -> SettingsPermissionState {
        guard isInstalled(rawValue) else { return .notInstalled }
        guard let processIdentifier = runningProcessIdentifier(rawValue) else { return .notRunning }
        // 指向已运行进程且禁止询问，刷新不会启动播放器或弹出授权窗口。
        switch determinePermission(processIdentifier, false) {
        case noErr: return .allowed
        case OSStatus(errAEEventWouldRequireUserConsent): return .notRequested
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(procNotFound): return .notRunning
        default: return .unknown
        }
    }
}

@Observable @MainActor
final class SettingsPermissions {
    private(set) var calendar: SettingsPermissionState = .unknown
    private(set) var loginItems: SettingsPermissionState = .unknown
    private(set) var automation: [SettingsAutomationApp: SettingsPermissionState] = [.music: .unknown, .spotify: .unknown]
    private(set) var loginItemsError: String?
    private let readCalendar: () -> EKAuthorizationStatus
    private let readLoginItems: () -> SMAppService.Status
    private let readAutomation: @Sendable (SettingsAutomationApp) async -> SettingsPermissionState
    private let writeLoginItems: (Bool) throws -> Void
    private let writeLoginPreference: (Bool) -> Void
    @ObservationIgnored private var automationRefreshTask: Task<Void, Never>?

    // 已注册但待批准时仍可通过开关取消注册，状态行单独说明尚未生效。
    var launchAtLoginEnabled: Bool { loginItems == .allowed || loginItems == .requiresApproval }

    init(readCalendar: @escaping () -> EKAuthorizationStatus = { EKEventStore.authorizationStatus(for: .event) },
         readLoginItems: @escaping () -> SMAppService.Status = { SMAppService.mainApp.status },
         readAutomation: @escaping @Sendable (SettingsAutomationApp) async -> SettingsPermissionState = { app in
             await Task.detached { app.permissionState() }.value
         },
         writeLoginItems: @escaping (Bool) throws -> Void = { enabled in
             if enabled { try SMAppService.mainApp.register() }
             else { try SMAppService.mainApp.unregister() }
         },
         writeLoginPreference: @escaping (Bool) -> Void = { UserDefaults.standard.set($0, forKey: "launchAtLogin") }) {
        self.readCalendar = readCalendar
        self.readLoginItems = readLoginItems
        self.readAutomation = readAutomation
        self.writeLoginItems = writeLoginItems
        self.writeLoginPreference = writeLoginPreference
    }

    deinit { automationRefreshTask?.cancel() }

    @discardableResult
    func refresh() -> Task<Void, Never> {
        switch readCalendar() {
        case .notDetermined: calendar = .notRequested
        case .fullAccess: calendar = .allowed
        case .writeOnly: calendar = .writeOnly
        case .denied: calendar = .denied
        case .restricted: calendar = .restricted
        @unknown default: calendar = .unknown
        }
        switch readLoginItems() {
        case .notRegistered: loginItems = .disabled
        case .enabled: loginItems = .allowed
        case .requiresApproval: loginItems = .requiresApproval
        case .notFound: loginItems = .unavailable
        @unknown default: loginItems = .unknown
        }
        automationRefreshTask?.cancel()
        let readAutomation = self.readAutomation
        let task = Task { [weak self] in
            for app in SettingsAutomationApp.allCases {
                guard !Task.isCancelled else { return }
                let state = await readAutomation(app)
                guard !Task.isCancelled else { return }
                self?.automation[app] = state
            }
        }
        automationRefreshTask = task
        return task
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try writeLoginItems(enabled)
            writeLoginPreference(enabled)
            loginItemsError = nil
        } catch {
            loginItemsError = L10n.settingsLoginUpdateFailed
        }
        refresh()
    }
}
