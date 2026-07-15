import AppKit
import QuartzCore

@MainActor
final class NotchWindow: NSPanel {
    static let maxExpandedWidth: CGFloat = 1_600
    static let maxExpandedHeight: CGFloat = 900
    private static let defaultWidth: CGFloat = 220
    private static let defaultHeight: CGFloat = 50

    private static let expandedPadding: CGFloat = 8
    private static let collapsedHitHeight: CGFloat = 32
    /// 双指下滑展开的最小滚动距离，过滤触控板惯性残余
    static let scrollExpandMinDelta: CGFloat = 2

    static func islandTopOffset(for _: NSScreen) -> CGFloat { 0 }

    /// 窗口向上延伸的像素数，使屏幕顶端在窗口内部而非边缘
    /// 避免 setFrame 偏差或抗锯齿导致顶部出现 1px 缝隙；内容顶部 padding 会覆盖此越界量，可见区无空隙
    /// 4px 已足够覆盖 setFrame 偏差与抗锯齿，同时减少内容空间浪费
    static let windowTopExtension: CGFloat = 4

    /// 展开面板可见高度上限，保留窗口边距并避免超出当前屏幕。
    static func maximumExpandedContentHeight(for screen: NSScreen? = NSScreen.main) -> CGFloat {
        let screenHeight = screen?.visibleFrame.height ?? maxExpandedHeight
        return maximumExpandedContentHeight(forScreenHeight: screenHeight)
    }

    static func maximumExpandedContentHeight(forScreenHeight screenHeight: CGFloat) -> CGFloat {
        let availableHeight = screenHeight - expandedPadding - windowTopExtension
        return max(160, min(maxExpandedHeight, availableHeight))
    }

    static func maximumExpandedContentWidth(forScreenWidth screenWidth: CGFloat) -> CGFloat {
        max(160, min(maxExpandedWidth, screenWidth - expandedPadding * 2))
    }

    func maximumExpandedContentSize() -> CGSize {
        let screen = cachedOrRefreshScreen()
        let width = screen.map { Self.maximumExpandedContentWidth(forScreenWidth: $0.visibleFrame.width) }
            ?? Self.maxExpandedWidth
        let height = screen.map { Self.maximumExpandedContentHeight(for: $0) }
            ?? Self.maxExpandedHeight
        return CGSize(width: width, height: height)
    }

    func isObscuredByPhysicalNotch() -> Bool {
        guard let screen = self.screen else { return false }
        if #available(macOS 14.0, *) {
            guard screen.safeAreaInsets.top > 0 else { return false }
        } else {
            return false
        }
        let sf = screen.frame
        let wf = frame
        let topAligned = abs(wf.maxY - sf.maxY) < 4
        let inCenterBand = abs(wf.midX - sf.midX) < sf.width * 0.22
        return topAligned && inCenterBand
    }

    var customX: CGFloat?
    var keyEquivalentHandler: ((NSEvent) -> Bool)?
    private(set) var isDragging = false
    private var dragTracking = false
    private var dragStartWindowX: CGFloat = 0
    private var dragStartMouseX: CGFloat = 0
    private var mouseTrackingTimer: Timer?
    private var lastActiveScreenID: CGDirectDisplayID?
    private var cachedBestScreen: NSScreen?

    /// 横滑切换手势识别器
    let swipeRecognizer = SwipeGestureRecognizer()
    /// 灵动岛当前状态（由 NotchContentView 同步）
    var islandState: IslandState = .collapsed
    /// 正在切换应用时临时禁用 activeSpaceDidChange 的自动显示
    var isSwitchingApps = false
    /// 已让位给另一个灵动岛，收到显式显示命令前禁止自动显示
    var isHiddenByIslandSwitch = false
    /// 用户主动隐藏后，不应因桌面或全屏状态变化重新出现
    private(set) var isHiddenByUser = false

    // MARK: - Init

    init() {
        let width = Self.defaultWidth
        let height = Self.defaultHeight
        let initialFrame: NSRect
        if let screen = Self.bestScreen() {
            initialFrame = Self.dockedFrame(on: screen, width: width, height: height)
        } else {
            initialFrame = Self.fallbackFrame(width: width, height: height)
        }

        super.init(
            contentRect: initialFrame,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .statusBar + 2
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = false
        isMovableByWindowBackground = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        animationBehavior = .none
        isReleasedWhenClosed = false
        isRestorable = false
        setFrameAutosaveName("")

        if let screen = Self.bestScreen() {
            cachedBestScreen = screen
            lastActiveScreenID = screen.deviceDescription[
                NSDeviceDescriptionKey(rawValue: "NSScreenNumber")
            ] as? CGDirectDisplayID
        }

        applySpaceBehavior()

        contentView = FlippedView(frame: .zero)
        contentView?.wantsLayer = true
        contentView?.layer?.backgroundColor = .clear

        NotificationCenter.default.addObserver(
            self, selector: #selector(screenDidChange),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(activeSpaceDidChange),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil
        )

        mouseTrackingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.followMouseIfScreenChanged()
            }
        }
    }

    deinit {
        mouseTrackingTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - Window Visibility

    func showWindow() {
        isHiddenByIslandSwitch = false
        isHiddenByUser = false
        if let currentIsland = AppSwitcher.shared.currentIsland {
            IslandIntegrationSettings.markVisible(currentIsland)
        }
        orderFrontRegardless()
    }
    func hideWindow() {
        isHiddenByUser = true
        orderOut(nil)
    }
    func toggleVisibility() { isVisible ? hideWindow() : showWindow() }

    /// 在鼠标所在屏幕显示窗口（URL Scheme 唤醒时调用）
    func showAtMouseScreen() {
        isHiddenByIslandSwitch = false
        if let currentIsland = AppSwitcher.shared.currentIsland {
            IslandIntegrationSettings.markVisible(currentIsland)
        }
        let mouseLocation = NSEvent.mouseLocation
        guard let mouseScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) else {
            orderFrontRegardless()
            return
        }
        repositionOnScreen(mouseScreen)
        orderFrontRegardless()
    }

    func isFrontmostIslandWindow() -> Bool {
        IslandWindowOwnership.isFrontmostIslandWindow(
            self,
            bundleIdentifiers: ["com.meteorkid.xnook", "dev.xisland.app"]
        )
    }

    // MARK: - Screen Tracking

    private func followMouseIfScreenChanged() {
        let mouseLocation = NSEvent.mouseLocation
        guard let mouseScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }),
              let screenID = mouseScreen.deviceDescription[NSDeviceDescriptionKey(rawValue: "NSScreenNumber")] as? CGDirectDisplayID
        else { return }

        if screenID != lastActiveScreenID {
            lastActiveScreenID = screenID
            cachedBestScreen = mouseScreen
            guard !dragTracking else { return }
            repositionOnScreen(mouseScreen)
        }
    }

    private func pauseMouseTracking() {
        mouseTrackingTimer?.invalidate()
        mouseTrackingTimer = nil
    }

    private func resumeMouseTracking() {
        guard mouseTrackingTimer == nil else { return }
        mouseTrackingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.followMouseIfScreenChanged()
            }
        }
    }

    private func repositionOnScreen(_ screen: NSScreen) {
        let currentFrame = frame
        let x: CGFloat
        if let cx = customX, cx.isFinite {
            let ratio = screen.frame.width / (self.screen?.frame.width ?? screen.frame.width)
            x = max(screen.frame.origin.x,
                    min(cx * ratio - currentFrame.width / 2,
                        screen.frame.origin.x + screen.frame.width - currentFrame.width))
        } else {
            x = screen.frame.origin.x + (screen.frame.width - currentFrame.width) / 2
        }
        let screenTop = screen.frame.origin.y + screen.frame.height - Self.islandTopOffset(for: screen)
        // 窗口向上延伸，使屏幕顶端在窗口内部
        let y = screenTop - currentFrame.height + Self.windowTopExtension
        setFrameDirect(NSRect(x: x, y: y, width: currentFrame.width, height: currentFrame.height), display: true)
    }

    func applySpaceBehavior() {
        let allSpaces = UserDefaults.standard.bool(forKey: "showOnAllSpaces")
        if allSpaces {
            collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        } else {
            collectionBehavior = [.fullScreenAuxiliary, .stationary]
        }
    }

    @objc private func activeSpaceDidChange(_ note: Notification) {
        // 切换应用期间不自动显示窗口
        guard !isSwitchingApps, !isHiddenByIslandSwitch else { return }

        let hideInFullscreen = UserDefaults.standard.bool(forKey: "hideInFullscreen")
        guard hideInFullscreen else {
            // 不再自动显示窗口——窗口只在明确命令时显示
            return
        }
        // 主线程：提取所有 NSScreen 属性为值类型（CGRect, NSWindow.StyleMask）
        let mainScreenFrame = NSScreen.main?.frame
        let windowSnapshots: [(screenFrame: CGRect?, styleMask: NSWindow.StyleMask)] =
            NSApplication.shared.windows.map { ($0.screen?.frame, $0.styleMask) }
        let frontApp = NSWorkspace.shared.frontmostApplication

        // 捕获标志值为局部常量，避免异步 Task 中的竞争条件
        let wasSwitchingApps = isSwitchingApps
        let wasHiddenByIslandSwitch = isHiddenByIslandSwitch

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let inFullscreen = Self.isScreenInFullscreenOffMain(
                mainScreenFrame: mainScreenFrame,
                windowSnapshots: windowSnapshots,
                frontApp: frontApp
            )
            await MainActor.run {
                // 使用捕获时的标志值，而非重新读取（避免竞争）
                guard !wasSwitchingApps, !wasHiddenByIslandSwitch else { return }
                guard !self.isSwitchingApps, !self.isHiddenByIslandSwitch else { return }
                if inFullscreen {
                    self.pauseMouseTracking()
                    self.orderOut(nil)
                } else if !self.isHiddenByUser {
                    self.resumeMouseTracking()
                    self.orderFrontRegardless()
                }
            }
        }
    }

    /// 后台线程安全：仅使用值类型（CGRect），不引用 NSScreen 对象
    private nonisolated static func isScreenInFullscreenOffMain(
        mainScreenFrame: CGRect?,
        windowSnapshots: [(screenFrame: CGRect?, styleMask: NSWindow.StyleMask)],
        frontApp: NSRunningApplication?
    ) -> Bool {
        guard let mainScreenFrame else { return false }
        // 检查是否有全屏窗口在主屏幕上（通过 frame origin 判断同一屏幕）
        for (winFrame, styleMask) in windowSnapshots {
            if styleMask.contains(.fullScreen),
               let winFrame,
               winFrame.origin == mainScreenFrame.origin {
                return true
            }
        }
        // 检查前台应用窗口是否覆盖整个屏幕
        if let frontApp,
           frontApp.bundleIdentifier != Bundle.main.bundleIdentifier {
            let opts = CGWindowListOption([.optionOnScreenOnly, .excludeDesktopElements])
            guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
                return false
            }
            for info in list {
                if let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                   pid == frontApp.processIdentifier,
                   let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                   let w = bounds["Width"], let h = bounds["Height"],
                   w >= mainScreenFrame.width && h >= mainScreenFrame.height {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Frame Management

    func resizeToFit(contentWidth: CGFloat, contentHeight: CGFloat, display: Bool = true) {
        let normalizedContentHeight = max(contentHeight, Self.collapsedHitHeight)
        let padding = Self.padding(forContentHeight: normalizedContentHeight)
        let w = contentWidth + padding * 2
        // 向上延伸窗口，使屏幕顶端在窗口内部
        let h = normalizedContentHeight + padding + Self.windowTopExtension
        guard let screen = cachedOrRefreshScreen() else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            setFrameDirect(
                NSRect(
                    x: frame.origin.x,
                    y: frame.origin.y,
                    width: w,
                    height: h
                ),
                display: display
            )
            CATransaction.commit()
            return
        }
        let x: CGFloat
        if let cx = customX, cx.isFinite {
            x = max(screen.frame.origin.x,
                    min(cx - w / 2, screen.frame.origin.x + screen.frame.width - w))
        } else {
            x = screen.frame.origin.x + (screen.frame.width - w) / 2
        }
        let screenTop = screen.frame.origin.y + screen.frame.height - Self.islandTopOffset(for: screen)
        // 窗口向上延伸 windowTopExtension，使屏幕顶端在窗口内部
        let yComputed = screenTop - h + Self.windowTopExtension
        let rect = Self.safeFrame(NSRect(x: x, y: yComputed, width: w, height: h), screen: screen)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        setFrameDirect(rect, display: display)
        CATransaction.commit()
    }

    func resizeToFitCollapse(contentWidth: CGFloat, contentHeight: CGFloat) {
        let targetW = max(1, contentWidth.isFinite ? contentWidth : 180)
        // 向上延伸窗口
        let targetH = max(contentHeight, Self.collapsedHitHeight) + Self.windowTopExtension
        guard let screen = cachedOrRefreshScreen() else {
            isDragging = false
            dragTracking = false
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            setFrameDirect(
                NSRect(
                    x: frame.origin.x,
                    y: frame.origin.y,
                    width: targetW,
                    height: targetH
                ),
                display: true
            )
            CATransaction.commit()
            return
        }
        let targetX: CGFloat
        if let cx = customX, cx.isFinite {
            targetX = max(screen.frame.origin.x,
                          min(cx - targetW / 2, screen.frame.origin.x + screen.frame.width - targetW))
        } else {
            targetX = screen.frame.origin.x + (screen.frame.width - targetW) / 2
        }
        let screenTop = screen.frame.origin.y + screen.frame.height - Self.islandTopOffset(for: screen)
        let targetY = screenTop - targetH + Self.windowTopExtension

        isDragging = false
        dragTracking = false

        let target = Self.safeFrame(
            NSRect(x: targetX, y: targetY, width: targetW, height: targetH),
            screen: screen
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        setFrameDirect(target, display: true)
        CATransaction.commit()
    }

    private static func safeFrame(_ rect: NSRect, screen: NSScreen) -> NSRect {
        let sf = screen.frame
        let minW: CGFloat = 1
        let minH = collapsedHitHeight
        var w = rect.width
        var h = rect.height
        var x = rect.origin.x
        var y = rect.origin.y
        if !w.isFinite || w < minW { w = minW }
        if !h.isFinite || h < minH { h = minH }
        if !x.isFinite { x = sf.midX - w / 2 }
        if !y.isFinite { y = sf.maxY - h }
        w = min(w, max(minW, sf.width))
        h = min(h, max(minH, sf.height))
        x = max(sf.minX, min(x, sf.maxX - w))
        // 允许窗口向上延伸 windowTopExtension 像素（超出屏幕顶端）
        y = max(sf.minY, min(y, sf.maxY - h + Self.windowTopExtension))
        return NSRect(x: x, y: y, width: w, height: h)
    }

    private static func dockedFrame(on screen: NSScreen, width: CGFloat, height: CGFloat) -> NSRect {
        let x = screen.frame.origin.x + (screen.frame.width - width) / 2
        let y = screen.frame.origin.y + screen.frame.height - Self.islandTopOffset(for: screen) - height
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private static func fallbackFrame(width: CGFloat, height: CGFloat) -> NSRect {
        NSRect(
            x: 0,
            y: 0,
            width: max(1, width),
            height: max(collapsedHitHeight, height)
        )
    }

    static func bestScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        if let mouseScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) {
            return mouseScreen
        }
        if let builtIn = NSScreen.screens.first(where: {
            $0.deviceDescription[NSDeviceDescriptionKey(rawValue: "NSScreenNumber")]
                as? CGDirectDisplayID == CGMainDisplayID()
        }) {
            return builtIn
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private func cachedOrRefreshScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        let mouseScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
        if let mouseScreen {
            let screenID = mouseScreen.deviceDescription[NSDeviceDescriptionKey(rawValue: "NSScreenNumber")] as? CGDirectDisplayID
            if screenID == lastActiveScreenID, let cached = cachedBestScreen {
                return cached
            }
            lastActiveScreenID = screenID
            cachedBestScreen = mouseScreen
            return mouseScreen
        }
        return cachedBestScreen ?? screen ?? Self.bestScreen()
    }

    static func screenHasPhysicalNotch(_ screen: NSScreen) -> Bool {
        if #available(macOS 14.0, *) {
            return screen.safeAreaInsets.top > 0
        }
        return false
    }

    @objc private func screenDidChange(_ note: Notification) {
        guard let screen = Self.bestScreen() else { return }
        let x: CGFloat
        if let cx = customX {
            x = max(screen.frame.origin.x,
                    min(cx - frame.width / 2, screen.frame.origin.x + screen.frame.width - frame.width))
        } else {
            x = screen.frame.origin.x + (screen.frame.width - frame.width) / 2
        }
        let screenTop = screen.frame.origin.y + screen.frame.height - Self.islandTopOffset(for: screen)
        // 窗口向上延伸
        let y = screenTop - frame.height + Self.windowTopExtension
        setFrameDirect(NSRect(x: x, y: y, width: frame.width, height: frame.height), display: true)
    }

    private static func padding(forContentHeight contentHeight: CGFloat) -> CGFloat {
        contentHeight <= collapsedHitHeight + 0.5 ? 0 : expandedPadding
    }

    // MARK: - Drag

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            dragStartMouseX = NSEvent.mouseLocation.x
            dragStartWindowX = frame.origin.x
            dragTracking = true
            isDragging = false
            super.sendEvent(event)

        case .leftMouseDragged where dragTracking:
            let currentX = NSEvent.mouseLocation.x
            let dx = currentX - dragStartMouseX
            if !isDragging && abs(dx) > 4 {
                isDragging = true
            }
            if isDragging {
                guard let screen = cachedOrRefreshScreen() else {
                    super.sendEvent(event)
                    return
                }
                let newX = max(screen.frame.origin.x,
                               min(dragStartWindowX + dx,
                                   screen.frame.origin.x + screen.frame.width - frame.width))
                let topY = screen.frame.origin.y + screen.frame.height - Self.islandTopOffset(for: screen) - frame.height + Self.windowTopExtension
                setFrameDirect(NSRect(x: newX, y: topY, width: frame.width, height: frame.height))
            } else {
                super.sendEvent(event)
            }

        case .leftMouseUp where dragTracking:
            dragTracking = false
            if isDragging {
                customX = frame.origin.x + frame.width / 2
                isDragging = false
            } else {
                super.sendEvent(event)
            }

        case .scrollWheel:
            // 横滑切换手势（仅收起状态响应）
            if islandState == .collapsed {
                let result = swipeRecognizer.handleScroll(event: event)
                if case .triggered(_) = result {
                    AppSwitcher.shared.switchToNextIsland()
                    return
                }
            }
            // 触控板双指下滑展开面板（由 AppDelegate 的全局监听器处理）
            super.sendEvent(event)

        default:
            super.sendEvent(event)
        }
    }

    func setFrameDirect(_ rect: NSRect, display: Bool = true) {
        let normalizedRect = NSRect(
            x: rect.origin.x,
            y: rect.origin.y,
            width: rect.width,
            height: max(rect.height, Self.collapsedHitHeight)
        )
        let normalized: NSRect
        if let screen = cachedOrRefreshScreen() {
            normalized = Self.safeFrame(
                normalizedRect,
                screen: screen
            )
        } else {
            normalized = normalizedRect
        }
        super.setFrame(normalized, display: display)
    }

    // MARK: - Window Properties

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let handler = keyEquivalentHandler, handler(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - FlippedView

private class FlippedView: NSView {
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func scrollWheel(with event: NSEvent) {
        let scrollEnabled = UserDefaults.standard.bool(forKey: "scrollDownToExpandPanel")
        if scrollEnabled, event.hasPreciseScrollingDeltas {
            let physicalDeltaY = event.isDirectionInvertedFromDevice
                ? event.scrollingDeltaY
                : -event.scrollingDeltaY
            if physicalDeltaY > NotchWindow.scrollExpandMinDelta {
                NotificationCenter.default.post(name: .xnookScrollDown, object: nil)
            }
        }
        super.scrollWheel(with: event)
    }
}
