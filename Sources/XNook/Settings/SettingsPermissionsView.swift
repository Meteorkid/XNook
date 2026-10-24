import SwiftUI

enum SettingsPermissionDestination {
    case calendar, automation, loginItems
    func open() {
        switch self {
        case .calendar: SystemPrivacySettings.openCalendars()
        case .automation: SystemPrivacySettings.openAutomation()
        case .loginItems: SystemPrivacySettings.openLoginItems()
        }
    }
}

struct SettingsPermissionsView: View {
    let permissions: SettingsPermissions
    var highlightedID: String?
    var openSettings: (SettingsPermissionDestination) -> Void = { $0.open() }

    var body: some View {
        VStack(spacing: 0) {
            permissionRow(id: "permissionCalendar", title: L10n.openCalendarsButton,
                state: permissions.calendar, help: L10n.settingsCalendarHelp, destination: .calendar)
            Divider()
            permissionRow(id: "permissionAutomation", title: L10n.openAutomationButton,
                state: permissions.automation, help: L10n.settingsAutomationHelp, destination: .automation)
            Divider()
            permissionRow(id: "permissionLoginItems", title: L10n.openLoginItemsButton,
                state: permissions.loginItems, help: L10n.settingsLoginHelp, destination: .loginItems)
        }
    }

    private func permissionRow(id: String, title: String, state: SettingsPermissionState,
                               help: String, destination: SettingsPermissionDestination) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(title).font(.system(size: 13, weight: .medium))
                Spacer()
                Text(state.title).font(.system(size: 11))
                    .foregroundStyle(state == .allowed ? Color.green : Color.secondary)
            }
            Text(help).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(title) { openSettings(destination) }.controlSize(.small)
                .accessibilityLabel(L10n.open + " " + title)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .settingsSearchTarget(id: id, highlightedID: highlightedID)
    }
}
