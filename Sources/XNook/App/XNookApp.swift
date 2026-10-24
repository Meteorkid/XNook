import AppKit
import SwiftUI

@main
struct XNookApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            appDelegate.makeSettingsContent()
                .background(SettingsWindowReader { [weak appDelegate] window in
                    appDelegate?.registerSettingsWindow(window)
                }.frame(width: 0, height: 0).allowsHitTesting(false))
        }
        .defaultSize(width: 560, height: 550)
        .windowResizability(.contentSize)
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

/// 通过所属视图登记系统创建的设置窗口，不接管 SwiftUI 的窗口代理。
struct SettingsWindowReader: NSViewRepresentable {
    var onWindowAvailable: (NSWindow) -> Void

    func makeNSView(context: Context) -> WindowView {
        WindowView(onWindowAvailable: onWindowAvailable)
    }

    func updateNSView(_ nsView: WindowView, context: Context) {
        nsView.onWindowAvailable = onWindowAvailable
        if let window = nsView.window { onWindowAvailable(window) }
    }

    final class WindowView: NSView {
        var onWindowAvailable: (NSWindow) -> Void

        init(onWindowAvailable: @escaping (NSWindow) -> Void) {
            self.onWindowAvailable = onWindowAvailable
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindowAvailable(window) }
        }
    }
}
