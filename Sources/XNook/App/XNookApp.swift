import SwiftUI

@main
struct XNookApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        SingleInstanceLock.acquire()
    }

    var body: some Scene {
        // 使用 Settings scene 作为菜单栏入口
        Settings {
            EmptyView()
        }
    }
}
