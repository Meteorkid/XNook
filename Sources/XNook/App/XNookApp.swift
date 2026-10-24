import SwiftUI

@main
struct XNookApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // 保留无启动窗口的 scene，设置窗口统一由 AppDelegate 管理。
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button(L10n.preferences) {
                    appDelegate.openPreferences()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
