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
        guard screenHeight.isFinite else { return maxExpandedHeight }
        let availableHeight = screenHeight - expandedPadding - windowTopExtension
        return max(1, min(maxExpandedHeight, availableHeight))
    }

    static func maximumExpandedContentWidth(forScreenWidth screenWidth: CGFloat) -> CGFloat {
        guard screenWidth.isFinite else { return maxExpandedWidth }
        return max(1, min(maxExpandedWidth, screenWidth - expandedPadding * 2))
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
    private(set) var isDragging = false {
        didSet { if oldValue != isDragging { synchronizeActivity() } }
    }
    private var dragTracking = false
    private var dragStartWindowX: CGFloat = 0
    private var dragStartMouseX: CGFloat = 0
    private let pointerLocation: () -> NSPoint
    private let defaults: UserDefaults
    private let markVisible: @MainActor () -> Void
    private let onExplicitShow: @MainActor () -> Void
    private let fullscreenProbe: (@Sendable () async -> Bool)?
    struct HandoffEnvironment {
        var reduceMotion: () -> Bool
        var schedule: (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void
        var orderFront: (NotchWindow) -> Void
        var orderOut: (NotchWindow) -> Void
    }
    private let handoffEnvironment: HandoffEnvironment
    private(set) var handoffState = IslandHandoffState()
    private var handoffPreparationHandler: (@MainActor (UInt64) -> Void)?
    private var handoffPrepared: (@MainActor (UInt64) -> Void)?
    private var cancelHandoffFrames: [() -> Void] = []
    private var visibilityGeneration: UInt64 = 0
    let activityState = PanelActivityState()
    private var isTornDown = false
    private var isClosed = false
    private lazy var mouseTracking = PanelMouseTrackingController { [weak self] in
        self?.followMouseIfScreenChanged()
    }
    private var lastActiveScreenID: CGDirectDisplayID?
    private var cachedBestScreen: NSScreen?

    /// 横滑切换手势识别器
    let swipeRecognizer = SwipeGestureRecognizer()
    /// 灵动岛当前状态（由 NotchContentView 同步）
    var islandState: IslandState = .collapsed
    /// 正在切换应用时临时禁用 activeSpaceDidChange 的自动显示
    var isSwitchingApps = false {
        didSet {
            if oldValue != isSwitchingApps { visibilityGeneration &+= 1 }
        }
    }
    /// 已让位给另一个灵动岛，收到显式显示命令前禁止自动显示
    var isHiddenByIslandSwitch = false {
        didSet {
            if oldValue != isHiddenByIslandSwitch { visibilityGeneration &+= 1 }
        }
    }
    /// 用户主动隐藏后，不应因桌面或全屏状态变化重新出现
    private(set) var isHiddenByUser = false
    private(set) var lastExplicitShowTime: TimeInterval = 0
    private(set) var hasPendingPanelReveal = false

    // MARK: - Init

    init(
        pointerLocation: @escaping () -> NSPoint = { NSEvent.mouseLocation },
        defaults: UserDefaults = .standard,
        markVisible: @escaping @MainActor () -> Void = {
            if let currentIsland = AppSwitcher.shared.currentIsland {
                IslandIntegrationSettings.markVisible(currentIsland)
            }
        },
        onExplicitShow: @escaping @MainActor () -> Void = { AppSwitcher.shared.cancelSwitch() },
        fullscreenProbe: (@Sendable () async -> Bool)? = nil,
        handoffEnvironment: HandoffEnvironment? = nil
    ) {
        self.pointerLocation = pointerLocation
        self.defaults = defaults
        self.markVisible = markVisible
        self.onExplicitShow = onExplicitShow
        self.fullscreenProbe = fullscreenProbe
        self.handoffEnvironment = handoffEnvironment ?? HandoffEnvironment(
            reduceMotion: {
                defaults.bool(forKey: "reduceMotion") || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            },
            schedule: { delay, action in
                let work = DispatchWorkItem { action() }
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
                return { work.cancel() }
            },
            orderFront: { $0.orderFrontRegardless() },
            orderOut: { $0.orderOut(nil) }
        )
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

        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(systemWillSleep),
            name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - Window Visibility

    override func orderFrontRegardless() {
        guard !isTornDown else { return }
        super.orderFrontRegardless()
        synchronizeActivity()
    }

    override func orderFront(_ sender: Any?) {
        guard !isTornDown else { return }
        super.orderFront(sender)
        synchronizeActivity()
    }

    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        synchronizeActivity()
    }

    override func close() {
        hasPendingPanelReveal = false
        isClosed = true
        visibilityGeneration &+= 1
        cancelHandoffPresentation()
        super.close()
        synchronizeActivity()
    }

    func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        close()
        mouseTracking.setActive(false)
    }

    private func synchronizeActivity() {
        activityState.setWindowVisible(isVisible && !isClosed && !isTornDown)
        mouseTracking.setActive(activityState.isActive && !isDragging)
    }

    @objc private func systemWillSleep(_ note: Notification) {
        visibilityGeneration &+= 1
        activityState.setSystemAwake(false)
        mouseTracking.setActive(false)
    }

    @objc private func systemDidWake(_ note: Notification) {
        guard !isTornDown else { return }
        activityState.setSystemAwake(true)
        synchronizeActivity()
    }

    func showWindow() {
        guard !isTornDown else { return }
        isClosed = false
        cancelHandoffPresentation()
        lastExplicitShowTime = Date().timeIntervalSince1970
        onExplicitShow()
        visibilityGeneration &+= 1
        isHiddenByIslandSwitch = false
        isHiddenByUser = false
        markVisible()
        orderFrontForPresentation()
    }
    func hideWindow() {
        hasPendingPanelReveal = false
        cancelHandoffPresentation()
        visibilityGeneration &+= 1
        isHiddenByUser = true
        handoffEnvironment.orderOut(self)
    }
    func hideWindowForIslandSwitch(animated: Bool = true) {
        hasPendingPanelReveal = false
        guard !isHiddenByIslandSwitch || handoffState.isFadingOut else { return }
        guard let generation = handoffState.beginFadeOut() else { return }
        cancelScheduledHandoffFrames()
        handoffPrepared = nil
        visibilityGeneration &+= 1
        isHiddenByIslandSwitch = true
        isSwitchingApps = true
        let duration = IslandHandoffState.outboundDuration(
            reduceMotion: !animated || handoffEnvironment.reduceMotion()
        )
        guard duration > 0 else {
            finishHandoffFade(generation: generation)
            return
        }
        let initialAlpha = alphaValue
        // 每帧检查代数，显式重新显示后迟到的动画既不能改 alpha，也不能 orderOut。
        for step in 1...8 {
            let progress = Double(step) / 8
            let cancel = handoffEnvironment.schedule(duration * progress) { [weak self] in
                guard let self, self.isCurrentHandoff(generation), self.handoffState.isFadingOut else { return }
                self.alphaValue = initialAlpha * (1 - progress)
                if step == 8 { self.finishHandoffFade(generation: generation) }
            }
            cancelHandoffFrames.append(cancel)
        }
    }
    func toggleVisibility() { isVisible ? hideWindow() : showWindow() }

    /// 隐藏窗口可能尚未建立 SwiftUI 订阅，保留快捷唤出意图直到宿主准备好。
    func requestPanelReveal() {
        guard !isTornDown else { return }
        hasPendingPanelReveal = true
        NotificationCenter.default.post(name: .xnookRevealPanel, object: self)
    }

    func consumePanelReveal() -> Bool {
        guard hasPendingPanelReveal, !isTornDown, !isHiddenByUser, !isHiddenByIslandSwitch else { return false }
        hasPendingPanelReveal = false
        return true
    }

    /// 在鼠标所在屏幕显示窗口（URL Scheme 唤醒时调用）
    func showAtMouseScreen() {
        cancelHandoffPresentation()
        presentAtMouseScreen()
    }

    private func presentAtMouseScreen(reposition: Bool = true) {
        guard !isTornDown else { return }
        isClosed = false
        alphaValue = 1
        lastExplicitShowTime = Date().timeIntervalSince1970
        onExplicitShow()
        visibilityGeneration &+= 1
        isHiddenByIslandSwitch = false
        isHiddenByUser = false
        markVisible()
        if reposition { positionAtMouseScreen() }
        orderFrontForPresentation()
    }

    private func orderFrontForPresentation() {
        handoffEnvironment.orderFront(self)
        NotificationCenter.default.post(name: .xnookWindowDidPresent, object: self)
    }

    private func positionAtMouseScreen() {
        let mouseLocation = pointerLocation()
        if let mouseScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) {
            repositionOnScreen(mouseScreen)
        }
    }

    @discardableResult
    func beginInboundHandoff(onPrepared: @escaping @MainActor (UInt64) -> Void) -> UInt64 {
        guard !isTornDown else { return handoffState.generation }
        hasPendingPanelReveal = false
        cancelScheduledHandoffFrames()
        let generation = handoffState.beginInbound()
        handoffPrepared = onPrepared
        visibilityGeneration &+= 1
        isHiddenByIslandSwitch = false
        isSwitchingApps = true
        swipeRecognizer.suppress(for: 0.8)
        handoffPreparationHandler?(generation)
        // 冷启动窗口尚未显示；强制建立 SwiftUI 树以安装准备处理器。
        contentView?.layoutSubtreeIfNeeded()
        return generation
    }

    func installHandoffPreparationHandler(_ handler: @escaping @MainActor (UInt64) -> Void) {
        handoffPreparationHandler = handler
        if let generation = handoffState.pendingPreparation { handler(generation) }
    }

    func removeHandoffPreparationHandler() { handoffPreparationHandler = nil }

    @discardableResult
    func completeInboundHandoffPreparation(generation: UInt64) -> Bool {
        guard isCurrentHandoff(generation), handoffState.pendingPreparation == generation else { return false }
        // 最终屏幕位置也属于准备阶段，布局期间的旧坐标不能解除 hover 门控。
        positionAtMouseScreen()
        contentView?.layoutSubtreeIfNeeded()
        guard handoffState.consumePreparation(generation) else { return false }
        let prepared = handoffPrepared
        handoffPrepared = nil
        prepared?(generation)
        return true
    }

    func showPreparedHandoff(generation: UInt64) {
        guard isCurrentHandoff(generation), handoffState.pendingPreparation == nil else { return }
        presentAtMouseScreen(reposition: false)
    }

    func isCurrentHandoff(_ generation: UInt64) -> Bool { handoffState.generation == generation }

    /// 取消准备后的内容只由普通重新显示恢复，不能覆盖新入站淡入或出站淡出。
    func canRestoreHandoffContent(after cancelledGeneration: UInt64) -> Bool {
        !isCurrentHandoff(cancelledGeneration)
            && handoffState.pendingPreparation == nil
            && !handoffState.isFadingOut
            && !isHiddenByIslandSwitch
            && !isHiddenByUser
    }

    func observeHandoffPointer(isInside: Bool) -> Bool {
        handoffState.observePointer(isInside: isInside)
    }

    private func cancelScheduledHandoffFrames() {
        cancelHandoffFrames.forEach { $0() }
        cancelHandoffFrames.removeAll()
    }

    private func cancelHandoffPresentation() {
        cancelScheduledHandoffFrames()
        handoffState.cancelPresentation()
        handoffPrepared = nil
        alphaValue = 1
        isSwitchingApps = false
    }

    private func finishHandoffFade(generation: UInt64) {
        guard handoffState.finishFadeOut(generation) else { return }
        cancelScheduledHandoffFrames()
        handoffEnvironment.orderOut(self)
        alphaValue = 1
        isSwitchingApps = false
    }

    func isFrontmostIslandWindow() -> Bool {
        IslandWindowOwnership.isFrontmostIslandWindow(
            self,
            bundleIdentifiers: ["com.meteorkid.xnook", "dev.xisland.app"]
        )
    }

    // MARK: - Screen Tracking

    private func followMouseIfScreenChanged() {
        guard activityState.isActive, !isDragging else { return }
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
        mouseTracking.setActive(false)
    }

    private func resumeMouseTracking() {
        mouseTracking.setActive(activityState.isActive && !isDragging)
    }

    private func repositionOnScreen(_ screen: NSScreen) {
        let currentFrame = frame
        let x: CGFloat
        if let cx = customX, cx.isFinite {
            let center = Self.mappedCenterX(cx, from: self.screen?.frame ?? screen.frame, to: screen.frame)
            customX = center
            x = max(screen.frame.origin.x,
                    min(center - currentFrame.width / 2,
                        screen.frame.origin.x + screen.frame.width - currentFrame.width))
        } else {
            x = screen.frame.origin.x + (screen.frame.width - currentFrame.width) / 2
        }
        let screenTop = screen.frame.origin.y + screen.frame.height - Self.islandTopOffset(for: screen)
        // 窗口向上延伸，使屏幕顶端在窗口内部
        let y = screenTop - currentFrame.height + Self.windowTopExtension
        let proposed = NSRect(x: x, y: y, width: currentFrame.width, height: currentFrame.height)
        let fitted = islandState == .expanded
            ? Self.fittingExpandedFrame(proposed, screenFrame: screen.frame, visibleFrame: screen.visibleFrame)
            : Self.safeFrame(proposed, screen: screen)
        setFrameDirect(fitted, display: true)
    }

    func applySpaceBehavior() {
        let allSpaces = defaults.bool(forKey: "showOnAllSpaces")
        if allSpaces {
            collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        } else {
            collectionBehavior = [.fullScreenAuxiliary, .stationary]
        }
    }

    @objc private func activeSpaceDidChange(_ note: Notification) {
        refreshFullscreenVisibility()
    }

    @discardableResult
    func refreshFullscreenVisibility() -> Task<Void, Never>? {
        // 新的桌面检查或显式显示意图都会淘汰之前的异步结果。
        visibilityGeneration &+= 1
        let generation = visibilityGeneration
        // 切换应用期间不自动显示窗口
        guard !isTornDown, !isClosed, activityState.isSystemAwake,
              !isSwitchingApps, !isHiddenByIslandSwitch else { return nil }

        let hideInFullscreen = defaults.bool(forKey: "hideInFullscreen")
        guard hideInFullscreen else {
            // 不再自动显示窗口——窗口只在明确命令时显示
            return nil
        }
        // 主线程：提取所有 NSScreen 属性为值类型（CGRect, NSWindow.StyleMask）
        let mainScreenFrame = NSScreen.main?.frame
        let windowSnapshots: [(screenFrame: CGRect?, styleMask: NSWindow.StyleMask)] =
            NSApplication.shared.windows.map { ($0.screen?.frame, $0.styleMask) }
        let frontApp = NSWorkspace.shared.frontmostApplication

        let fullscreenProbe = fullscreenProbe

        return Task { [weak self] in
            let inFullscreen: Bool
            if let fullscreenProbe {
                inFullscreen = await fullscreenProbe()
            } else {
                inFullscreen = await Task.detached(priority: .userInitiated) {
                    Self.isScreenInFullscreenOffMain(
                        mainScreenFrame: mainScreenFrame,
                        windowSnapshots: windowSnapshots,
                        frontApp: frontApp
                    )
                }.value
            }
            guard let self else { return }
            guard self.visibilityGeneration == generation,
                  self.defaults.bool(forKey: "hideInFullscreen"),
                  !self.isSwitchingApps, !self.isHiddenByIslandSwitch else { return }
            if inFullscreen {
                self.pauseMouseTracking()
                self.orderOut(nil)
            } else if !self.isHiddenByUser {
                self.resumeMouseTracking()
                self.orderFrontRegardless()
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
        let proposed = NSRect(x: x, y: yComputed, width: w, height: h)
        let rect = islandState == .expanded
            ? Self.fittingExpandedFrame(proposed, screenFrame: screen.frame, visibleFrame: screen.visibleFrame)
            : Self.safeFrame(proposed, screen: screen)
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

    /// 屏幕坐标可能为负；按相对横向位置映射，不能缩放全局坐标。
    static func mappedCenterX(_ center: CGFloat, from source: CGRect, to target: CGRect) -> CGFloat {
        guard center.isFinite, source.width.isFinite, source.width > 0 else { return target.midX }
        guard source != target else { return center }
        let fraction = min(1, max(0, (center - source.minX) / source.width))
        return target.minX + fraction * target.width
    }

    /// 顶部仍贴屏幕边缘，横向和底部让开 Dock；跨屏时先限窗，再由内容重新测量。
    static func fittingExpandedFrame(_ proposed: CGRect, screenFrame: CGRect, visibleFrame: CGRect) -> CGRect {
        let width = min(max(1, proposed.width.isFinite ? proposed.width : 1), max(1, visibleFrame.width))
        let height = min(max(1, proposed.height.isFinite ? proposed.height : 1), max(1, visibleFrame.height))
        let preferredX = proposed.origin.x.isFinite ? proposed.origin.x : screenFrame.midX - width / 2
        let x = min(max(visibleFrame.minX, preferredX), visibleFrame.maxX - width)
        return CGRect(x: x, y: screenFrame.maxY + windowTopExtension - height, width: width, height: height)
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
        let currentScreen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey(rawValue: "NSScreenNumber")] as? CGDirectDisplayID)
                == lastActiveScreenID
        }
        guard let updated = currentScreen ?? Self.bestScreen() else { return }
        cachedBestScreen = updated
        lastActiveScreenID = updated.deviceDescription[NSDeviceDescriptionKey(rawValue: "NSScreenNumber")] as? CGDirectDisplayID
        repositionOnScreen(updated)
    }

    private static func padding(forContentHeight contentHeight: CGFloat) -> CGFloat {
        contentHeight <= collapsedHitHeight + 0.5 ? 0 : expandedPadding
    }

    // MARK: - Drag

    override func sendEvent(_ event: NSEvent) {
        // 展开后的拖选和拖放属于内容控件，不能被药丸拖窗手势抢走。
        guard islandState == .collapsed else {
            dragTracking = false
            isDragging = false
            super.sendEvent(event)
            return
        }
        switch event.type {
        case .leftMouseDown:
            dragStartMouseX = pointerLocation().x
            dragStartWindowX = frame.origin.x
            dragTracking = true
            isDragging = false
            super.sendEvent(event)

        case .leftMouseDragged where dragTracking:
            let currentX = pointerLocation().x
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
