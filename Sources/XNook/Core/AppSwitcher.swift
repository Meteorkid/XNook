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
        DispatchQueue.global(qos: .userInitiated).async {
            let script = """
            tell application "X Island"
                activate
            end tell
            """
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
        }
    }

    /// 切换到 X Nook
    func switchToXNook() {
        DispatchQueue.global(qos: .userInitiated).async {
            let script = """
            tell application "X Nook"
                activate
            end tell
            """
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
        }
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
