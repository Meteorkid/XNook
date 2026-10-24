import SwiftUI
import EventKit
import AppKit

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
    var layoutStore: PanelLayoutStore? = nil
    var editRequest: Int = 0
    var onEditRequestHandled: () -> Void = {}
    var onEditingChanged: (Bool) -> Void = { _ in }
    @State private var layoutEditor = PanelLayoutEditingSession()
    @State private var layoutSelection: PanelModuleID = .media
    @State private var interactingModules: Set<PanelModuleID> = []
    @State private var linkingModules: Set<PanelModuleID> = []
    @State private var confirmsLayoutRecovery = false
    @State private var layoutRecoveryError: String?
    @State private var layoutEntryError: String?

    private var dashboardConfiguration: PanelLayoutConfiguration {
        layoutEditor.isEditing ? layoutEditor.draft : layoutStore?.configuration
            ?? .legacy(enabledWidgetIDs: Set(enabledWidgets.map(\.rawValue)), showHistory: showHistory)
    }
    private var layoutSignature: String { layoutStore == nil ? "" : dashboardConfiguration.signature }

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
                    if selectedWidget == nil, let layoutStore {
                        if let layoutEntryError { Text(layoutEntryError).font(.caption).foregroundStyle(.secondary) }
                        if layoutEditor.isEditing {
                            PanelLayoutEditorToolbar(editor: layoutEditor, selection: $layoutSelection,
                                onSave: { _ = layoutEditor.save(to: layoutStore) }, onCancel: layoutEditor.cancel)
                        } else if let issue = layoutRecoveryError ?? layoutStore.loadError {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(issue).font(.caption).foregroundStyle(.secondary)
                                Button(L10n.localized(zh: "恢复默认布局…", en: "Restore Default Layout…")) { confirmsLayoutRecovery = true }
                            }
                        }
                        PanelDashboardGrid(
                            configuration: Binding(get: { dashboardConfiguration }, set: { if layoutEditor.isEditing { layoutEditor.draft = $0 } }),
                            selection: $layoutSelection, width: max(1, panelWidth - ExpandedPanelLayout.outerPadding * 2),
                            isEditing: layoutEditor.isEditing, summary: moduleSummary
                        ) { item, size in moduleView(item.id, size: size) }
                    } else if selectedWidget == nil {
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
                            selectedWidget: selectedWidget,
                            enabledWidgets: enabledWidgets,
                            layoutSignature: layoutSignature,
                            isEditingLayout: layoutEditor.isEditing
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
        .onAppear { handleEditRequest() }
        .onChange(of: editRequest) { _, _ in handleEditRequest() }
        .onChange(of: layoutEditor.isEditing) { _, editing in
            onEditingChanged(editing)
            reportInteractions()
        }
        .onChange(of: confirmsLayoutRecovery) { _, _ in reportInteractions() }
        .onChange(of: dashboardConfiguration.signature) { _, _ in
            reportInteractions()
            onLinksPresentationChanged(!linkingModules.intersection(visibleModuleIDs).isEmpty)
        }
        .onDisappear { onEditingChanged(false); onInteractionChanged(false); onLinksPresentationChanged(false) }
        .alert(L10n.localized(zh: "恢复默认布局？", en: "Restore Default Layout?"), isPresented: $confirmsLayoutRecovery) {
            Button(L10n.localized(zh: "取消", en: "Cancel"), role: .cancel) {}
            Button(L10n.localized(zh: "恢复默认", en: "Restore")) {
                do { try layoutStore?.reset(); layoutRecoveryError = nil }
                catch { layoutRecoveryError = error.localizedDescription }
            }
        } message: {
            Text(L10n.localized(zh: "只重置组件排列，原布局会留作备份；笔记、文件和任务不受影响。", en: "Only the layout is reset and backed up. Notes, files and tasks are retained."))
        }
        .onExitCommand {
            if layoutEditor.isEditing { layoutEditor.cancel() }
            else if selectedWidget != nil { selectedWidget = nil }
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
            headerButton(icon: "xmark", help: L10n.panelClose, action: { layoutEditor.cancel(); onClose() })
        }
        .padding(.horizontal, IslandTokens.Spacing.standard)
        .frame(height: IslandTokens.Layout.headerHeight)
    }

    private func headerButton(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            MotionIcon(systemName: icon, fontSize: IslandTokens.Font.body, reduceMotion: shouldReduceMotion)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private var navigation: some View {
        HStack(spacing: 8) {
            if panelWidth < 640 {
                Picker(L10n.panelNavigation, selection: $selectedWidget) {
                    Label(L10n.panelOverview, systemImage: "square.grid.2x2").tag(nil as Widget?)
                    ForEach(navigationWidgets, id: \.self) { widget in
                        Label(widget.localizedName, systemImage: widget.icon).tag(Optional(widget))
                    }
                }.pickerStyle(.menu).labelsHidden().disabled(layoutEditor.isEditing)
            } else {
                HStack(spacing: IslandTokens.Spacing.tight) {
                    navigationButton(title: L10n.panelOverview, icon: "square.grid.2x2", widget: nil)
                    ForEach(navigationWidgets, id: \.self) { widget in
                        navigationButton(title: widget.localizedName, icon: widget.icon, widget: widget)
                    }
                }.disabled(layoutEditor.isEditing)
            }
            Spacer(minLength: 0)
            if layoutStore != nil, !layoutEditor.isEditing, selectedWidget == nil {
                Button(action: beginLayoutEditing) {
                    Image(systemName: "rectangle.3.group").frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.localized(zh: "编辑布局", en: "Edit Layout"))
                .accessibilityLabel(L10n.localized(zh: "编辑布局", en: "Edit Layout"))
                .accessibilityIdentifier("panelLayoutBegin")
                .disabled(layoutStore?.canEdit != true)
            }
        }
        .padding(.horizontal, ExpandedPanelLayout.outerPadding)
        .frame(height: IslandTokens.Layout.navigationHeight)
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
            onInteractionChanged: { reportModuleInteraction(.currentTask, active: $0) },
            onLinksPresentationChanged: { reportModuleLinks(.currentTask, active: $0) }
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
            NotesWidgetView(notesManager: notesManager, isDetail: isDetail, onShowAll: { selectedWidget = .notes }, onInteractionChanged: { reportModuleInteraction(.notes, active: $0) })
        case .tray:
            TrayWidgetView(trayManager: trayManager, isDetail: isDetail, onShowAll: { selectedWidget = .tray })
        }
    }
    private func beginLayoutEditing() {
        guard let layoutStore else { return }
        guard linkingModules.isEmpty else {
            layoutEntryError = L10n.localized(zh: "请先完成网页链接编辑，再调整布局。", en: "Finish editing the task links before changing the layout.")
            return
        }
        guard !notesManager.isEditing || notesManager.closeEditor() else { return }
        layoutEntryError = nil
        selectedWidget = nil
        layoutEditor.begin(from: layoutStore)
        if layoutEditor.isEditing { NSApp.keyWindow?.makeFirstResponder(nil) }
    }

    private func handleEditRequest() {
        guard editRequest > 0 else { return }
        beginLayoutEditing()
        onEditRequestHandled()
    }

    private var visibleModuleIDs: Set<PanelModuleID> { Set(dashboardConfiguration.visibleItems.map(\.id)) }

    private func reportModuleInteraction(_ id: PanelModuleID, active: Bool) {
        if active { interactingModules.insert(id) } else { interactingModules.remove(id) }
        reportInteractions()
    }
    private func reportModuleLinks(_ id: PanelModuleID, active: Bool) {
        if active { linkingModules.insert(id) } else { linkingModules.remove(id) }
        onLinksPresentationChanged(!linkingModules.intersection(visibleModuleIDs).isEmpty)
    }
    private func reportInteractions() {
        onInteractionChanged(layoutEditor.isEditing || confirmsLayoutRecovery || !interactingModules.intersection(visibleModuleIDs).isEmpty)
    }

    private func moduleSummary(_ id: PanelModuleID) -> String {
        switch id {
        case .media: return mediaManager.currentTitle.isEmpty ? L10n.localized(zh: "播放与歌词", en: "Playback and lyrics") : mediaManager.currentTitle
        case .calendar: return calendarManager.displayedDate.formatted(date: .abbreviated, time: .omitted)
        case .notes: return "\(notesManager.notes.count) " + L10n.localized(zh: "条笔记", en: "notes")
        case .tray: return "\(trayManager.files.count) " + L10n.localized(zh: "个文件", en: "files")
        case .currentTask: return focusSessionManager.activeSession?.title ?? L10n.flowTaskPlaceholder
        case .recentTasks: return "\(focusSessionManager.history.count) " + L10n.localized(zh: "条任务记录", en: "tasks")
        }
    }

    @ViewBuilder
    private func moduleView(_ id: PanelModuleID, size: CGSize) -> some View {
        switch id {
        case .media:
            MediaWidgetView(mediaManager: mediaManager, isDetail: false, onShowAll: { selectedWidget = .media }, availableHeight: size.height)
        case .calendar:
            CalendarWidgetView(calendarManager: calendarManager, recenterTrigger: $calendarRecenterTrigger,
                onStartFocus: onStartFocus, isDetail: false, onShowAll: { selectedWidget = .calendar }, availableHeight: size.height)
        case .notes:
            NotesWidgetView(notesManager: notesManager, isDetail: false, onShowAll: { selectedWidget = .notes },
                onInteractionChanged: { reportModuleInteraction(.notes, active: $0) }, availableHeight: size.height)
        case .tray:
            TrayWidgetView(trayManager: trayManager, isDetail: false, onShowAll: { selectedWidget = .tray }, availableHeight: size.height)
        case .currentTask, .recentTasks:
            FocusSessionView(manager: focusSessionManager, historyDisplayLimit: historyDisplayLimit,
                trayFileCount: trayManager.files.count, onCreateLinkedNote: onCreateLinkedNote,
                onLinkTrayFiles: onLinkTrayFiles, onEndSession: onEndSession, showHistory: true,
                onOpenNote: onOpenNote, onOpenFile: onOpenFile,
                onInteractionChanged: { reportModuleInteraction(id, active: $0) },
                onLinksPresentationChanged: { reportModuleLinks(id, active: $0) },
                section: id == .currentTask ? .currentTask : .recentTasks, availableHeight: size.height)
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
        if let next = nextValue(), next.matches(width: next.width, selectedWidget: next.selectedWidget, enabledWidgets: next.enabledWidgets, layoutSignature: next.layoutSignature, isEditingLayout: next.isEditingLayout) {
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
