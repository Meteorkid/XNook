import AppKit
import SwiftUI

extension Notification.Name {
    static let xnookShowAboutPane = Notification.Name("xnookShowAboutPane")
    static let xnookScrollDown = Notification.Name("xnookScrollDown")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) var shared: AppDelegate!

    var notchWindow: NotchWindow?
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var scrollMonitor: Any?

    /// 悬停自动展开是否关闭
    private var hoverToExpandDisabled: Bool {
        !UserDefaults.standard.bool(forKey: "hoverToExpandPanel")
    }

    /// 鼠标是否在药丸区域附近（允许一定的误差范围）
    private var isMouseNearPill: Bool {
        guard let window = notchWindow else { return false }
        let mouseLocation = NSEvent.mouseLocation
        let pillFrame = window.frame
        // 扩大检测范围：上下左右各 20pt
        let expandedFrame = pillFrame.insetBy(dx: -20, dy: -20)
        return expandedFrame.contains(mouseLocation)
    }

    // MARK: - Lifecycle

    func applicationWillFinishLaunching(_ notification: Notification) {
        Self.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // 注册默认设置（与 X Island 一致）
        UserDefaults.standard.register(defaults: [
            "showOnAllSpaces": true,
            "hideInFullscreen": true,
            "autoCollapseDelay": 3.0,
            "expandedInactivityAutoHideDelay": 10.0,
            "hoverExitCollapseDelay": 0.5,
            "panelWidth": 420.0,
            "panelMaxHeight": 480.0,
            "islandWidth": 180.0,
            "islandHeight": 32.0,
            "hoverToExpandPanel": true,
            "scrollDownToExpandPanel": false,
            "reduceMotion": false,
            "launchAtLogin": false,
            "showTickerLine": true,
            "tickerSpeed": 25.0,
        ])

        setupNotchWindow()
        setupMenuBarItem()
        setupScrollMonitor()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openPreferencesFromNotification),
            name: .xnookShowAboutPane,
            object: nil
        )
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard url.scheme == "xnook" else { continue }
            NSApp.activate(ignoringOtherApps: true)
            notchWindow?.orderFrontRegardless()
        }
    }

    // MARK: - Setup

    private func setupScrollMonitor() {
        // 全局事件监听器：捕获刘海区域的滚动事件
        // 当窗口无法接收 scrollWheel 事件时（如刘海区域），此监听器作为备用
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self,
                  let window = self.notchWindow,
                  UserDefaults.standard.bool(forKey: "scrollDownToExpandPanel"),
                  event.hasPreciseScrollingDeltas,
                  event.scrollingDeltaY > NotchWindow.scrollExpandMinDelta
            else { return }

            // 检查鼠标是否在屏幕顶部区域（灵动岛区域）
            let mouseLocation = NSEvent.mouseLocation
            guard let screen = window.screen else { return }

            // 灵动岛区域：屏幕顶部 100pt 范围内，且在屏幕水平中心 60% 范围内
            let screenTop = screen.frame.origin.y + screen.frame.height
            let isInTopRegion = mouseLocation.y > screenTop - 100
            let isInCenterRegion = abs(mouseLocation.x - screen.frame.midX) < screen.frame.width * 0.3

            guard isInTopRegion && isInCenterRegion else { return }

            NotificationCenter.default.post(name: .xnookScrollDown, object: nil)
        }
    }

    private func setupNotchWindow() {
        let window = NotchWindow()
        let hostView = NotchHostingView(
            rootView: NotchContentView(onSizeChange: { [weak window] w, h in
                window?.resizeToFit(contentWidth: w, contentHeight: h)
            })
        )
        hostView.frame = window.contentView!.bounds
        hostView.autoresizingMask = [.width, .height]
        if #available(macOS 13.0, *) {
            hostView.sizingOptions = []
        }
        window.contentView?.addSubview(hostView)
        notchWindow = window
        window.orderFrontRegardless()
    }

    private func setupMenuBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            let image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "X Nook")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeft
            button.action = #selector(toggleNotch)
            button.target = self
            button.toolTip = "X Nook"
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: L10n.showXNook, action: #selector(showNotch), keyEquivalent: "s"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: L10n.preferences, action: #selector(openPreferences), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: L10n.quit, action: #selector(quit), keyEquivalent: "q"))
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

    @objc func openPreferences() {
        if let w = settingsWindow, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let w = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.isFloatingPanel = true
        w.hidesOnDeactivate = false
        w.title = L10n.xnookSettings
        w.center()
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: SettingsView())
        settingsWindow = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openPreferencesFromNotification() {
        openPreferences()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
    }
}

// MARK: - Hosting View

final class NotchHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
