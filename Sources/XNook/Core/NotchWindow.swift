import AppKit
import QuartzCore

final class NotchWindow: NSPanel {
    static let maxExpandedWidth: CGFloat = 520
    static let maxExpandedHeight: CGFloat = 600

    private static let expandedPadding: CGFloat = 8
    private static let collapsedHitHeight: CGFloat = 32
    /// 双指下滑展开的最小滚动距离，过滤触控板惯性残余
    private static let scrollExpandMinDelta: CGFloat = 2

    static func islandTopOffset(for _: NSScreen) -> CGFloat { 0 }

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

    // MARK: - Init

    init() {
        let screen = Self.bestScreen()
        let width: CGFloat = 220
        let height: CGFloat = 50
        let x = screen.frame.origin.x + (screen.frame.width - width) / 2
        let y = screen.frame.origin.y + screen.frame.height - Self.islandTopOffset(for: screen) - height

        super.init(
            contentRect: NSRect(x: x, y: y, width: width, height: height),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .statusBar + 1
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
            self?.followMouseIfScreenChanged()
        }
    }

    deinit {
        mouseTrackingTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - Window Visibility

    func showWindow() { orderFrontRegardless() }
    func hideWindow() { orderOut(nil) }
    func toggleVisibility() { isVisible ? hideWindow() : showWindow() }

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
            self?.followMouseIfScreenChanged()
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
        let y = screenTop - currentFrame.height
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
        let hideInFullscreen = UserDefaults.standard.bool(forKey: "hideInFullscreen")
        guard hideInFullscreen else {
            if !isVisible {
                resumeMouseTracking()
                orderFrontRegardless()
            }
            return
        }
        // 主线程：提取所有 NSScreen 属性为值类型（CGRect, NSWindow.StyleMask）
        let mainScreenFrame = NSScreen.main?.frame
        let windowSnapshots: [(screenFrame: CGRect?, styleMask: NSWindow.StyleMask)] =
            NSApplication.shared.windows.map { ($0.screen?.frame, $0.styleMask) }
        let frontApp = NSWorkspace.shared.frontmostApplication

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let inFullscreen = Self.isScreenInFullscreenOffMain(
                mainScreenFrame: mainScreenFrame,
                windowSnapshots: windowSnapshots,
                frontApp: frontApp
            )
            await MainActor.run {
                if inFullscreen {
                    self.pauseMouseTracking()
                    self.orderOut(nil)
                } else {
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
        let screen = cachedOrRefreshScreen()
        let normalizedContentHeight = max(contentHeight, Self.collapsedHitHeight)
        let padding = Self.padding(forContentHeight: normalizedContentHeight)
        let w = contentWidth + padding * 2
        let h = normalizedContentHeight + padding
        let x: CGFloat
        if let cx = customX, cx.isFinite {
            x = max(screen.frame.origin.x,
                    min(cx - w / 2, screen.frame.origin.x + screen.frame.width - w))
        } else {
            x = screen.frame.origin.x + (screen.frame.width - w) / 2
        }
        let screenTop = screen.frame.origin.y + screen.frame.height - Self.islandTopOffset(for: screen)
        let yComputed = screenTop - h
        let rect = Self.safeFrame(NSRect(x: x, y: yComputed, width: w, height: h), screen: screen)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        setFrameDirect(rect, display: display)
        CATransaction.commit()
    }

    func resizeToFitCollapse(contentWidth: CGFloat, contentHeight: CGFloat) {
        let screen = cachedOrRefreshScreen()
        let targetW = max(1, contentWidth.isFinite ? contentWidth : 180)
        let targetH = max(contentHeight, Self.collapsedHitHeight)
        let targetX: CGFloat
        if let cx = customX, cx.isFinite {
            targetX = max(screen.frame.origin.x,
                          min(cx - targetW / 2, screen.frame.origin.x + screen.frame.width - targetW))
        } else {
            targetX = screen.frame.origin.x + (screen.frame.width - targetW) / 2
        }
        let screenTop = screen.frame.origin.y + screen.frame.height - Self.islandTopOffset(for: screen)
        let targetY = screenTop - targetH

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
        y = max(sf.minY, min(y, sf.maxY - h))
        return NSRect(x: x, y: y, width: w, height: h)
    }

    static func bestScreen() -> NSScreen {
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
        return NSScreen.main ?? NSScreen.screens.first!
    }

    private func cachedOrRefreshScreen() -> NSScreen {
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
        return cachedBestScreen ?? Self.bestScreen()
    }

    static func screenHasPhysicalNotch(_ screen: NSScreen) -> Bool {
        if #available(macOS 14.0, *) {
            return screen.safeAreaInsets.top > 0
        }
        return false
    }

    @objc private func screenDidChange(_ note: Notification) {
        let screen = Self.bestScreen()
        let x: CGFloat
        if let cx = customX {
            x = max(screen.frame.origin.x,
                    min(cx - frame.width / 2, screen.frame.origin.x + screen.frame.width - frame.width))
        } else {
            x = screen.frame.origin.x + (screen.frame.width - frame.width) / 2
        }
        let screenTop = screen.frame.origin.y + screen.frame.height - Self.islandTopOffset(for: screen)
        let y = screenTop - frame.height
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
                let screen = cachedOrRefreshScreen()
                let newX = max(screen.frame.origin.x,
                               min(dragStartWindowX + dx,
                                   screen.frame.origin.x + screen.frame.width - frame.width))
                let topY = screen.frame.origin.y + screen.frame.height - Self.islandTopOffset(for: screen) - frame.height
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
            // 触控板双指下滑展开面板
            let scrollEnabled = UserDefaults.standard.bool(forKey: "scrollDownToExpandPanel")
            if scrollEnabled,
               event.hasPreciseScrollingDeltas,
               event.scrollingDeltaY > Self.scrollExpandMinDelta {
                NotificationCenter.default.post(name: .xnookScrollDown, object: nil)
            }
            super.sendEvent(event)

        default:
            super.sendEvent(event)
        }
    }

    func setFrameDirect(_ rect: NSRect, display: Bool = true) {
        let screen = cachedOrRefreshScreen()
        let normalized = Self.safeFrame(
            NSRect(
                x: rect.origin.x,
                y: rect.origin.y,
                width: rect.width,
                height: max(rect.height, Self.collapsedHitHeight)
            ),
            screen: screen
        )
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
}
