import SwiftUI
import EventKit

/// 纯内容面板，窗口与悬停逻辑由 NotchContentView 管理。
struct ExpandedPanelView: View {
    typealias Widget = NotchContentView.WidgetType

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Binding var selectedWidget: Widget?
    @Binding var calendarRecenterTrigger: Int
    let enabledWidgets: [Widget]
    let panelWidth: CGFloat
    let mediaManager: MediaManager
    let calendarManager: CalendarManager
    let notesManager: NotesManager
    let trayManager: TrayManager
    let focusSessionManager: FocusSessionManager
    let showHistory: Bool
    let historyDisplayLimit: Int
    let onCreateLinkedNote: () -> Bool
    let onLinkTrayFiles: () -> Void
    let onEndSession: () -> Void
    let onOpenNote: (UUID) -> Bool
    let onOpenFile: (LinkedFile) -> Bool
    let onStartFocus: (EKEvent) -> Void
    let onInteractionChanged: (Bool) -> Void
    /// 网页链接面板展开期间需要暂停自动收起，必须由窗口层知晓。
    let onLinksPresentationChanged: (Bool) -> Void
    let onSettings: () -> Void
    let onClose: () -> Void
    let onMeasurement: (ExpandedPanelMeasurement) -> Void
    /// 面板顶部被物理刘海遮挡的死区，由窗口层按当前屏幕推导
    var deadZone: NotchDeadZone = .none
    @AppStorage("reduceMotion") private var reduceMotion = SettingsDefaults.bool(for: "reduceMotion")

    private var shouldReduceMotion: Bool { reduceMotion || systemReduceMotion }

    var body: some View {
        VStack(spacing: 0) {
            header
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("expandedPanelHeader")
                .expandedPanelDebugFrame(id: "expandedPanelHeader")
            navigation
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("expandedPanelNavigation")
                .expandedPanelDebugFrame(id: "expandedPanelNavigation")
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: IslandTokens.Spacing.section) {
                    if selectedWidget == nil {
                        if enabledWidgets.isEmpty {
                            Text(L10n.panelNoWidgets)
                                .font(.system(size: IslandTokens.Font.body))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, IslandTokens.Spacing.group)
                        } else {
                            overview
                        }
                        focusContent
                    } else if let selectedWidget {
                        widgetView(for: selectedWidget, isDetail: true)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .frame(minHeight: 260)
                    }
                }
                .padding(IslandTokens.Spacing.standard)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: PanelContentHeightKey.self, value: ExpandedPanelMeasurement(
                            width: geometry.size.width,
                            height: geometry.size.height + ExpandedPanelLayout.headerHeight,
                            selectedWidget: selectedWidget
                        ))
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("expandedPanelBody")
            .expandedPanelDebugFrame(id: "expandedPanelBody")
            .onPreferenceChange(PanelContentHeightKey.self) { measurement in
                if let measurement { onMeasurement(measurement) }
            }
        }
        .expandedPanelDebugCoordinateSpace()
        .onExitCommand {
            if selectedWidget != nil { selectedWidget = nil }
            else { onClose() }
        }
    }

    private var header: some View {
        HStack(spacing: IslandTokens.Spacing.compact) {
            Label("Nook", systemImage: "square.grid.2x2")
                .font(.system(size: IslandTokens.Font.title, weight: .semibold, design: .rounded))
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
            Spacer(minLength: 0)
            // 头部右侧是刘海最可能覆盖的区域，把按钮整体推到死区之外。
            NotchDeadZoneSpacer(zone: deadZone)
            headerButton(icon: "gearshape", help: L10n.preferences, action: onSettings)
            headerButton(icon: "xmark", help: L10n.panelClose, action: onClose)
        }
        .padding(.horizontal, IslandTokens.Spacing.standard)
        .frame(height: IslandTokens.Layout.headerHeight)
    }

    private func headerButton(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            MotionIcon(systemName: icon, fontSize: IslandTokens.Font.body, reduceMotion: shouldReduceMotion)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    @ViewBuilder
    private var navigation: some View {
        if panelWidth < 480 {
            Picker(L10n.panelNavigation, selection: $selectedWidget) {
                Label(L10n.panelOverview, systemImage: "square.grid.2x2").tag(nil as Widget?)
                ForEach(navigationWidgets, id: \.self) { widget in
                    Label(widget.localizedName, systemImage: widget.icon).tag(Optional(widget))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .font(.system(size: IslandTokens.Font.body, weight: .medium))
            .padding(.horizontal, IslandTokens.Spacing.standard)
            .frame(height: IslandTokens.Layout.navigationHeight)
        } else {
            HStack(spacing: IslandTokens.Spacing.tight) {
                navigationButton(title: L10n.panelOverview, icon: "square.grid.2x2", widget: nil)
                ForEach(navigationWidgets, id: \.self) { widget in
                    navigationButton(title: widget.localizedName, icon: widget.icon, widget: widget)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, IslandTokens.Spacing.standard)
            .frame(height: IslandTokens.Layout.navigationHeight)
        }
    }

    /// 隐藏的工具仍可从任务记录打开；进入详情后临时保留其导航入口。
    private var navigationWidgets: [Widget] {
        guard let selectedWidget, !enabledWidgets.contains(selectedWidget) else { return enabledWidgets }
        return enabledWidgets + [selectedWidget]
    }

    private func navigationButton(title: String, icon: String, widget: Widget?) -> some View {
        let isSelected = selectedWidget == widget
        return Button { selectedWidget = widget } label: {
            Label(title, systemImage: icon)
                .font(.system(size: IslandTokens.Font.body, weight: .medium))
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(isSelected ? IslandStyle.insetFill(for: colorScheme) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: IslandTokens.Radius.control))
                .fixedSize()
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var focusContent: some View {
        FocusSessionView(
            manager: focusSessionManager,
            historyDisplayLimit: historyDisplayLimit,
            trayFileCount: trayManager.files.count,
            onCreateLinkedNote: onCreateLinkedNote,
            onLinkTrayFiles: onLinkTrayFiles,
            onEndSession: onEndSession,
            showHistory: showHistory,
            onOpenNote: onOpenNote,
            onOpenFile: onOpenFile,
            onInteractionChanged: onInteractionChanged,
            onLinksPresentationChanged: onLinksPresentationChanged
        )
        .background(IslandStyle.cardRest(for: colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: IslandTokens.Radius.card))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("expandedPanelRecentTasks")
        .expandedPanelDebugFrame(id: "expandedPanelRecentTasks")
    }

    private var overview: some View {
        let count = ExpandedPanelLayout.columnCount(width: panelWidth, widgetCount: enabledWidgets.count)
        return PanelWidgetGrid(columns: count, spacing: IslandTokens.Spacing.standard) {
            ForEach(enabledWidgets, id: \.self) { widget in
                widgetView(for: widget, isDetail: false)
                    .padding(IslandTokens.Spacing.standard)
                    .frame(maxWidth: .infinity)
                    .background(IslandStyle.cardRest(for: colorScheme))
                    .clipShape(RoundedRectangle(cornerRadius: IslandTokens.Radius.card))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("expandedPanelWidget-\(widget.rawValue)")
                    .expandedPanelDebugFrame(id: "expandedPanelWidget-\(widget.rawValue)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("expandedPanelWidgets")
        .expandedPanelDebugFrame(id: "expandedPanelWidgets")
    }

    @ViewBuilder
    private func widgetView(for widget: Widget, isDetail: Bool) -> some View {
        switch widget {
        case .media:
            MediaWidgetView(mediaManager: mediaManager, isDetail: isDetail)
        case .calendar:
            CalendarWidgetView(
                calendarManager: calendarManager,
                recenterTrigger: $calendarRecenterTrigger,
                onStartFocus: onStartFocus,
                isDetail: isDetail,
                onShowAll: { selectedWidget = .calendar }
            )
        case .notes:
            NotesWidgetView(notesManager: notesManager, isDetail: isDetail, onShowAll: { selectedWidget = .notes }, onInteractionChanged: onInteractionChanged)
        case .tray:
            TrayWidgetView(trayManager: trayManager, isDetail: isDetail, onShowAll: { selectedWidget = .tray })
        }
    }
}

struct ExpandedPanelDebugGeometryKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

private struct ExpandedPanelDebugGeometryEnabledKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var reportsExpandedPanelDebugGeometry: Bool {
        get { self[ExpandedPanelDebugGeometryEnabledKey.self] }
        set { self[ExpandedPanelDebugGeometryEnabledKey.self] = newValue }
    }
}

extension View {
    @ViewBuilder
    fileprivate func expandedPanelDebugCoordinateSpace() -> some View {
        #if DEBUG
        coordinateSpace(name: "expandedPanelDebugGeometry")
        #else
        self
        #endif
    }

    @ViewBuilder
    func expandedPanelDebugFrame(id: String) -> some View {
        #if DEBUG
        modifier(ExpandedPanelDebugGeometryModifier(id: id))
        #else
        self
        #endif
    }
}

#if DEBUG
/// 离屏渲染不提供 SwiftUI 虚拟 AX 节点；诊断开启时从真实视图读取几何，发布构建不编译此层。
private struct ExpandedPanelDebugGeometryModifier: ViewModifier {
    let id: String
    @Environment(\.reportsExpandedPanelDebugGeometry) private var enabled

    func body(content: Content) -> some View {
        content.background {
            if enabled {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: ExpandedPanelDebugGeometryKey.self,
                        value: [id: geometry.frame(in: .named("expandedPanelDebugGeometry"))]
                    )
                }
            }
        }
    }
}
#endif

private struct PanelContentHeightKey: PreferenceKey {
    static var defaultValue: ExpandedPanelMeasurement? = nil
    static func reduce(value: inout ExpandedPanelMeasurement?, nextValue: () -> ExpandedPanelMeasurement?) {
        if let next = nextValue(), next.matches(width: next.width, selectedWidget: next.selectedWidget) {
            value = next
        }
    }
}

/// 同一层级的组件保留视图身份，每行以自然高度最高的卡片为准。
struct PanelWidgetGrid: Layout {
    var columns: Int
    var spacing: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = resolvedWidth(proposal.width, subviews: subviews)
        let heights = rowHeights(width: width, subviews: subviews)
        return CGSize(width: width, height: heights.reduce(0, +) + CGFloat(max(0, heights.count - 1)) * spacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let count = max(1, columns)
        let cellWidth = max(0, (bounds.width - CGFloat(count - 1) * spacing) / CGFloat(count))
        let heights = rowHeights(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for index in subviews.indices {
            let row = index / count
            let column = index % count
            if column == 0, row > 0 { y += heights[row - 1] + spacing }
            subviews[index].place(
                at: CGPoint(x: bounds.minX + CGFloat(column) * (cellWidth + spacing), y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: cellWidth, height: heights[row])
            )
        }
    }

    private func resolvedWidth(_ proposed: CGFloat?, subviews: Subviews) -> CGFloat {
        if let proposed, proposed.isFinite { return max(0, proposed) }
        let cellWidth = subviews.map { $0.sizeThatFits(.unspecified).width }.filter(\.isFinite).max() ?? 0
        return cellWidth * CGFloat(max(1, columns)) + CGFloat(max(0, columns - 1)) * spacing
    }

    private func rowHeights(width: CGFloat, subviews: Subviews) -> [CGFloat] {
        let count = max(1, columns)
        let cellWidth = max(0, (width - CGFloat(count - 1) * spacing) / CGFloat(count))
        var heights: [CGFloat] = []
        for index in subviews.indices {
            let height = subviews[index].sizeThatFits(ProposedViewSize(width: cellWidth, height: nil)).height
            if index % count == 0 { heights.append(0) }
            heights[index / count] = max(heights[index / count], height.isFinite ? max(0, height) : 0)
        }
        return heights
    }
}
