import AppKit
import SwiftUI

extension Notification.Name {
    static let xnookShowAboutPane = Notification.Name("xnookShowAboutPane")
    static let xnookScrollDown = Notification.Name("xnookScrollDown")
    static let xnookCollapse = Notification.Name("xnookCollapse")
    static let xnookWindowDidPresent = Notification.Name("xnookWindowDidPresent")
    static let xnookRevealPanel = Notification.Name("xnookRevealPanel")
    static let islandDidCollapse = Notification.Name("islandDidCollapse")
}

/// 跨进程通知前缀：请求目标灵动岛隐藏自身
/// 完整通知名格式：island.switch.hide.{targetAppName}
private let hideNotificationPrefix = "island.switch.hide."

/// 校验应用名是否安全用于通知名拼接（仅允许字母、数字、连字符、下划线、点）
private func isValidNotificationAppName(_ name: String) -> Bool {
    name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-._".contains($0)) }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    var notchWindow: NotchWindow?
    weak var notesManagerForTermination: NotesManager?
    private(set) var discardsPendingNotesOnTermination = false
    let themeManager = ThemeManager()
    let updateManager = UpdateManager()
    let activityCoordinator = PanelActivityCoordinator(
        onPresent: { event in
            if event.source == "calendar" { CalendarReminderManager.shared.playDueReminderSound() }
        },
        onAction: { action in
            if action == .openCalendar,
               let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
                NSWorkspace.shared.open(url)
            }
        }
    )
    lazy var claudeCompletionReceiver = ClaudeCompletionReceiver { [weak self] event in
        guard let self, UserDefaults.standard.bool(forKey: "claudeCompletionEnabled"),
              UserDefaults.standard.bool(forKey: "activityNotificationsEnabled") else { return }
        self.activityCoordinator.setEnabled(true)
        self.activityCoordinator.enqueue(PanelActivityEvent(source: event.source, id: event.id,
            title: L10n.claudeResponseEnded, kind: .completion,
            createdAt: event.createdAt, expiresAt: event.expiresAt))
    }
    private var claudePreferencesObserver: NSObjectProtocol?
    private var claudeWasEnabled: Bool?
    lazy var globalPanelShortcut = GlobalPanelShortcutController { [weak self] in
        self?.revealPanelFromShortcut()
    }
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var scrollMonitor: Any?
    private var islandHideObserver: NSObjectProtocol?
    private var pendingIslandShowURL: URL?
    private var hasExplicitIslandVisibilityRequest = false
    private var ownsSharedData = false
    /// 统一的 isSwitchingApps 清除 WorkItem，确保只有一个活跃的清除计时器
    private var clearSwitchingAppsWorkItem: DispatchWorkItem?

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
        ownsSharedData = SingleInstanceLock.acquire()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ownsSharedData else { return }
        NSApp.setActivationPolicy(.accessory)

        SettingsDefaults.register()
        IslandIntegrationSettings.registerDefaults()
        IslandIntegrationSettings.markProtocolAvailable(for: .xnook)
        activityCoordinator.setEnabled(UserDefaults.standard.bool(forKey: "activityNotificationsEnabled"))
        synchronizeClaudeCompletion()
        claudePreferencesObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.synchronizeClaudeCompletion() }
        }
        CalendarReminderManager.shared.onReminder = { [weak activityCoordinator] reminder in
            guard let activityCoordinator else { return false }
            activityCoordinator.setEnabled(UserDefaults.standard.bool(forKey: "activityNotificationsEnabled"))
            guard activityCoordinator.isEnabled else { return false }
            activityCoordinator.enqueue(.calendarReminder(reminder))
            // 已交给统一队列，不能在提示被门控时绕过队列发声。
            return true
        }
        CalendarReminderManager.shared.startMonitoring()

        setupNotchWindow()
        if let pendingIslandShowURL { handleIslandCommand(pendingIslandShowURL) }
        setupMenuBarItem()
        setupScrollMonitor()
        globalPanelShortcut.activate()

        // 监听跨进程通知：对方应用请求本应用隐藏
        // 通知名格式：island.switch.hide.{targetAppName}
        if let appName = AppSwitcher.shared.currentAppName {
            let hideNotification = "\(hideNotificationPrefix)\(appName)"
            islandHideObserver = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(hideNotification),
                object: nil,
                queue: .main
            ) { [weak self] note in
                let peer = note.userInfo?["source"] as? String
                let shownAt = note.userInfo?["shownAt"] as? TimeInterval
                Task { @MainActor [weak self] in
                    self?.hideIslandForSwitch(from: peer, shownAt: shownAt)
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

        // 启动自动检查更新
        updateManager.startAutoCheck()

        // 监听更新状态变化，实时刷新菜单栏
        observeUpdateState()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        discardsPendingNotesOnTermination = false
        guard notesManagerForTermination?.prepareForTermination() != false else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L10n.notesStorageWarning
            alert.informativeText = L10n.notesSaveFailed
            alert.addButton(withTitle: L10n.back)
            alert.addButton(withTitle: L10n.notesQuitWithoutSaving)
            sender.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
            discardsPendingNotesOnTermination = true
            return .terminateNow
        }
        return .terminateNow
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard url.scheme == AppSwitcher.shared.currentURLScheme else { continue }
            handleIslandCommand(url)
        }
    }

    private func handleIslandCommand(_ url: URL) {
        // 解析路径: xnook://xnook/show
        // url.host 是目标应用名，检查是否是发给自己的
        guard let targetName = url.host,
              targetName == AppSwitcher.shared.currentAppName,
              url.path == "/show" else { return }
        hasExplicitIslandVisibilityRequest = true
        guard let window = notchWindow else {
            pendingIslandShowURL = url
            return
        }
        pendingIslandShowURL = nil
        AppSwitcher.shared.cancelSwitch()

        clearSwitchingAppsWorkItem?.cancel()
        // 准备请求保存在窗口上，冷启动视图注册后仍能消费，不能依赖一次性通知。
        window.beginInboundHandoff { [weak self, weak window] generation in
            guard let self, let window else { return }
            window.showPreparedHandoff(generation: generation)
            self.scheduleClearSwitchingApps(window: window, delay: 1.5)
            self.requestOtherIslandsToHide()
        }
    }

    func hideIslandForSwitch(from peer: String? = nil, shownAt: TimeInterval? = nil,
                             using switcher: AppSwitcher? = nil) {
        guard let window = notchWindow,
              (switcher ?? .shared).acceptPeerHideRequest(from: peer, shownAt: shownAt, after: window.lastExplicitShowTime)
        else { return }
        hasExplicitIslandVisibilityRequest = true
        clearSwitchingAppsWorkItem?.cancel()
        window.hideWindowForIslandSwitch()
    }

    /// 统一调度 isSwitchingApps 清除，取消之前的计时器避免竞争
    func scheduleClearSwitchingApps(window: NotchWindow?, delay: TimeInterval) {
        clearSwitchingAppsWorkItem?.cancel()
        let handoffGeneration = window?.handoffState.generation
        let workItem = DispatchWorkItem { [weak self, weak window] in
            guard let window, handoffGeneration == window.handoffState.generation else { return }
            self?.clearSwitchingProtection(window: window)
        }
        clearSwitchingAppsWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func clearSwitchingProtection(window: NotchWindow, using switcher: AppSwitcher? = nil) {
        guard !(switcher ?? .shared).isSwitchInProgress,
              window.handoffState.pendingPreparation == nil,
              !window.handoffState.isFadingOut else { return }
        window.isSwitchingApps = false
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
        // 自然滚动开启时 deltaY 正值=手指下滑；关闭时 deltaY 负值=手指下滑
        // 统一转换为物理手指方向：正值=手指向下
        let physicalDeltaY = event.isDirectionInvertedFromDevice
            ? event.scrollingDeltaY
            : -event.scrollingDeltaY
        guard UserDefaults.standard.bool(forKey: "scrollDownToExpandPanel"),
              event.hasPreciseScrollingDeltas,
              physicalDeltaY > NotchWindow.scrollExpandMinDelta
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
        notchWindow = window
        let hostView = NotchHostingView(
            rootView: NotchContentView(onSizeChange: { [weak window] w, h in
                window?.resizeToFit(contentWidth: w, contentHeight: h)
            }, activityCoordinator: activityCoordinator)
        )
        hostView.frame = window.contentView!.bounds
        hostView.autoresizingMask = [.width, .height]
        if #available(macOS 13.0, *) {
            hostView.sizingOptions = []
        }
        window.contentView?.addSubview(hostView)
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
        menu.addItem(NSMenuItem(title: L10n.showXNook, action: #selector(showNotch), keyEquivalent: "0"))
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

    func openLayoutEditor() {
        showIsland(preferMouseScreen: false, hidePeers: true)
        NotificationCenter.default.post(name: .xnookEditPanelLayout, object: nil)
    }

    @objc func openPreferences() {
        let window = settingsWindowForPresentation()
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func makeSettingsContent() -> some View {
        SettingsView()
            .environment(themeManager)
            .environment(updateManager)
    }

    func registerSettingsWindow(_ window: NSWindow) {
        window.minSize = NSSize(width: 560, height: 400)
        window.maxSize = NSSize(width: 560, height: 700)
        let frame = window.frame
        let height = min(max(frame.height, window.minSize.height), window.maxSize.height)
        if frame.width != 560 || frame.height != height {
            // 恢复旧窗口时也沿用尺寸约束，保留原来的顶部位置。
            window.setFrame(NSRect(x: frame.minX, y: frame.maxY - height, width: 560, height: height), display: false)
        }
        guard settingsWindow !== window else { return }
        let previousWindow = settingsWindow
        settingsWindow = window
        window.title = L10n.xnookSettings
        window.isReleasedWhenClosed = false
        updateWindowAppearance(window)
        // 系统 scene 接管设置入口后，移除此前创建的备用面板。
        previousWindow?.close()
    }

    func settingsWindowForPresentation() -> NSWindow {
        if let settingsWindow { return settingsWindow }

        let w = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 550),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.isFloatingPanel = true
        w.hidesOnDeactivate = false
        w.center()
        w.contentView = NSHostingView(rootView: makeSettingsContent())
        registerSettingsWindow(w)
        return w
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

    /// 监听更新状态变化，实时刷新菜单栏
    private func observeUpdateState() {
        withObservationTracking {
            _ = updateManager.state
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshUpdateMenuItem()
                self?.observeUpdateState()
            }
        }
    }

    /// 刷新更新菜单项
    private func refreshUpdateMenuItem() {
        // 找到更新菜单项并更新标题
        if let menu = statusItem?.menu {
            for item in menu.items {
                if item.title == L10n.checkForUpdates || item.title == L10n.checkForUpdatesButtonChecking {
                    switch updateManager.state {
                    case .checking:
                        item.title = L10n.checkForUpdatesButtonChecking
                    case .updateAvailable(let version):
                        item.title = "Update Available: \(version)"
                    default:
                        item.title = L10n.checkForUpdates
                    }
                    break
                }
            }
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        globalPanelShortcut.shutdown()
        claudeCompletionReceiver.shutdown()
        if let observer = claudePreferencesObserver {
            NotificationCenter.default.removeObserver(observer)
            claudePreferencesObserver = nil
        }
        CalendarReminderManager.shared.onReminder = nil
        activityCoordinator.shutdown()
        clearSwitchingAppsWorkItem?.cancel()
        clearSwitchingAppsWorkItem = nil
        notchWindow?.tearDown()
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

    private func synchronizeClaudeCompletion() {
        guard ownsSharedData else { return }
        let enabled = UserDefaults.standard.bool(forKey: "claudeCompletionEnabled")
            && UserDefaults.standard.bool(forKey: "activityNotificationsEnabled")
        guard claudeWasEnabled != enabled else { return }
        claudeWasEnabled = enabled
        claudeCompletionReceiver.setEnabled(enabled)
    }

    private func revealPanelFromShortcut() {
        guard ownsSharedData, let window = notchWindow else { return }
        showIsland(preferMouseScreen: true, hidePeers: true)
        window.requestPanelReveal()
    }

    private func postHideNotification(_ name: String) {
        guard name.hasPrefix(hideNotificationPrefix), notchWindow?.isVisible == true else { return }
        let appName = String(name.dropFirst(hideNotificationPrefix.count))
        guard isValidNotificationAppName(appName) else { return }
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(name),
            object: nil,
            userInfo: ["source": AppSwitcher.shared.currentAppName ?? "",
                       "shownAt": notchWindow?.lastExplicitShowTime ?? 0],
            deliverImmediately: true
        )
    }

    func updateWindowAppearance(_ window: NSWindow) {
        let applicationIsDark = themeManager.resolvedScheme == .dark
        let isDark = window is NotchWindow
            ? IslandBackgroundPolicy.isDark(
                style: IslandBackgroundStyle.resolved(from: UserDefaults.standard.string(forKey: "islandBackgroundStyle")),
                applicationIsDark: applicationIsDark)
            : applicationIsDark
        let name: NSAppearance.Name = isDark ? .darkAqua : .aqua
        guard window.appearance?.name != name else { return }
        window.appearance = NSAppearance(named: name)
    }

    private func scheduleInitialVisibilityResolution() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.resolveInitialIslandVisibility()
        }
    }

    private func resolveInitialIslandVisibility() {
        guard !hasExplicitIslandVisibilityRequest, !AppSwitcher.shared.isSwitchInProgress else { return }
        guard let currentIsland = AppSwitcher.shared.currentIsland else {
            showIsland(preferMouseScreen: false, hidePeers: false)
            return
        }

        let otherInstalled = AppSwitcher.shared.otherIslandNames.contains { AppSwitcher.shared.isIslandInstalled(named: $0) }
        let preferredIsland = IslandIntegrationSettings.preferredStartupIsland(
            currentApp: currentIsland,
            otherAppInstalled: otherInstalled
        )
        let preferredVisible = AppSwitcher.shared.isIslandVisible(named: preferredIsland.rawValue)
        let shouldShow = IslandIntegrationSettings.shouldShowOnLaunch(
            currentApp: currentIsland,
            preferredApp: preferredIsland,
            preferredAppVisible: preferredVisible
        )

        guard shouldShow else { return }

        // 用文件锁原子仲裁：确保只有一个进程获得显示权
        let won = IslandIntegrationSettings.claimVisibility(
            currentApp: currentIsland,
            isInstalled: { app in
                AppSwitcher.shared.isIslandInstalled(named: app.rawValue)
            },
            isVisible: { app in
                AppSwitcher.shared.isIslandVisible(named: app.rawValue)
            }
        )
        guard won else { return }

        showIsland(preferMouseScreen: false, hidePeers: preferredIsland == currentIsland)
    }

    private func showIsland(preferMouseScreen: Bool, hidePeers: Bool) {
        guard let window = notchWindow else { return }
        hasExplicitIslandVisibilityRequest = true
        AppSwitcher.shared.cancelSwitch()

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
