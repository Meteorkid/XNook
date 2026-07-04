import AppKit
import Foundation

/// 打开 macOS 系统设置中的常见权限面板，便于首次配置 X Nook 所需能力。
enum SystemPrivacySettings {
    static func openPrivacySecurity() {
        if #available(macOS 13.0, *) {
            open("x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension")
        } else {
            open("x-apple.systempreferences:com.apple.preference.security?Privacy")
        }
    }

    static func openCalendars() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
    }

    static func openAutomation() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
    }

    static func openAccessibility() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openLoginItems() {
        if #available(macOS 13.0, *) {
            open("x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
        } else {
            open("x-apple.systempreferences:com.apple.preferences.users")
        }
    }

    private static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
