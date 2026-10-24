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
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var mediaManager = MediaManager()
    @State private var calendarManager = CalendarManager()
    @State private var notesManager = NotesManager()
    @State private var trayManager = TrayManager()
    @State private var focusSessionManager = FocusSessionManager()
    /// 网页链接面板展开期间不得自动收起，否则编辑中的内容会丢失。
    @State private var isTaskLinksPresented = false

    @State private var state: IslandState = .collapsed
    @State private var showContent = false
    @State private var cachedExpandedShapeHeight: CGFloat = 220
    @State private var selectedWidget: WidgetType?
    @State private var enabledWidgets = WidgetType.enabledWidgets
    @State private var expandedMeasurement: ExpandedPanelMeasurement?
    @State private var expandedResizeScheduled = false
    @State private var availablePanelSize = CGSize(width: 1600, height: 900)
    @State private var isPanelInteractionActive = false
    @State private var hoverTimer: Timer?
    @State private var hoverPollingFast = false
    @State private var autoHideController = ExpandedAutoHideController()
    @State private var isWindowVisible = false
    @State private var lastCollapseAt: Date = .distantPast
    @State private var collapseAnimating = false
    /// 当前屏幕尺寸对应的动效档位，随窗口所在屏幕更新
    @State private var motionTier: IslandMotion.Tier = .regular
    private var motionPreset: IslandMotion.Preset { IslandMotion.preset(for: motionTier) }
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
    @AppStorage("panelBaseHeight") private var panelBaseHeight = SettingsDefaults.double(for: "panelBaseHeight")
    @AppStorage("panelAutoSize") private var panelAutoSize = SettingsDefaults.bool(for: "panelAutoSize")
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
    private var shouldReduceMotion: Bool { reduceMotion || systemReduceMotion }
    @AppStorage("showTickerLine") private var showTickerLine = SettingsDefaults.bool(for: "showTickerLine", fallback: true)
    @AppStorage("showLyrics") private var showLyrics = SettingsDefaults.bool(for: "showLyrics")
    @AppStorage("tickerSpeed") private var tickerSpeed = SettingsDefaults.double(for: "tickerSpeed")
    @AppStorage("showNookFlowHistory") private var showNookFlowHistory = SettingsDefaults.bool(for: "showNookFlowHistory", fallback: true)
    @AppStorage("nookFlowHistoryDisplayLimit") private var nookFlowHistoryDisplayLimit = SettingsDefaults.int(for: "nookFlowHistoryDisplayLimit", fallback: FocusSessionView.defaultHistoryDisplayLimit)
    @State private var cachedGifData: Data?
    @State private var gifLoadGeneration = 0
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

        var icon: String {
            switch self {
            case .media: return "play.fill"
            case .calendar: return "calendar"
            case .notes: return "note.text"
            case .tray: return "tray.full"
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

    private var effectivePanelWidth: CGFloat {
        let preferred = panelWidth.isFinite && panelWidth > 0 ? panelWidth : 800
        return min(max(160, preferred), availablePanelSize.width)
    }

    private var expandedWidth: CGFloat {
        isExpanded ? effectivePanelWidth : 0
    }

    private var naturalExpandedHeight: CGFloat {
        let measurement = expandedMeasurement.flatMap {
            $0.matches(width: effectivePanelWidth, selectedWidget: selectedWidget, enabledWidgets: enabledWidgets) ? $0.height : nil
        }
        return ExpandedPanelLayout.height(
            measuredContentHeight: measurement,
            maximumHeight: ExpandedPanelLayout.maximumHeight(
                availableHeight: availablePanelSize.height,
                automaticallyFit: panelAutoSize,
                manualMaxHeight: panelBaseHeight
            )
        )
    }

    private var expandedHeight: CGFloat {
        isExpanded ? naturalExpandedHeight : collapsedShapeHeight
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

    /// 灵动岛外轮廓。背景填充与描边共用同一形状，避免两处参数漂移。
    private var islandShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: notchTopCornerRadius,
            bottomLeadingRadius: notchBottomCornerRadius,
            bottomTrailingRadius: notchBottomCornerRadius,
            topTrailingRadius: notchTopCornerRadius,
            style: .continuous
        )
    }

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

    /// 展开与收起用不同弹簧：展开保留回弹，收起近乎不过冲。参数随屏幕尺寸分档，
    /// 见 IslandMotion。
    private var expandSpring: Animation { motionPreset.expand.animation }
    private var collapseSpring: Animation { motionPreset.collapse.animation }
    private static let contentFade = Animation.easeInOut(duration: IslandTokens.Duration.standard)
    /// Ticker 文本切换的淡入淡出动画：歌词行变化时不硬切
    private static let tickerTextTransition = Animation.easeInOut(duration: IslandTokens.Duration.text)
    /// 收起看门狗在动画时长之外额外等待的余量
    private static let collapseWatchdogSlack: TimeInterval = 0.25

    // MARK: - 主视图

    var body: some View {
        ZStack(alignment: .top) {
            // 背景形状：macOS 26 走玻璃材质，低版本回退纯色填充
            islandShape
            .fill(Color.clear)
            .background {
                IslandGlassBackground(shape: islandShape, scheme: colorScheme, isExpanded: isExpanded)
            }
            .shadow(
                color: IslandStyle.shadowColor(for: colorScheme)
                    .opacity(IslandStyle.shadowOpacity(for: colorScheme) + 0.02 * notchShapeOpenProgress),
                radius: 10 + 10 * notchShapeOpenProgress,
                y: 3 + notchShapeOpenProgress
            )
            .overlay {
                islandShape.strokeBorder(
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
            if isExpanded || expandPending || collapseAnimating {
                expandedContent
                .frame(width: effectivePanelWidth,
                       height: isExpanded ? expandedHeight : 0, alignment: .top)
                .clipped()
                .opacity(showContent ? 1 : 0)
                .allowsHitTesting(showContent)
                .zIndex(1)
            }

            // 收起状态内容
            ZStack(alignment: .top) {
                CollapsedPillView(
                    isExpanded: isExpanded,
                    isPlaying: mediaManager.isPlaying && isWindowVisible && !isExpanded && !expandPending && !collapseAnimating && !shouldReduceMotion,
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
                        speed: tickerSpeed,
                        isAnimated: isWindowVisible && !shouldReduceMotion
                    )
                    .foregroundColor(IslandStyle.tertiaryText(for: colorScheme))
                    .frame(width: shapeWidth, height: tickerLineHeight)
                    .offset(y: collapsedShapeHeight - 8)
                    // 不要用 .id(tickerText) 做转场：那会让每次歌词换行都销毁重建
                    // MarqueeText，其 @State textWidth 归零后要等一轮 preference
                    // 测量才恢复，反而在换行瞬间抖一下；且 0.25s 过渡期内新旧两个
                    // TimelineView(.animation) 会同时逐帧渲染。
                    // 滚动位置的重置由 MarqueeText 自身的 onChange(of: text) 负责。
                    .animation(shouldReduceMotion ? nil : Self.tickerTextTransition, value: tickerText)
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
            scheduleExpandedWindowResize()
        }
        .onChange(of: effectivePanelWidth) { _, _ in
            expandedMeasurement = nil
            scheduleExpandedWindowResize()
        }
        .onChange(of: selectedWidget) { _, newWidget in
            expandedMeasurement = nil
            if newWidget != .notes, notesManager.isEditing {
                if !notesManager.closeEditor() { selectedWidget = .notes }
            }
        }
        .onChange(of: notesManager.isEditing) { _, editing in
            if editing { selectedWidget = .notes }
        }
        .onChange(of: shouldReduceMotion) { _, enabled in
            if enabled { resetHoverEffects() }
        }
        .onChange(of: state) { _, newState in
            if newState == .collapsed {
                cancelExpandedAutoHide()
            } else {
                scheduleExpandedAutoHide()
            }
        }
        .onChange(of: expandedInactivityAutoHideDelay) { _, _ in
            scheduleExpandedAutoHide()
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
            AppDelegate.shared?.notesManagerForTermination = notesManager
            enabledWidgets = WidgetType.enabledWidgets
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
                            availablePanelSize = window.maximumExpandedContentSize()
                            installKeyboardHandler(on: window)
                        }
                    }
                }
            }

            // 检查是否被物理 Notch 遮挡
            if let window = notchWindow {
                islandObscuredByNotch = window.isObscuredByPhysicalNotch()
                isWindowVisible = window.isVisible && window.occlusionState.contains(.visible)
                availablePanelSize = window.maximumExpandedContentSize()
                installKeyboardHandler(on: window)
            }

            // 初始化窗口大小为收起状态（含 Ticker 高度）
            let targetWidth = pillWidth
            let targetHeight = collapsedTotalHeight
            onSizeChange?(targetWidth, targetHeight)

            if isExpanded {
                cachedExpandedShapeHeight = naturalExpandedHeight
            }
            startHoverPolling()
            loadGifData()

            // 应用退出时恢复光标（防止崩溃导致光标残留隐藏）
            terminateObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    notesManager.flushPendingChanges()
                    NSCursor.arrow.set()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { notification in
            guard let window = notification.object as? NotchWindow,
                  window === resolveNotchWindow() else { return }
            isWindowVisible = window.isVisible && window.occlusionState.contains(.visible)
            if !isWindowVisible { resetHoverEffects() }
            scheduleExpandedAutoHide()
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
            // 切换到另一个岛时必须收起，即使在编辑网页链接。
            collapse(force: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            let widgets = WidgetType.enabledWidgets
            if widgets != enabledWidgets {
                enabledWidgets = widgets
                if let selectedWidget, !widgets.contains(selectedWidget) { self.selectedWidget = nil }
                expandedMeasurement = nil
            }
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
            collapseGeneration += 1
            expandPending = false
            collapseAnimating = false
            stopHoverPolling()
            cancelExpandedAutoHide()
            resetHoverEffects()
            notesManager.flushPendingChanges()
            isWindowVisible = false
            notchWindow?.keyEquivalentHandler = nil
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
        let generation = collapseGeneration
        collapseAnimating = false
        expandPending = true
        expandedAt = Date()
        calendarRecenterTrigger += 1

        // 同步状态到窗口层
        if let window = notchWindow {
            window.islandState = newState
            if !expandedByHover { window.makeKey() }
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
            cachedExpandedShapeHeight = naturalExpandedHeight
        }

        // 1. 窗口立即调整到目标大小（无动画）
        onSizeChange?(target.width, target.height)

        let runExpansion = { [motionPreset] in
            if self.shouldReduceMotion {
                self.state = newState
                self.showContent = true
            } else {
                // 2. 形状弹簧动画
                withAnimation(motionPreset.expand.animation) {
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
            guard generation == self.collapseGeneration, self.expandPending else { return }
            runExpansion()
        }
    }

    /// 链接面板打开时只允许强制收起（例如切换应用），避免自动收起丢掉正在编辑的内容。
    static func allowsCollapse(isTaskLinksPresented: Bool, forced: Bool) -> Bool {
        forced || !isTaskLinksPresented
    }

    private func collapse(force: Bool = false) {
        guard Self.allowsCollapse(isTaskLinksPresented: isTaskLinksPresented, forced: force) else { return }
        expandPending = false
        expandedByHover = false
        cancelExpandedAutoHide()
        notesManager.flushPendingChanges()
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
        if shouldReduceMotion {
            showContent = false
            state = .collapsed
        } else {
            withAnimation(motionPreset.collapse.animation) {
                showContent = false
                state = .collapsed
            }
        }

        // 2. 形状动画结束后调整窗口大小。
        // 收尾做成幂等，并由正常回调与看门狗两条路径调用：正常回调会因 generation
        // 过期被吞掉（收起期间视图消失、屏幕切换等），那样 collapseAnimating 会永久
        // 停在 true，此后轮询恒把指针判为在面板外，悬停展开彻底失效且只能重启。
        let settleDelay = shouldReduceMotion ? 0 : IslandMotion.settleDuration(for: motionPreset.collapse)
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) { [self] in
            completeCollapse(generation: generation)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay + Self.collapseWatchdogSlack) { [self] in
            completeCollapse(generation: generation)
        }
    }

    /// 收起收尾：把窗口收缩到胶囊尺寸并解除 collapseAnimating。幂等，可安全重复调用。
    private func completeCollapse(generation: Int) {
        // generation 已过期说明有更新的展开或收起接管，交给它收尾。
        guard generation == collapseGeneration, collapseAnimating, state == .collapsed else { return }
        let w = pillWidth
        let h = collapsedTotalHeight
        DispatchQueue.main.async { [self] in
            guard generation == collapseGeneration, collapseAnimating, state == .collapsed else { return }
            if let window = notchWindow {
                window.resizeToFitCollapse(contentWidth: w, contentHeight: h)
                window.islandState = state
            }
            collapseAnimating = false
            NotificationCenter.default.post(name: .islandDidCollapse, object: nil)
        }
    }

    private func targetSize(for state: IslandState) -> (width: CGFloat, height: CGFloat) {
        state == .expanded
            ? (effectivePanelWidth, naturalExpandedHeight)
            : (pillWidth, collapsedTotalHeight)
    }

    private func scheduleExpandedWindowResize() {
        guard isExpanded, !expandedResizeScheduled else { return }
        expandedResizeScheduled = true
        // 宽度、偏好和实测高度可在同一轮更新，合并后使用最新值，避免窗口反馈重复布局。
        DispatchQueue.main.async {
            expandedResizeScheduled = false
            guard isExpanded else { return }
            onSizeChange?(effectivePanelWidth, naturalExpandedHeight)
        }
    }

    // MARK: - 鼠标悬停检测

    /// 低频轮询间隔（鼠标远离时），仅检测进入/离开，大幅节省 CPU
    private static let hoverPollIntervalSlow: TimeInterval = 0.25
    /// 高频轮询间隔（鼠标靠近时），保证吸附和果冻动画流畅
    private static let hoverPollIntervalFast: TimeInterval = 0.016
    /// 自动收起的最小延迟；低于此值 ExpandedAutoHideController 不调度收起
    private static let minimumAutoHideDelay: TimeInterval = 0.1
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

    /// 窗口隐藏后不再进入悬停分支，因此必须主动配对释放透明光标。
    private func resetHoverEffects() {
        guard isHoveringPill || jellyTrigger || jellySettled
                || magneticOffset != .zero || wasPointerInsidePillHitFrame else { return }
        if isHoveringPill {
            Self.invisibleCursor.pop()
            isHoveringPill = false
        }
        jellyGeneration += 1
        jellyTrigger = false
        jellySettled = false
        magneticOffset = .zero
        wasPointerInsidePillHitFrame = false
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
        let visible = window.isVisible && window.occlusionState.contains(.visible)
        let panelSize = window.maximumExpandedContentSize()
        if availablePanelSize != panelSize { availablePanelSize = panelSize }
        if isWindowVisible != visible { isWindowVisible = visible }
        // 形变距离随屏幕变大，动效参数跟着档位走；窗口跨屏后需要换档。
        if let screenWidth = window.screen?.frame.width {
            let tier = IslandMotion.tier(forScreenWidth: screenWidth)
            if tier != motionTier { motionTier = tier }
        }
        guard visible else {
            cancelExpandedAutoHide()
            resetHoverEffects()
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
        if !shouldReduceMotion && Self.shouldTriggerHoverJelly(
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

        // @State 的 setter 不做值相等判别，写一次就使视图失效一次。本函数最快以 0.016s
        // 被调用，无条件写入会让展开后的面板持续全树重算，必须仅在值变化时写入。
        if previousMouseY != mouse.y { previousMouseY = mouse.y }
        if wasPointerInsidePillHitFrame != inside { wasPointerInsidePillHitFrame = inside }

        // 吸附效果：鼠标靠近药丸时水平偏移
        if !shouldReduceMotion, !isExpanded, !collapseAnimating {
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

        // 指针进入时取消等待；离开后仅启动一次，重复轮询保持原倒计时。
        scheduleExpandedAutoHide()

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
        } else if !inside && isExpanded && expandedByHover && !shouldKeepPanelOpen(window) {
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

    private func cancelExpandedAutoHide() {
        autoHideController.cancel()
    }

    private func shouldKeepPanelOpen(_ window: NotchWindow) -> Bool {
        notesManager.isEditing || isPanelInteractionActive || isTaskLinksPresented || window.isDragging
            || window.attachedSheet != nil
            || (window.childWindows?.contains(where: \.isVisible) ?? false)
            || (window.isKeyWindow && window.firstResponder is NSTextView)
            || RunLoop.current.currentMode == .eventTracking
    }

    private func installKeyboardHandler(on window: NotchWindow) {
        window.keyEquivalentHandler = { event in
            guard isExpanded, let action = PanelKeyboardAction.resolve(
                characters: event.charactersIgnoringModifiers, modifiers: event.modifierFlags
            ) else { return false }
            guard !event.isARepeat else { return true }
            switch action {
            case .overview:
                selectedWidget = nil
            case .tool(let index):
                let widget = WidgetType.allCases[index]
                guard enabledWidgets.contains(widget) else { return false }
                selectedWidget = widget
            case .newNote:
                selectedWidget = .notes
                notesManager.createNote()
            case .saveNote:
                guard selectedWidget == .notes, notesManager.isEditing else { return false }
                notesManager.flushPendingChanges()
            }
            return true
        }
    }

    private func scheduleExpandedAutoHide() {
        guard let window = resolveNotchWindow() else {
            cancelExpandedAutoHide()
            return
        }
        // 指针停在面板上时挂起倒计时并记账，离开后按剩余时间续上，
        // 而不是把整个延迟重新计一遍——否则每次瞥一眼面板都会重置倒计时。
        let pointerInsidePanel = Self.shouldDeferExpandedAutoHide(
            mouseLocation: NSEvent.mouseLocation,
            windowFrame: window.frame,
            screenFrame: window.screen?.visibleFrame
        )
        let shouldDefer = shouldKeepPanelOpen(window) || pointerInsidePanel
        autoHideController.update(
            isExpanded: isExpanded && isWindowVisible,
            shouldDefer: shouldDefer,
            // 0 或负值会让自动收起永不触发，面板会一直悬停；旧配置里可能残留 0，在此兜底。
            delay: max(Self.minimumAutoHideDelay, expandedInactivityAutoHideDelay)
        ) {
            // 等待结束时重新检查，避免指针已进入但下一次轮询尚未执行。
            guard isExpanded, isWindowVisible, !shouldKeepPanelOpen(window) else { return }
            guard !Self.shouldDeferExpandedAutoHide(
                mouseLocation: NSEvent.mouseLocation,
                windowFrame: window.frame,
                screenFrame: window.screen?.visibleFrame
            ) else { return }
            collapse()
        }
    }

    // MARK: - 展开面板

    /// 面板顶部的物理刘海死区。窗口不在刘海正下方时为空，不影响无刘海屏幕。
    private var panelDeadZone: NotchDeadZone {
        guard isExpanded, let window = notchWindow else { return .none }
        return NotchDeadZone.resolve(for: window)
    }

    private var expandedContent: some View {
        ExpandedPanelView(
            selectedWidget: $selectedWidget,
            calendarRecenterTrigger: $calendarRecenterTrigger,
            enabledWidgets: enabledWidgets,
            panelWidth: effectivePanelWidth,
            mediaManager: mediaManager,
            calendarManager: calendarManager,
            notesManager: notesManager,
            trayManager: trayManager,
            focusSessionManager: focusSessionManager,
            showHistory: showNookFlowHistory,
            historyDisplayLimit: nookFlowHistoryDisplayLimit,
            onCreateLinkedNote: createLinkedNote,
            onLinkTrayFiles: linkTrayFiles,
            onEndSession: endFocusSession,
            onOpenNote: openLinkedNote,
            onOpenFile: openLinkedFile,
            onStartFocus: startFocusSession,
            onInteractionChanged: { isPanelInteractionActive = $0 },
            onLinksPresentationChanged: { presented in
                isTaskLinksPresented = presented
                if presented { cancelExpandedAutoHide() }
                else if isExpanded { scheduleExpandedAutoHide() }
            },
            onSettings: openSettingsWindow,
            onClose: { collapse(force: true) },
            onMeasurement: { measurement in
                guard measurement.matches(width: effectivePanelWidth, selectedWidget: selectedWidget, enabledWidgets: enabledWidgets),
                      measurement.differs(from: expandedMeasurement) else { return }
                expandedMeasurement = measurement
            },
            deadZone: panelDeadZone
        )
    }

    // MARK: - NookFlow 协调逻辑

    private var nookFlowActions: NookFlowActions {
        NookFlowActions(sessions: focusSessionManager, notes: notesManager, tray: trayManager)
    }

    /// 创建关联笔记 — 立即将返回 Note 的 id 与 title 写入 activeSession 快照
    private func createLinkedNote() -> Bool {
        guard nookFlowActions.createLinkedNote() else { return false }
        selectedWidget = .notes
        return true
    }

    private func openLinkedNote(_ id: UUID) -> Bool {
        guard nookFlowActions.openNote(id) else { return false }
        selectedWidget = .notes
        return true
    }

    private func openLinkedFile(_ file: LinkedFile) -> Bool {
        nookFlowActions.openFile(file)
    }

    /// 关联当前文件架 — 遍历 trayManager.files，立即把每个文件的快照写入 activeSession
    /// 已关联的文件由 Manager 按 id 去重
    private func linkTrayFiles() {
        nookFlowActions.linkTrayFiles()
    }

    /// 结束当前任务会话 — 直接调用 Manager.end()，不回读其他 Manager
    private func endFocusSession() {
        focusSessionManager.end()
    }

    /// 从日历事件启动 NookFlow 会话
    /// 写入 activeSession 后由 @Observable 驱动 expandedHeight 重算，
    /// onChange(of: expandedHeight) 同步窗口尺寸；若面板未展开则展开一次
    private func startFocusSession(from event: EKEvent) {
        // 存储不可用时 start 返回 nil，此时不应展开面板，也不清掉当前选择的工具。
        guard focusSessionManager.start(
            title: event.title ?? "",
            eventIdentifier: event.eventIdentifier,
            scheduledEndAt: event.endDate
        ) != nil else { return }
        selectedWidget = nil
        if !isExpanded {
            expand(to: .expanded)
        }
    }

    private func openSettingsWindow() {
        collapse()
        // 推迟到下一 runloop 打开设置窗口，避免 NSPanel 首次创建 + SettingsView 加载
        // 阻塞主线程导致收起动画前几帧丢帧
        DispatchQueue.main.async {
            AppDelegate.shared?.openPreferences()
        }
    }

    /// Ticker 显示文本优先级：
    /// 1. 同步歌词当前行
    /// 2. 纯歌词首句兜底（无时间轴，仍有歌词可读）
    /// 3. 标题 — 艺术家
    private var tickerText: String {
        if showLyrics {
            let syncedLine = mediaManager.currentLyricLine
            if !syncedLine.isEmpty { return syncedLine }
            let plainPreview = mediaManager.plainLyricPreview
            if !plainPreview.isEmpty { return plainPreview }
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
        let selectedName = defaults.string(forKey: "selectedGifName")
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let bookmarkData = defaults.data(forKey: "customGifBookmark")
        gifLoadGeneration += 1
        let generation = gifLoadGeneration
        Task { @MainActor in
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    try GifResource.selectedData(selectedName: selectedName, appSupport: appSupport, bookmarkData: bookmarkData)
                }.value
                guard generation == gifLoadGeneration else { return }
                cachedGifData = data
            } catch {
                guard generation == gifLoadGeneration else { return }
                // 加载失败时保留上一份已验证缓存和用户选择，设置页可显示错误。
                NotificationCenter.default.post(name: GifResource.loadFailureNotification, object: nil, userInfo: [
                    "message": L10n.gifLoadFailed(selectedName ?? "GIF", reason: error.localizedDescription)
                ])
            }
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
                if let nsImage = albumArt {
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

#if !XNOOK_DISABLE_PREVIEWS
#Preview {
    NotchContentView()
        .frame(width: 420, height: 250)
        .background(Color.black)
}
#endif
