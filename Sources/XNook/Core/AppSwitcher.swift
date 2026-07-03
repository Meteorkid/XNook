import AppKit

/// 负责在 X Nook 和 X Island 之间快速切换
@MainActor
final class AppSwitcher {
    static let shared = AppSwitcher()

    private let xnookBundleID = "com.meteorkid.xnook"
    private let xislandBundleID = "com.meteorkid.xisland"

    /// 切换到另一个应用
    func switchToOtherApp() {
        let currentAppBundleID = Bundle.main.bundleIdentifier

        if currentAppBundleID == xnookBundleID {
            switchToXIsland()
        } else {
            switchToXNook()
        }
    }

    /// 切换到 X Island
    func switchToXIsland() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: xislandBundleID) else {
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    /// 切换到 X Nook
    func switchToXNook() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: xnookBundleID) else {
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    /// 检查另一个应用是否在运行
    func isOtherAppRunning() -> Bool {
        let currentAppBundleID = Bundle.main.bundleIdentifier
        let targetBundleID = currentAppBundleID == xnookBundleID ? xislandBundleID : xnookBundleID

        return NSRunningApplication.runningApplications(withBundleIdentifier: targetBundleID).count > 0
    }

    /// 获取另一个应用的名称
    var otherAppName: String {
        let currentAppBundleID = Bundle.main.bundleIdentifier
        return currentAppBundleID == xnookBundleID ? "X Island" : "X Nook"
    }
}
