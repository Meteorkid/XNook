import AppKit
import SwiftUI

extension Notification.Name {
    static let xnookShowAboutPane = Notification.Name("xnookShowAboutPane")
    static let xnookScrollDown = Notification.Name("xnookScrollDown")
    static let islandDidCollapse = Notification.Name("islandDidCollapse")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) weak var shared: AppDelegate?

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
        SingleInstanceLock.acquire()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // 注册默认设置
        UserDefaults.standard.register(defaults: [
            "showOnAllSpaces": true,
            "hideInFullscreen": true,
            "expandedInactivityAutoHideDelay": 1.0,
            "hoverExitCollapseDelay": 0.2,
            "panelWidth": 800.0,
            "panelMaxHeight": 200.0,
            "islandWidth": 253.0,
            "islandHeight": 40.0,
            "islandWidthWithLyrics": 263.0,
            "islandHeightWithLyrics": 36.0,
            "hoverToExpandPanel": false,
            "scrollDownToExpandPanel": true,
            "reduceMotion": false,
            "jellyIntensity": "medium",
            "launchAtLogin": false,
            "showTickerLine": true,
            "showLyrics": true,
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
            handleIslandCommand(url)
        }
    }

    private func handleIslandCommand(_ url: URL) {
        // 解析路径: xnook://island/show
        guard url.host == "island",
              url.pathComponents.contains("show") else { return }

        // 收起内容，重新定位到鼠标屏幕，显示窗口
        notchWindow?.showAtMouseScreen()
    }

    // MARK: - Setup

    private func setupScrollMonitor() {
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            // Global monitor 回调不一定在主线程，确保后续 UI 操作安全
            DispatchQueue.main.async {
                self?.handleScrollEvent(event)
            }
        }
    }

    private func handleScrollEvent(_ event: NSEvent) {
        guard let window = notchWindow else { return }

        let mouseLocation = NSEvent.mouseLocation

        // 1. 横滑切换手势（仅收起状态响应）
        if window.islandState == .collapsed {
            let result = window.swipeRecognizer.handleScroll(event: event)
            if case .triggered(let direction) = result {
                AppSwitcher.shared.switchToOtherApp(swipeDirection: direction)
                return
            }
        }

        // 2. 双指下滑展开面板
        guard UserDefaults.standard.bool(forKey: "scrollDownToExpandPanel"),
              event.hasPreciseScrollingDeltas,
              event.scrollingDeltaY > NotchWindow.scrollExpandMinDelta
        else { return }

        guard let screen = window.screen else { return }

        let screenTop = screen.frame.origin.y + screen.frame.height
        let wf = window.frame

        // 扩展检测区域：覆盖药丸水平范围 + 屏幕顶端
        let hitFrame = NSRect(
            x: wf.minX,
            y: wf.minY,
            width: wf.width,
            height: max(wf.height, screenTop - wf.minY)
        )

        guard hitFrame.contains(mouseLocation) else { return }

        NotificationCenter.default.post(name: .xnookScrollDown, object: nil)
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
