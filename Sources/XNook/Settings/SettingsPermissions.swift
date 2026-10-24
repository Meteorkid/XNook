import EventKit
import ServiceManagement
import Observation

enum SettingsPermissionState: Equatable {
    case unknown, notRequested, allowed, writeOnly, denied, restricted, disabled, requiresApproval, unavailable
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
        }
    }
}

@Observable @MainActor
final class SettingsPermissions {
    private(set) var calendar: SettingsPermissionState = .unknown
    private(set) var loginItems: SettingsPermissionState = .unknown
    let automation = SettingsPermissionState.unknown
    private let readCalendar: () -> EKAuthorizationStatus
    private let readLoginItems: () -> SMAppService.Status

    init(readCalendar: @escaping () -> EKAuthorizationStatus = { EKEventStore.authorizationStatus(for: .event) },
         readLoginItems: @escaping () -> SMAppService.Status = { SMAppService.mainApp.status }) {
        self.readCalendar = readCalendar
        self.readLoginItems = readLoginItems
    }

    func refresh() {
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
    }
}
