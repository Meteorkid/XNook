import AppKit
import SwiftUI

extension Notification.Name {
    static let xnookShowAboutPane = Notification.Name("xnookShowAboutPane")
    static let xnookScrollDown = Notification.Name("xnookScrollDown")
    static let xnookCollapse = Notification.Name("xnookCollapse")
    static let islandDidCollapse = Notification.Name("islandDidCollapse")
}

/// 跨进程通知前缀：请求目标灵动岛隐藏自身
/// 完整通知名格式：island.switch.hide.{targetAppName}
private let hideNotificationPrefix = "island.switch.hide."

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) weak var shared: AppDelegate?

    var notchWindow: NotchWindow?
    let themeManager = ThemeManager()
    let updateManager = UpdateManager()
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var scrollMonitor: Any?
    private var islandHideObserver: NSObjectProtocol?

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

        SettingsDefaults.register()
        IslandIntegrationSettings.registerDefaults()
        CalendarReminderManager.shared.startMonitoring()

        setupNotchWindow()
        setupMenuBarItem()
        setupScrollMonitor()

        // 监听跨进程通知：对方应用请求本应用隐藏
        // 通知名格式：island.switch.hide.{targetAppName}
        if let appName = AppSwitcher.shared.currentAppName {
            let hideNotification = "\(hideNotificationPrefix)\(appName)"
            islandHideObserver = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(hideNotification),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.hideIslandForSwitch()
                }
            }
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openPreferencesFromNotification),
            name: .xnookShowAboutPane,
            object: nil
        )

        scheduleInitialVisibilityResolution()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard url.scheme == AppSwitcher.shared.currentURLScheme else { continue }
            handleIslandCommand(url)
        }
    }

    private func handleIslandCommand(_ url: URL) {
        // 解析路径: xnook://island/show
        guard url.host == "island",
              url.pathComponents.contains("show"),
              let window = notchWindow else { return }

        // 立即设置切换标志（同步），防止 activeSpaceDidChange 重新显示窗口
        window.isHiddenByIslandSwitch = false
        window.isSwitchingApps = true
        window.swipeRecognizer.suppress(for: 0.8)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            window.isSwitchingApps = false
        }

        // 先收起并显示自身，确认接管后再请求来源岛隐藏
        NotificationCenter.default.post(name: .xnookCollapse, object: nil)
        window.showAtMouseScreen()

        // 发送跨进程通知让来源岛隐藏
        // 需要找到来源岛的应用名
        if let sourceAppName = AppSwitcher.shared.otherIslandNames.first {
            let hideNotification = "\(hideNotificationPrefix)\(sourceAppName)"
            postHideNotification(hideNotification)
        }
    }

    private func hideIslandForSwitch() {
        guard let window = notchWindow else { return }
        window.isHiddenByIslandSwitch = true
        window.isSwitchingApps = true
        window.orderOut(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            window.isSwitchingApps = false
        }
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

        // 1. 横滑切换手势（仅由鼠标下最上层的收起岛响应）
        if IslandIntegrationSettings.isSwipeSwitchEnabled,
           IslandWindowOwnership.canHandleGlobalSwipe(
            isVisible: window.isVisible,
            isCollapsed: window.islandState == .collapsed,
            windowFrame: window.frame,
            mouseLocation: mouseLocation
        ) {
            let result = window.swipeRecognizer.handleScroll(event: event)
            if case .triggered(_) = result {
                guard window.isFrontmostIslandWindow() else {
                    window.swipeRecognizer.reset()
                    return
                }
                AppSwitcher.shared.switchToNextIsland()
                return
            }
        } else {
            window.swipeRecognizer.reset()
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
        themeManager.onSchemeChange = { [weak self] in
            guard let self else { return }
            if let notchWindow = self.notchWindow {
                self.updateWindowAppearance(notchWindow)
            }
            if let settingsWindow = self.settingsWindow {
                self.updateWindowAppearance(settingsWindow)
            }
        }
        updateWindowAppearance(window)
        themeManager.startObservingSystemAppearance()
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
        menu.addItem(NSMenuItem(title: L10n.checkForUpdates, action: #selector(checkForUpdates), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: L10n.quit, action: #selector(quit), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    // MARK: - Actions

    @objc private func toggleNotch() {
        if let w = notchWindow {
            if w.isVisible {
                w.hideWindow()
            } else {
                showIsland(preferMouseScreen: false, hidePeers: true)
            }
        }
    }

    @objc private func showNotch() {
        showIsland(preferMouseScreen: false, hidePeers: true)
    }

    @objc func openPreferences() {
        if let w = settingsWindow, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let w = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.isFloatingPanel = true
        w.hidesOnDeactivate = false
        w.title = L10n.xnookSettings
        w.center()
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(
            rootView: SettingsView()
                .environment(themeManager)
                .environment(updateManager)
        )
        settingsWindow = w
        updateWindowAppearance(w)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openPreferencesFromNotification() {
        openPreferences()
    }

    @objc private func checkForUpdates() {
        openPreferences()
        // 打开设置后自动检查更新
        Task { @MainActor in
            await updateManager.checkForUpdates()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        CalendarReminderManager.shared.stopMonitoring()
        if let observer = islandHideObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            islandHideObserver = nil
        }
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
    }

    private func postHideNotification(_ name: String) {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(name),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    func updateWindowAppearance(_ window: NSWindow) {
        let scheme = themeManager.resolvedScheme
        window.appearance = scheme == .dark
            ? NSAppearance(named: .darkAqua)
            : NSAppearance(named: .aqua)
    }

    private func scheduleInitialVisibilityResolution() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.resolveInitialIslandVisibility()
        }
    }

    private func resolveInitialIslandVisibility() {
        guard let currentIsland = AppSwitcher.shared.currentIsland else {
            showIsland(preferMouseScreen: false, hidePeers: false)
            return
        }

        let otherInstalled = AppSwitcher.shared.otherIslandNames.contains { AppSwitcher.shared.isIslandInstalled(named: $0) }
        let preferredIsland = IslandIntegrationSettings.preferredStartupIsland(
            currentApp: currentIsland,
            otherAppInstalled: otherInstalled
        )
        let preferredRunning = AppSwitcher.shared.isIslandRunning(named: preferredIsland.rawValue)
        let shouldShow = IslandIntegrationSettings.shouldShowOnLaunch(
            currentApp: currentIsland,
            preferredApp: preferredIsland,
            preferredAppRunning: preferredRunning
        )

        guard shouldShow else { return }

        showIsland(preferMouseScreen: false, hidePeers: preferredIsland == currentIsland)
    }

    private func showIsland(preferMouseScreen: Bool, hidePeers: Bool) {
        guard let window = notchWindow else { return }

        if preferMouseScreen {
            window.showAtMouseScreen()
        } else {
            window.showWindow()
        }

        guard hidePeers else { return }
        requestOtherIslandsToHide()
    }

    private func requestOtherIslandsToHide() {
        for otherIslandName in AppSwitcher.shared.otherIslandNames {
            let hideNotification = "\(hideNotificationPrefix)\(otherIslandName)"
            postHideNotification(hideNotification)
        }
    }
}

// MARK: - Hosting View

final class NotchHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
