import SwiftUI
import EventKit

/// 灵动岛状态
enum IslandState: Equatable {
    case collapsed
    case expanded
}

/// Notch 主内容视图 - 与 X Island 保持一致的灵动岛风格
struct NotchContentView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var mediaManager = MediaManager()
    @State private var calendarManager = CalendarManager()
    @State private var notesManager = NotesManager()
    @State private var trayManager = TrayManager()
    @State private var focusSessionManager = FocusSessionManager()

    @State private var state: IslandState = .collapsed
    @State private var showContent = false
    @State private var cachedExpandedShapeHeight: CGFloat = 220
    @State private var selectedWidget: WidgetType?
    @State private var hoverTimer: Timer?
    @State private var hoverPollingFast = false
    @State private var lastCollapseAt: Date = .distantPast
    @State private var collapseAnimating = false
    @State private var collapseGeneration = 0
    @State private var expandedByHover = false
    @State private var expandedAt: Date = .distantPast
    @State private var expandPending = false
    @State private var calendarRecenterTrigger = 0
    @State private var terminateObserver: NSObjectProtocol?
    /// 缓存 NotchWindow 引用，避免每次事件都全局查找
    @State private var notchWindow: NotchWindow?

    // 鼠标进入动效
    @State private var isHoveringPill = false
    @State private var jellyTrigger = false
    @State private var jellySettled = false
    @State private var previousMouseY: CGFloat = 0
    @State private var wasPointerInsidePillHitFrame = false

    // 防止快速晃动鼠标导致果冻动画错乱
    @State private var jellyGeneration: UInt = 0

    // 吸附效果
    @State private var magneticOffset: CGSize = .zero
    private static let magneticMaxOffset: CGFloat = 8
    private static let magneticRange: CGFloat = 80

    /// 透明光标：推入后隐藏系统光标
    private static let invisibleCursor: NSCursor = {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.clear.set()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return NSCursor(image: image, hotSpot: .zero)
    }()

    @AppStorage("panelWidth") private var panelWidth = SettingsDefaults.double(for: "panelWidth")
    @AppStorage("panelMaxHeight") private var panelMaxHeight = SettingsDefaults.double(for: "panelMaxHeight")
    @AppStorage("jellyIntensity") private var jellyIntensity = SettingsDefaults.string(for: "jellyIntensity", fallback: "medium")

    /// 根据强度设置返回果冻缩放值
    private var jellyScale: (xPop: CGFloat, xSettle: CGFloat, yPop: CGFloat, ySettle: CGFloat) {
        switch jellyIntensity {
        case "weak":   return (0.97, 0.99, 1.10, 1.03)
        case "strong": return (0.90, 0.96, 1.40, 1.12)
        default:       return (0.94, 0.98, 1.25, 1.08) // medium
        }
    }
    @AppStorage("expandedInactivityAutoHideDelay") private var expandedInactivityAutoHideDelay = SettingsDefaults.double(for: "expandedInactivityAutoHideDelay")
    @AppStorage("hoverExitCollapseDelay") private var hoverExitCollapseDelay = SettingsDefaults.double(for: "hoverExitCollapseDelay")
    @AppStorage("hoverToExpandPanel") private var hoverToExpandPanel = SettingsDefaults.bool(for: "hoverToExpandPanel")
    @AppStorage("reduceMotion") private var reduceMotion = SettingsDefaults.bool(for: "reduceMotion")
    @AppStorage("showTickerLine") private var showTickerLine = SettingsDefaults.bool(for: "showTickerLine", fallback: true)
    @AppStorage("showLyrics") private var showLyrics = SettingsDefaults.bool(for: "showLyrics")
    @AppStorage("tickerSpeed") private var tickerSpeed = SettingsDefaults.double(for: "tickerSpeed")
    @State private var cachedGifData: Data?
    @State private var islandObscuredByNotch = false

    private var onSizeChange: ((CGFloat, CGFloat) -> Void)?

    init(onSizeChange: ((CGFloat, CGFloat) -> Void)? = nil) {
        self.onSizeChange = onSizeChange
    }

    enum WidgetType: String, CaseIterable {
        case media
        case calendar
        case notes
        case tray

        var localizedName: String {
            switch self {
            case .media: return L10n.widgetMedia
            case .calendar: return L10n.widgetCalendar
            case .notes: return L10n.widgetNotes
            case .tray: return L10n.widgetTray
            }
        }

        /// 从 UserDefaults 读取已启用的 Widget 列表
        static var enabledWidgets: [WidgetType] {
            if let data = UserDefaults.standard.data(forKey: "enabledWidgets"),
               let enabled = try? JSONDecoder().decode(Set<String>.self, from: data) {
                return allCases.filter { enabled.contains($0.rawValue) }
            }
            // 默认全部启用
            return allCases
        }
    }

    // MARK: - 尺寸计算

    /// 收起高度：开启歌词时使用带歌词的高度，否则使用默认高度
    private var collapsedShapeHeight: CGFloat {
        showLyrics && showTicker
            ? IslandSizeCalculator.collapsedShapeHeightWithLyrics
            : IslandSizeCalculator.collapsedShapeHeight
    }

    /// Ticker 行高度
    private let tickerLineHeight: CGFloat = 18

    /// 是否显示 Ticker（播放中 + 曲目信息或歌词任一开启 + 收起状态）
    private var showTicker: Bool {
        mediaManager.isPlaying && (showTickerLine || showLyrics) && !isExpanded
    }

    /// 收起状态总高度（含 Ticker）
    private var collapsedTotalHeight: CGFloat {
        collapsedShapeHeight + (showTicker ? tickerLineHeight + 4 : 0)
    }

    private var isExpanded: Bool { state == .expanded }

    /// NookFlow 区域是否应显示（有活跃会话或有历史记录）
    private var isFocusSessionVisible: Bool {
        focusSessionManager.activeSession != nil || !focusSessionManager.history.isEmpty
    }

    /// NookFlow 区域集中计算的高度来源 — expandedHeight / targetSize / cachedExpandedShapeHeight 统一使用
    /// 活跃会话：卡片高度；仅历史记录：列表高度；否则 0
    private var focusSessionCardHeight: CGFloat {
        guard isFocusSessionVisible else { return 0 }
        return focusSessionManager.activeSession != nil ? Self.activeSessionCardHeight : Self.historyListHeight
    }

    /// 活跃任务卡片估计高度
    private static let activeSessionCardHeight: CGFloat = 96
    /// 历史记录列表估计高度（标题 + 最多 3 条）
    private static let historyListHeight: CGFloat = 72

    private var expandedWidth: CGFloat {
        IslandSizeCalculator.expandedWidth(for: state, panelWidth: panelWidth)
    }

    private var expandedHeight: CGFloat {
        IslandSizeCalculator.expandedHeight(
            for: state,
            visibleSessionCount: WidgetType.enabledWidgets.count,
            panelMaxHeight: panelMaxHeight,
            focusSessionCardHeight: focusSessionCardHeight
        )
    }

    private var contentWidth: CGFloat {
        isExpanded ? expandedWidth : pillWidth
    }

    private var contentHeight: CGFloat {
        isExpanded ? expandedHeight : collapsedTotalHeight
    }

    private var shapeWidth: CGFloat {
        isExpanded ? expandedWidth : pillWidth
    }

    private var shapeHeight: CGFloat {
        isExpanded ? expandedHeight : collapsedTotalHeight
    }

    /// 收起宽度：开启歌词时使用带歌词的宽度，否则使用默认宽度
    private var pillWidth: CGFloat {
        showLyrics && showTicker
            ? IslandSizeCalculator.collapsedPillWidthWithLyrics
            : IslandSizeCalculator.pillWidth(
                islandObscuredByNotch: islandObscuredByNotch,
                visibleSessionCount: 0
            )
    }

    private var pillFillColor: Color { IslandStyle.surface(for: colorScheme) }

    private var pillStrokeOpacity: CGFloat { IslandStyle.strokeOpacity(for: colorScheme) }

    private var notchShapeOpenProgress: CGFloat {
        IslandSizeCalculator.openProgress(
            shapeHeight: shapeHeight,
            cachedExpandedShapeHeight: cachedExpandedShapeHeight
        )
    }

    private var notchTopCornerRadius: CGFloat {
        IslandSizeCalculator.topCornerRadius(for: state)
    }

    private var notchBottomCornerRadius: CGFloat {
        IslandSizeCalculator.bottomCornerRadius(openProgress: notchShapeOpenProgress)
    }

    // MARK: - 动画

    private static let expandSpring = Animation.spring(response: 0.4, dampingFraction: 0.82)
    private static let collapseSpring = Animation.spring(response: 0.35, dampingFraction: 0.8)
    private static let contentFade = Animation.easeInOut(duration: 0.2)

    // MARK: - 主视图

    var body: some View {
        ZStack(alignment: .top) {
            // 背景形状
            UnevenRoundedRectangle(
                topLeadingRadius: notchTopCornerRadius,
                bottomLeadingRadius: notchBottomCornerRadius,
                bottomTrailingRadius: notchBottomCornerRadius,
                topTrailingRadius: notchTopCornerRadius,
                style: .continuous
            )
            .fill(pillFillColor)
            .shadow(
                color: IslandStyle.shadowColor(for: colorScheme)
                    .opacity(IslandStyle.shadowOpacity(for: colorScheme) + 0.02 * notchShapeOpenProgress),
                radius: 10 + 10 * notchShapeOpenProgress,
                y: 3 + notchShapeOpenProgress
            )
            .overlay {
                UnevenRoundedRectangle(
                    topLeadingRadius: notchTopCornerRadius,
                    bottomLeadingRadius: notchBottomCornerRadius,
                    bottomTrailingRadius: notchBottomCornerRadius,
                    topTrailingRadius: notchTopCornerRadius,
                    style: .continuous
                )
                .strokeBorder(
                    IslandStyle.strokeColor(for: colorScheme)
                        .opacity(pillStrokeOpacity + (isHoveringPill ? 0.15 : 0)),
                    lineWidth: 0.5
                )
            }
            .scaleEffect(
                x: jellyTrigger ? (jellySettled ? jellyScale.xSettle : jellyScale.xPop) : 1.0,
                y: jellyTrigger ? (jellySettled ? jellyScale.ySettle : jellyScale.yPop) : 1.0
            )
            .frame(width: shapeWidth, height: shapeHeight)

            // 展开内容
            expandedContent
                .frame(width: expandedWidth > 0 ? expandedWidth : panelWidth,
                       height: isExpanded ? expandedHeight : 0, alignment: .top)
                .clipped()
                .opacity(showContent ? 1 : 0)
                .allowsHitTesting(showContent)
                .zIndex(1)

            // 收起状态内容
            ZStack(alignment: .top) {
                CollapsedPillView(
                    isExpanded: isExpanded,
                    isPlaying: mediaManager.isPlaying,
                    albumArt: mediaManager.currentArtwork,
                    albumArtData: mediaManager.currentArtworkData,
                    artworkVersion: mediaManager.artworkVersion,
                    gifData: cachedGifData,
                    containerWidth: shapeWidth,
                    containerHeight: collapsedShapeHeight,
                    onTap: { expand(to: .expanded) },
                    onFileDrop: { providers in
                        for provider in providers {
                            provider.loadObject(ofClass: NSURL.self) { reading, _ in
                                guard let nsurl = reading as? NSURL else { return }
                                DispatchQueue.main.async { trayManager.addFile(from: nsurl as URL) }
                            }
                        }
                        return true
                    }
                )
                .gesture(
                    DragGesture(minimumDistance: 15, coordinateSpace: .global)
                        .onEnded { value in
                            // 下滑展开
                            let dy = value.translation.height
                            if dy > 15 && !isExpanded {
                                expand(to: .expanded)
                            }
                        }
                )
                .offset(magneticOffset)
                .frame(width: shapeWidth, height: collapsedShapeHeight)

                // Ticker 行
                if showTicker {
                    MarqueeText(
                        text: tickerText,
                        font: .system(size: 10, weight: .medium),
                        availableWidth: shapeWidth - 28,
                        speed: tickerSpeed
                    )
                    .foregroundColor(IslandStyle.tertiaryText(for: colorScheme))
                    .frame(width: shapeWidth, height: tickerLineHeight)
                    .offset(y: collapsedShapeHeight - 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .frame(width: shapeWidth, height: collapsedTotalHeight)
            .opacity(showContent ? 0 : 1)
            .allowsHitTesting(!showContent)
            .zIndex(0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
        .contentShape(Rectangle())
        .contextMenu {
            Button(L10n.preferences) {
                openSettingsWindow()
            }
            Divider()
            Button(L10n.quit) {
                NSApp.terminate(nil)
            }
        }
        .preferredColorScheme(colorScheme)
        .onChange(of: expandedHeight) { _, newHeight in
            guard isExpanded else { return }
            cachedExpandedShapeHeight = max(collapsedShapeHeight + 1, newHeight)
            onSizeChange?(expandedWidth, newHeight)
        }
        .onChange(of: state) { _, newState in
            if newState == .collapsed {
                cancelExpandedAutoHide()
            } else {
                scheduleExpandedAutoHide()
            }
        }
        .onChange(of: showTicker) { _, newValue in
            guard !isExpanded, !collapseAnimating else { return }
            if newValue {
                // Ticker 出现：先调大窗口，再让 SwiftUI 动画渲染
                onSizeChange?(pillWidth, collapsedShapeHeight + tickerLineHeight + 4)
            } else {
                // Ticker 消失：先动画收缩，再缩小窗口
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    guard self.state == .collapsed, !self.showTicker else { return }
                    onSizeChange?(pillWidth, collapsedShapeHeight)
                }
            }
        }
        .onAppear {
            // 缓存 NotchWindow 引用，后续直接使用
            notchWindow = NSApp.windows.first(where: { $0 is NotchWindow }) as? NotchWindow

            // 如果窗口尚未就绪，递增延迟重试（0.3s → 0.6s → 1.0s）
            if notchWindow == nil {
                let delays: [TimeInterval] = [0.3, 0.6, 1.0]
                for delay in delays {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
                        guard notchWindow == nil else { return } // 已找到则跳过后续重试
                        notchWindow = NSApp.windows.first(where: { $0 is NotchWindow }) as? NotchWindow
                        if let window = notchWindow {
                            islandObscuredByNotch = window.isObscuredByPhysicalNotch()
                        }
                    }
                }
            }

            // 检查是否被物理 Notch 遮挡
            if let window = notchWindow {
                islandObscuredByNotch = window.isObscuredByPhysicalNotch()
            }

            // 初始化窗口大小为收起状态（含 Ticker 高度）
            let targetWidth = pillWidth
            let targetHeight = collapsedTotalHeight
            onSizeChange?(targetWidth, targetHeight)

            if isExpanded {
                cachedExpandedShapeHeight = IslandSizeCalculator.expandedPanelShapeHeight(
                    visibleSessionCount: WidgetType.enabledWidgets.count,
                    panelMaxHeight: panelMaxHeight,
                    focusSessionCardHeight: focusSessionCardHeight
                )
            }
            startHoverPolling()
            loadGifData()

            // 应用退出时恢复光标（防止崩溃导致光标残留隐藏）
            terminateObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { _ in
                NSCursor.arrow.set()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .xnookScrollDown)) { _ in
            // 双指下滑展开面板（由 scrollDownToExpandPanel 开关控制）
            // 冷却 0.5s 防止连续滚动帧导致的抖动循环
            let cooldown: TimeInterval = 0.5
            guard !isExpanded, !collapseAnimating,
                  Date().timeIntervalSince(expandedAt) > cooldown else { return }
            expand(to: .expanded)
        }
        .onReceive(NotificationCenter.default.publisher(for: .xnookCollapse)) { _ in
            collapse()
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            // UserDefaults 变更时更新窗口大小
            if state == .collapsed {
                let h = showTicker ? collapsedShapeHeight + tickerLineHeight + 4 : collapsedShapeHeight
                onSizeChange?(pillWidth, h)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("GifDidChange"))) { _ in
            // 仅在 GIF 选择变更时重新加载
            loadGifData()
        }
        .onDisappear {
            stopHoverPolling()
            cancelExpandedAutoHide()
            if let observer = terminateObserver {
                NotificationCenter.default.removeObserver(observer)
                terminateObserver = nil
            }
        }
    }

    // MARK: - 展开/收起逻辑（与 X Island 完全一致）

    private func expand(to newState: IslandState) {
        guard !expandPending else { return }
        collapseGeneration += 1
        collapseAnimating = false
        expandPending = true
        expandedAt = Date()
        calendarRecenterTrigger += 1

        // 同步状态到窗口层
        if let window = notchWindow {
            window.islandState = newState
        }

        // 展开时恢复光标和果冻状态
        if isHoveringPill {
            isHoveringPill = false
            jellyTrigger = false
            jellySettled = false
            jellyGeneration += 1
            Self.invisibleCursor.pop()
        }

        let target = targetSize(for: newState)
        if case .expanded = newState {
            cachedExpandedShapeHeight = IslandSizeCalculator.expandedPanelShapeHeight(
                visibleSessionCount: WidgetType.enabledWidgets.count,
                panelMaxHeight: panelMaxHeight,
                focusSessionCardHeight: focusSessionCardHeight
            )
        }

        // 1. 窗口立即调整到目标大小（无动画）
        onSizeChange?(target.width, target.height)

        let runExpansion = {
            if self.reduceMotion {
                self.state = newState
                self.showContent = true
            } else {
                // 2. 形状弹簧动画
                withAnimation(Self.expandSpring) {
                    self.state = newState
                }
                // 3. 内容延迟淡入
                withAnimation(Self.contentFade.delay(0.12)) {
                    self.showContent = true
                }
            }
            self.expandPending = false
        }

        // 等 0.05s 让窗口先就位，再开始形状动画
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            runExpansion()
        }
    }

    private func collapse() {
        collapseGeneration += 1
        let generation = collapseGeneration
        lastCollapseAt = Date()
        collapseAnimating = true

        // 收起时恢复光标和果冻状态
        if isHoveringPill {
            isHoveringPill = false
            jellyTrigger = false
            jellySettled = false
            jellyGeneration += 1
            Self.invisibleCursor.pop()
        }

        // 1. 形状动画收起
        if reduceMotion {
            showContent = false
            state = .collapsed
        } else {
            withAnimation(Self.collapseSpring) {
                showContent = false
                state = .collapsed
            }
        }

        // 2. 等 0.45s 形状动画完成，再调整窗口大小
        let finishCollapse = {
            guard generation == self.collapseGeneration, self.state == .collapsed else { return }
            let w = self.pillWidth
            let h = self.collapsedTotalHeight
            DispatchQueue.main.async {
                guard generation == self.collapseGeneration, self.state == .collapsed else { return }
                if let window = notchWindow {
                    window.resizeToFitCollapse(contentWidth: w, contentHeight: h)
                    window.islandState = self.state
                }
                self.collapseAnimating = false
                NotificationCenter.default.post(name: .islandDidCollapse, object: nil)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            finishCollapse()
        }
    }

    private func targetSize(for state: IslandState) -> (width: CGFloat, height: CGFloat) {
        // 收起状态传 0（无会话），展开状态传 widget 数量
        let sessionCount = state == .expanded ? WidgetType.enabledWidgets.count : 0
        // NookFlow 区域高度仅在展开时纳入
        let cardHeight = state == .expanded ? focusSessionCardHeight : 0
        return IslandSizeCalculator.targetSize(
            for: state,
            visibleSessionCount: sessionCount,
            panelWidth: panelWidth,
            panelMaxHeight: panelMaxHeight,
            focusSessionCardHeight: cardHeight
        )
    }

    // MARK: - 鼠标悬停检测

    /// 低频轮询间隔（鼠标远离时），仅检测进入/离开，大幅节省 CPU
    private static let hoverPollIntervalSlow: TimeInterval = 0.25
    /// 高频轮询间隔（鼠标靠近时），保证吸附和果冻动画流畅
    private static let hoverPollIntervalFast: TimeInterval = 0.016
    /// 鼠标接近判定距离（屏幕宽度的一定比例）
    private static let hoverProximityRange: CGFloat = 300

    static func shouldTriggerHoverJelly(
        isPointerInside: Bool,
        wasPointerInside: Bool,
        isExpanded: Bool,
        collapseAnimating: Bool,
        previousMouseY: CGFloat,
        currentMouseY: CGFloat
    ) -> Bool {
        isPointerInside
            && !isExpanded
            && !collapseAnimating
            && (!wasPointerInside || previousMouseY < currentMouseY)
    }

    static func shouldExpandForHover(
        isPointerInside: Bool,
        isExpanded: Bool,
        hasPassedCollapseCooldown: Bool,
        hoverToExpandPanel: Bool,
        isSwitchingApps: Bool
    ) -> Bool {
        isPointerInside
            && !isExpanded
            && hasPassedCollapseCooldown
            && hoverToExpandPanel
            && !isSwitchingApps
    }

    static func hoverHitFrame(
        windowFrame: CGRect,
        screenFrame: CGRect?,
        isExpanded: Bool
    ) -> CGRect {
        var hitFrame = windowFrame

        if isExpanded {
            hitFrame = windowFrame.insetBy(dx: -20, dy: -20)
            if let screenFrame {
                let minX = max(hitFrame.minX, screenFrame.minX)
                let maxX = min(hitFrame.maxX, screenFrame.maxX)
                if maxX >= minX {
                    hitFrame.origin.x = minX
                    hitFrame.size.width = maxX - minX
                }
            }
            return hitFrame
        }

        if let screenFrame {
            let screenTop = screenFrame.maxY
            hitFrame.size.height += max(0, screenTop - hitFrame.maxY) + 1
        }
        return hitFrame
    }

    static func shouldDeferExpandedAutoHide(
        mouseLocation: CGPoint,
        windowFrame: CGRect,
        screenFrame: CGRect?
    ) -> Bool {
        hoverHitFrame(
            windowFrame: windowFrame,
            screenFrame: screenFrame,
            isExpanded: true
        ).contains(mouseLocation)
    }

    private func startHoverPolling() {
        stopHoverPolling()
        // 默认从低频开始，鼠标接近 notch 区域时自动加速
        hoverPollingFast = false
        scheduleHoverPoll(interval: Self.hoverPollIntervalSlow)
    }

    private func stopHoverPolling() {
        hoverTimer?.invalidate()
        hoverTimer = nil
    }

    private func resolveNotchWindow() -> NotchWindow? {
        if let appDelegateWindow = AppDelegate.shared?.notchWindow {
            if notchWindow !== appDelegateWindow {
                notchWindow = appDelegateWindow
            }
            return appDelegateWindow
        }

        if notchWindow == nil {
            notchWindow = NSApp.windows.first(where: { $0 is NotchWindow }) as? NotchWindow
        }
        return notchWindow
    }

    /// 调度单次轮询，完成后根据鼠标距离决定下次频率
    private func scheduleHoverPoll(interval: TimeInterval) {
        hoverTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { _ in
            pollMousePosition()
        }
    }

    /// 轮询后根据鼠标距离动态切换频率
    private func adjustHoverPollingSpeed(mouseNear: Bool) {
        let shouldFast = mouseNear || isHoveringPill || isExpanded
        if shouldFast != hoverPollingFast {
            hoverPollingFast = shouldFast
            // 当前 Timer 是 non-repeating，下次 pollMousePosition 末尾会用新间隔重新调度
        }
        let interval = hoverPollingFast ? Self.hoverPollIntervalFast : Self.hoverPollIntervalSlow
        scheduleHoverPoll(interval: interval)
    }

    private func pollMousePosition() {
        guard let window = resolveNotchWindow() else {
            scheduleHoverPoll(interval: Self.hoverPollIntervalSlow)
            return
        }
        guard !window.isDragging else {
            scheduleHoverPoll(interval: Self.hoverPollIntervalFast)
            return
        }

        // 更新 notch 遮挡状态
        let obscured = window.isObscuredByPhysicalNotch()
        if obscured != islandObscuredByNotch {
            islandObscuredByNotch = obscured
        }

        let mouse = NSEvent.mouseLocation
        let hitFrame = Self.hoverHitFrame(
            windowFrame: window.frame,
            screenFrame: isExpanded ? window.screen?.visibleFrame : window.screen?.frame,
            isExpanded: isExpanded
        )

        var inside = hitFrame.contains(mouse)
        let wasInside = wasPointerInsidePillHitFrame

        if collapseAnimating { inside = false }

        // 检测鼠标从下方进入药丸（仅收起状态且无动画时）
        if Self.shouldTriggerHoverJelly(
            isPointerInside: inside,
            wasPointerInside: wasInside,
            isExpanded: isExpanded,
            collapseAnimating: collapseAnimating,
            previousMouseY: previousMouseY,
            currentMouseY: mouse.y
        ) {
            if !isHoveringPill {
                isHoveringPill = true
                jellySettled = false
                jellyGeneration += 1  // 新一代动画，废弃旧的 asyncAfter
                let gen = jellyGeneration
                Self.invisibleCursor.push()
                // 果冻弹跳：先大幅弹起
                withAnimation(.spring(response: 0.5, dampingFraction: 0.3)) {
                    jellyTrigger = true
                }
                // 回弹到稍大状态（检查 generation，防止旧计时器干扰）
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [self] in
                    guard gen == self.jellyGeneration else { return }
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.4)) {
                        self.jellySettled = true
                    }
                }
            }
        } else if !inside || isExpanded || collapseAnimating {
            if isHoveringPill {
                isHoveringPill = false
                jellyGeneration += 1  // 废弃所有进行中的果冻计时器
                Self.invisibleCursor.pop()
                withAnimation(.easeOut(duration: 0.2)) {
                    jellyTrigger = false
                    jellySettled = false
                }
            }
        }

        previousMouseY = mouse.y
        wasPointerInsidePillHitFrame = inside

        // 吸附效果：鼠标靠近药丸时水平偏移
        if !isExpanded, !collapseAnimating {
            let pillCenterX = window.frame.midX
            let pillCenterY = window.frame.minY + collapsedShapeHeight / 2
            let dx = mouse.x - pillCenterX
            let dy = mouse.y - pillCenterY
            let distance = sqrt(dx * dx + dy * dy)

            if distance < Self.magneticRange, distance > 1 {
                let strength = 1.0 - distance / Self.magneticRange
                let offsetX = dx * strength * 0.15
                let clamped = max(-Self.magneticMaxOffset, min(Self.magneticMaxOffset, offsetX))
                let newOffset = CGSize(width: clamped, height: 0)
                // 仅在变化超过阈值时触发动画，避免每帧重启动画
                if abs(newOffset.width - magneticOffset.width) > 0.5 {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        magneticOffset = newOffset
                    }
                }
            } else if magneticOffset != .zero {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.65)) {
                    magneticOffset = .zero
                }
            }
        } else if magneticOffset != .zero {
            magneticOffset = .zero
        }

        // 鼠标在展开面板内时，重置自动隐藏计时器
        if inside && isExpanded {
            scheduleExpandedAutoHide()
        }

        if Self.shouldExpandForHover(
            isPointerInside: inside,
            isExpanded: isExpanded,
            hasPassedCollapseCooldown: Date().timeIntervalSince(lastCollapseAt) > 0.65,
            hoverToExpandPanel: hoverToExpandPanel,
            isSwitchingApps: notchWindow?.isSwitchingApps ?? false
        ) {
            expandedByHover = true
            expandedAt = Date()
            expand(to: .expanded)
        } else if !inside && isExpanded && expandedByHover {
            // 鼠标移出展开面板时收起
            let elapsed = Date().timeIntervalSince(expandedAt)
            if elapsed > hoverExitCollapseDelay {
                expandedByHover = false
                collapse()
            }
        }

        // 根据鼠标距离动态调整下次轮询频率
        let pillCenterX = window.frame.midX
        let pillCenterY = window.frame.minY + collapsedShapeHeight / 2
        let dx = mouse.x - pillCenterX
        let dy = mouse.y - pillCenterY
        let distance = sqrt(dx * dx + dy * dy)
        adjustHoverPollingSpeed(mouseNear: distance < Self.hoverProximityRange)
    }

    // MARK: - 自动隐藏

    @State private var autoHideGeneration = 0

    private func cancelExpandedAutoHide() {
        autoHideGeneration += 1
    }

    private func scheduleExpandedAutoHide() {
        cancelExpandedAutoHide()
        let delay = UserDefaults.standard.double(forKey: "expandedInactivityAutoHideDelay")
        guard delay > 0 else { return }

        let gen = autoHideGeneration
        Task {
            try? await Task.sleep(for: .seconds(delay))
            guard autoHideGeneration == gen, isExpanded else { return }
            if let window = resolveNotchWindow() {
                if Self.shouldDeferExpandedAutoHide(
                    mouseLocation: NSEvent.mouseLocation,
                    windowFrame: window.frame,
                    screenFrame: window.screen?.visibleFrame
                ) {
                    scheduleExpandedAutoHide()
                    return
                }
            }
            collapse()
        }
    }

    // MARK: - 展开内容（多 Widget 并排布局）

    private var expandedContent: some View {
        VStack(spacing: 0) {
            // 顶部栏
            HStack(spacing: 8) {
                // 应用标识（左侧）
                HStack(spacing: 4) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(IslandStyle.accent(for: colorScheme))
                    Text("Nook")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(IslandStyle.primaryText)
                }

                Spacer()

                // Widget 标签（仅显示已启用的）
                ForEach(WidgetType.enabledWidgets, id: \.self) { widget in
                    HStack(spacing: 3) {
                        Image(systemName: widgetIcon(for: widget))
                            .font(.system(size: 8))
                        Text(widget.localizedName)
                            .font(.system(size: 9, weight: .medium))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .cornerRadius(4)
                    .foregroundColor(IslandStyle.secondaryText)
                }

                Spacer()

                // 关闭按钮（仅非悬停展开时显示）
                if !expandedByHover {
                    Button(action: { collapse() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(IslandStyle.secondaryText)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                // 设置按钮（右侧）
                Button(action: { openSettingsWindow() }) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(IslandStyle.secondaryText)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            // 分隔线
            Rectangle()
                .fill(IslandStyle.divider(for: colorScheme).opacity(IslandStyle.dividerOpacity(for: colorScheme)))
                .frame(height: 0.5)

            // NookFlow 区域：有活跃会话或有历史记录时显示
            if isFocusSessionVisible {
                FocusSessionView(
                    manager: focusSessionManager,
                    trayFileCount: trayManager.files.count,
                    onCreateLinkedNote: createLinkedNote,
                    onLinkTrayFiles: linkTrayFiles,
                    onEndSession: endFocusSession
                )
                // NookFlow 区域与下方 widget 网格之间的分隔线
                Rectangle()
                    .fill(IslandStyle.divider(for: colorScheme).opacity(IslandStyle.dividerOpacity(for: colorScheme)))
                    .frame(height: 0.5)
            }

            // 始终显示紧凑网格
            widgetCompactGrid
        }
    }

    // MARK: - NookFlow 协调逻辑

    /// 创建关联笔记 — 立即将返回 Note 的 id 与 title 写入 activeSession 快照
    private func createLinkedNote() {
        let note = notesManager.createNote(
            title: focusSessionManager.activeSession?.title ?? "Untitled",
            content: "",
            isMarkdown: true
        )
        focusSessionManager.linkNote(id: note.id, title: note.title)
    }

    /// 关联当前文件架 — 遍历 trayManager.files，立即把每个文件的快照写入 activeSession
    /// 已关联的文件由 Manager 按 id 去重
    private func linkTrayFiles() {
        guard focusSessionManager.activeSession != nil else { return }
        for file in trayManager.files {
            focusSessionManager.linkFile(id: file.id, name: file.name, icon: file.icon)
        }
    }

    /// 结束当前任务会话 — 直接调用 Manager.end()，不回读其他 Manager
    private func endFocusSession() {
        focusSessionManager.end()
    }

    /// 从日历事件启动 NookFlow 会话
    /// 写入 activeSession 后由 @Observable 驱动 expandedHeight 重算，
    /// onChange(of: expandedHeight) 同步窗口尺寸；若面板未展开则展开一次
    private func startFocusSession(from event: EKEvent) {
        focusSessionManager.start(
            title: event.title ?? "",
            eventIdentifier: event.eventIdentifier,
            scheduledEndAt: event.endDate
        )
        if !isExpanded {
            expand(to: .expanded)
        }
    }

    // MARK: - Widget 紧凑网格

    private var widgetCompactGrid: some View {
        let enabled = WidgetType.enabledWidgets
        return HStack(spacing: 0) {
            ForEach(Array(enabled.enumerated()), id: \.element) { index, widget in
                // Widget 内容
                widgetView(for: widget)
                    .frame(maxWidth: .infinity)
                    .frame(height: 160)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                // 垂直分隔线（最后一个不加）
                if index < enabled.count - 1 {
                    Rectangle()
                        .fill(IslandStyle.divider(for: colorScheme).opacity(0.4))
                        .frame(width: 0.5)
                        .frame(height: 120)
                }
            }
        }
    }

    /// 根据类型返回对应的 Widget 视图
    @ViewBuilder
    private func widgetView(for widget: WidgetType) -> some View {
        switch widget {
        case .media:
            MediaWidgetView(mediaManager: mediaManager)
        case .calendar:
            CalendarWidgetView(
                calendarManager: calendarManager,
                recenterTrigger: $calendarRecenterTrigger,
                onStartFocus: { event in startFocusSession(from: event) }
            )
            .onAppear { calendarManager.ensureAccess() }
        case .notes:
            NotesWidgetView(notesManager: notesManager)
        case .tray:
            TrayWidgetView(trayManager: trayManager)
        }
    }

    // MARK: - 辅助方法

    private func widgetIcon(for widget: WidgetType) -> String {
        switch widget {
        case .media: return "play.fill"
        case .calendar: return "calendar"
        case .notes: return "note.text"
        case .tray: return "tray.full"
        }
    }

    private func openSettingsWindow() {
        collapse()
        AppDelegate.shared?.openPreferences()
    }

    /// Ticker 显示文本：开启歌词时优先显示歌词，否则显示 标题 — 艺术家
    private var tickerText: String {
        if showLyrics {
            let lyricsLine = mediaManager.currentLyricLine
            if !lyricsLine.isEmpty { return lyricsLine }
        }

        let title = mediaManager.currentTitle
        let artist = mediaManager.currentArtist
        if title.isEmpty && artist.isEmpty { return L10n.nowPlaying }
        else if artist.isEmpty { return title }
        else if title.isEmpty { return artist }
        else { return "\(title) — \(artist)" }
    }

    private func loadGifData() {
        let defaults = UserDefaults.standard

        // 新版：从 gifs 目录加载选中的 GIF
        if let selectedName = defaults.string(forKey: "selectedGifName"),
           let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let gifURL = appSupport.appendingPathComponent("XNook/gifs/\(selectedName)")
            if let data = try? Data(contentsOf: gifURL) {
                cachedGifData = data
                return
            }
            // selectedGifName 已设置但文件不存在，不回退到旧版
            cachedGifData = nil
            return
        }

        // 旧版：从 custom.gif 加载（仅在未使用新版功能时）
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let gifURL = appSupport.appendingPathComponent("XNook/custom.gif")
            if let data = try? Data(contentsOf: gifURL) {
                cachedGifData = data
                return
            }
        }

        // 回退：从 bookmark 加载（兼容旧版本）
        guard let bookmarkData = defaults.data(forKey: "customGifBookmark") else {
            cachedGifData = nil
            return
        }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            cachedGifData = nil
            return
        }

        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        guard accessing else {
            cachedGifData = nil
            return
        }

        if let data = try? Data(contentsOf: url) {
            cachedGifData = data
        } else {
            cachedGifData = nil
        }
    }
}

// MARK: - 收起状态视图

struct CollapsedPillView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var isDragTargeted = false

    let isExpanded: Bool
    let isPlaying: Bool
    let albumArt: NSImage?
    let albumArtData: Data?
    let artworkVersion: Int
    let gifData: Data?
    let containerWidth: CGFloat
    let containerHeight: CGFloat
    let onTap: () -> Void
    var onFileDrop: (([NSItemProvider]) -> Bool)?

    /// 内容区域的可用高度（减去上下 padding）
    private var contentHeight: CGFloat { containerHeight - 12 }
    /// 封面和 GIF 的尺寸（取可用高度与默认高度的较小值，保持协调比例）
    private var iconSize: CGFloat { min(contentHeight, 24) }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 0) {
                // 左侧：专辑封面
                if let artData = albumArtData, let nsImage = NSImage(data: artData) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: iconSize, height: iconSize)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .id(artworkVersion)
                } else {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.1))
                        .frame(width: iconSize, height: iconSize)
                }

                Spacer(minLength: 6)

                // 右侧：自定义 GIF 或默认音频波形
                if let gifData {
                    GifView(gifData: gifData, isPlaying: isPlaying, targetSize: NSSize(width: iconSize, height: iconSize))
                        .frame(width: iconSize, height: iconSize)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    MusicVisualizerView(
                        isPlaying: isPlaying,
                        barCount: 4,
                        barColor: IslandStyle.tertiaryText(for: colorScheme)
                    )
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .onDrop(of: [.fileURL], isTargeted: $isDragTargeted) { providers in
            // 收起状态拖入文件：展开面板 + 接受文件
            if !isExpanded { onTap() }
            return onFileDrop?(providers) ?? false
        }
    }
}

// MARK: - Preview

#Preview {
    NotchContentView()
        .frame(width: 420, height: 250)
        .background(Color.black)
}
