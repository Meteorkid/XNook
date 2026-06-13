import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) var shared: AppDelegate!

    private var notchWindow: NotchWindow?
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?

    // MARK: - Lifecycle

    func applicationWillFinishLaunching(_ notification: Notification) {
        Self.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupNotchWindow()
        setupMenuBarItem()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        .terminateCancel
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard url.scheme == "xnook" else { continue }
            NSApp.activate(ignoringOtherApps: true)
            notchWindow?.showWindow()
        }
    }

    // MARK: - Setup

    private func setupNotchWindow() {
        let window = NotchWindow()
        let hostView = NotchHostingView(
            rootView: NotchContentView()
        )
        hostView.frame = window.contentView!.bounds
        hostView.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(hostView)
        notchWindow = window
        window.orderFrontRegardless()
    }

    private func setupMenuBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "X Nook")
            button.action = #selector(toggleNotch)
            button.target = self
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show X Nook", action: #selector(showNotch), keyEquivalent: "s"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Preferences...", action: #selector(openPreferences), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    // MARK: - Actions

    @objc private func toggleNotch() {
        if let w = notchWindow {
            w.isVisible ? w.orderOut(nil) : w.orderFrontRegardless()
        }
    }

    @objc private func showNotch() {
        notchWindow?.orderFrontRegardless()
    }

    @objc private func openPreferences() {
        if let w = settingsWindow, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let w = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.isFloatingPanel = true
        w.hidesOnDeactivate = false
        w.title = "X Nook Settings"
        w.center()
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: SettingsView())
        settingsWindow = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - Hosting View

final class NotchHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
