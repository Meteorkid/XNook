import SwiftUI

/// 灵动岛状态
enum IslandState: Equatable {
    case collapsed
    case expanded
}

/// Notch 主内容视图 - 与 X Island 保持一致的灵动岛风格
struct NotchContentView: View {
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var mediaManager = MediaManager()
    @StateObject private var calendarManager = CalendarManager()
    @StateObject private var notesManager = NotesManager()
    @StateObject private var trayManager = TrayManager()

    @State private var state: IslandState = .collapsed
    @State private var showContent = false
    @State private var cachedExpandedShapeHeight: CGFloat = 220
    @State private var selectedWidget: WidgetType?
    @State private var hoverTimer: Timer?
    @State private var lastCollapseAt: Date = .distantPast
    @State private var collapseAnimating = false
    @State private var collapseGeneration = 0
    @State private var expandedByHover = false
    @State private var expandedAt: Date = .distantPast
    @State private var expandPending = false
    @State private var calendarRecenterTrigger = 0

    @AppStorage("panelWidth") private var panelWidth = 420.0
    @AppStorage("panelMaxHeight") private var panelMaxHeight = 480.0
    @AppStorage("autoCollapseDelay") private var autoCollapseDelay = 3.0
    @AppStorage("expandedInactivityAutoHideDelay") private var expandedInactivityAutoHideDelay = 10.0
    @AppStorage("hoverExitCollapseDelay") private var hoverExitCollapseDelay = 0.5
    @AppStorage("hoverToExpandPanel") private var hoverToExpandPanel = true
    @AppStorage("reduceMotion") private var reduceMotion = false
    @AppStorage("showTickerLine") private var showTickerLine = true
    @AppStorage("showLyrics") private var showLyrics = true
    @AppStorage("tickerSpeed") private var tickerSpeed = 25.0
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

    private var collapsedShapeHeight: CGFloat { IslandSizeCalculator.collapsedShapeHeight }

    /// Ticker 行高度
    private let tickerLineHeight: CGFloat = 18

    /// 是否显示 Ticker（播放中 + 设置开启 + 收起状态）
    private var showTicker: Bool {
        mediaManager.isPlaying && showTickerLine && !isExpanded
    }

    /// 收起状态总高度（含 Ticker）
    private var collapsedTotalHeight: CGFloat {
        collapsedShapeHeight + (showTicker ? tickerLineHeight + 4 : 0)
    }

    private var isExpanded: Bool { state == .expanded }

    private var expandedWidth: CGFloat {
        IslandSizeCalculator.expandedWidth(for: state, panelWidth: panelWidth)
    }

    private var expandedHeight: CGFloat {
        IslandSizeCalculator.expandedHeight(
            for: state,
            visibleSessionCount: WidgetType.enabledWidgets.count,
            panelMaxHeight: panelMaxHeight
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

    private var pillWidth: CGFloat {
        // 收起状态无会话，传 0（匹配 X Island 的 idle 状态）
        IslandSizeCalculator.pillWidth(
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
                        .opacity(pillStrokeOpacity),
                    lineWidth: 0.5
                )
            }
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
                    onTap: { expand(to: .expanded) }
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
        .onChange(of: expandedHeight) { _, _ in
            if case .expanded = state {
                cachedExpandedShapeHeight = max(collapsedShapeHeight + 1, expandedHeight)
            }
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
            // 检查是否被物理 Notch 遮挡
            if let window = NSApp.windows.first(where: { $0 is NotchWindow }) as? NotchWindow {
                islandObscuredByNotch = window.isObscuredByPhysicalNotch()
            }

            // 初始化窗口大小为收起状态
            let targetWidth = pillWidth
            let targetHeight = IslandSizeCalculator.collapsedShapeHeight
            onSizeChange?(targetWidth, targetHeight)

            if isExpanded {
                cachedExpandedShapeHeight = IslandSizeCalculator.expandedPanelShapeHeight(
                    visibleSessionCount: WidgetType.enabledWidgets.count,
                    panelMaxHeight: panelMaxHeight
                )
            }
            startHoverPolling()
        }
        .onReceive(NotificationCenter.default.publisher(for: .xnookScrollDown)) { _ in
            // 双指下滑展开面板（由 scrollDownToExpandPanel 开关控制）
            // 冷却 0.5s 防止连续滚动帧导致的抖动循环
            let cooldown: TimeInterval = 0.5
            guard !isExpanded, !collapseAnimating,
                  Date().timeIntervalSince(expandedAt) > cooldown else { return }
            expand(to: .expanded)
        }
        .onDisappear {
            stopHoverPolling()
            cancelExpandedAutoHide()
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

        let target = targetSize(for: newState)
        if case .expanded = newState {
            cachedExpandedShapeHeight = IslandSizeCalculator.expandedPanelShapeHeight(
                visibleSessionCount: WidgetType.enabledWidgets.count,
                panelMaxHeight: panelMaxHeight
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
                if let window = NSApp.windows.first(where: { $0 is NotchWindow }) as? NotchWindow {
                    window.resizeToFitCollapse(contentWidth: w, contentHeight: h)
                }
                self.collapseAnimating = false
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            finishCollapse()
        }
    }

    private func targetSize(for state: IslandState) -> (width: CGFloat, height: CGFloat) {
        // 收起状态传 0（无会话），展开状态传 widget 数量
        let sessionCount = state == .expanded ? WidgetType.enabledWidgets.count : 0
        return IslandSizeCalculator.targetSize(
            for: state,
            visibleSessionCount: sessionCount,
            panelWidth: panelWidth,
            panelMaxHeight: panelMaxHeight
        )
    }

    // MARK: - 鼠标悬停轮询

    private func startHoverPolling() {
        stopHoverPolling()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            Task { @MainActor in
                pollMousePosition()
            }
        }
    }

    private func stopHoverPolling() {
        hoverTimer?.invalidate()
        hoverTimer = nil
    }

    private func pollMousePosition() {
        guard let window = NSApp.windows.first(where: { $0 is NotchWindow }) as? NotchWindow else { return }
        guard !window.isDragging else { return }

        // 更新 notch 遮挡状态
        let obscured = window.isObscuredByPhysicalNotch()
        if obscured != islandObscuredByNotch {
            islandObscuredByNotch = obscured
        }

        let mouse = NSEvent.mouseLocation
        var hitFrame = window.frame

        // 展开时用更大的命中区域
        if isExpanded {
            hitFrame.origin.y -= 20
            hitFrame.size.height = expandedHeight + 40
            if let screen = window.screen?.visibleFrame {
                hitFrame.origin.x = max(hitFrame.origin.x, screen.minX)
                hitFrame.size.width = min(hitFrame.maxX, screen.maxX) - hitFrame.origin.x
            }
        } else {
            // 收起状态下扩展到屏幕顶部
            if let screen = window.screen?.frame {
                let screenTop = screen.maxY
                hitFrame.size.height += max(0, screenTop - hitFrame.maxY) + 1
            }
        }

        var inside = hitFrame.contains(mouse)

        if collapseAnimating { inside = false }

        // 鼠标在展开面板内时，重置自动隐藏计时器
        if inside && isExpanded {
            scheduleExpandedAutoHide()
        }

        if inside && !isExpanded {
            guard Date().timeIntervalSince(lastCollapseAt) > 0.65 else { return }
            guard hoverToExpandPanel else { return }
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

            // 始终显示紧凑网格
            widgetCompactGrid
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
            CalendarWidgetView(calendarManager: calendarManager, recenterTrigger: $calendarRecenterTrigger)
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
}

// MARK: - 收起状态视图

struct CollapsedPillView: View {
    @Environment(\.colorScheme) private var colorScheme

    let isExpanded: Bool
    let isPlaying: Bool
    let albumArt: NSImage?
    let albumArtData: Data?
    let artworkVersion: Int
    let onTap: () -> Void

    /// 从 UserDefaults 加载自定义 GIF
    private var customGifImage: NSImage? {
        guard let bookmarkData = UserDefaults.standard.data(forKey: "customGifBookmark") else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }

        // 开始访问安全作用域资源
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else { return nil }
        return NSImage(data: data)
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 0) {
                // 左侧：专辑封面
                if let artData = albumArtData, let nsImage = NSImage(data: artData) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 20, height: 20)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .id(artworkVersion) // 切歌时递增，强制 SwiftUI 重建 Image
                } else {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.1))
                        .frame(width: 20, height: 20)
                }

                Spacer(minLength: 6)

                Spacer(minLength: 6)

                // 右侧：自定义 GIF 或默认音频波形
                if let gif = customGifImage {
                    GifView(image: gif, isPlaying: isPlaying, targetSize: NSSize(width: 20, height: 20))
                        .frame(width: 20, height: 20)
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
    }
}

// MARK: - GIF 动画视图

/// GIF 动画视图 — 播放时动画，暂停时冻结
private struct GifView: NSViewRepresentable {
    let image: NSImage
    let isPlaying: Bool
    let targetSize: NSSize

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyDown
        view.image = image
        return view
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        if isPlaying {
            nsView.image = image
        } else {
            // 暂停：取第一帧作为静态图
            if let rep = image.representations.first {
                let staticImage = NSImage(size: image.size)
                staticImage.addRepresentation(rep)
                nsView.image = staticImage
            }
        }
    }
}

// MARK: - Preview

#Preview {
    NotchContentView()
        .frame(width: 420, height: 250)
        .background(Color.black)
}
