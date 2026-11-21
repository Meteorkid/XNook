import SwiftUI
import EventKit
import AppKit

/// 纯内容面板，窗口与悬停逻辑由 NotchContentView 管理。
struct ExpandedPanelView: View {
    typealias Widget = NotchContentView.WidgetType

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.mediaAmbientAnimationEnabled) private var ambientAnimationEnabled
    @Binding var selectedWidget: Widget?
    /// 媒体卡片形变状态，由外壳 `NotchContentView` 持有（换页前要先写源矩形）。
    @ObservedObject var cardMorph: PanelCardMorphStore
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
    var focusResources: FocusResourceCoordinator? = nil
    var pendingTasks: PendingTaskCoordinator? = nil
    var activityCoordinator: PanelActivityCoordinator? = nil
    var onEditingChanged: (Bool) -> Void = { _ in }
    @State private var showsFallbackInbox = false
    @State private var layoutEditor = PanelLayoutEditingSession()
    @State private var layoutSelection: PanelModuleID = .media
    @State private var interactingModules: Set<PanelModuleID> = []
    @State private var linkingModules: Set<PanelModuleID> = []
    @State private var confirmsLayoutRecovery = false
    @State private var layoutRecoveryError: String?
    @State private var layoutEntryError: String?
    @State private var editorToolbarHeight: CGFloat = 0
    @State private var showsLayoutLibrary = false
    @State private var layoutProfiles: PanelLayoutProfileStore?
    /// 两端卡片坐标系（面板内容区左上角），保证两个页面量出来的矩形可以直接比较。
    static let cardSpace = "panelMediaCardSpace"

    private var dashboardConfiguration: PanelLayoutConfiguration {
        layoutEditor.isEditing ? layoutEditor.draft : layoutStore?.configuration
            ?? .legacy(enabledWidgetIDs: Set(enabledWidgets.map(\.rawValue)), showHistory: showHistory)
    }
    private var usesDefaultContentFit: Bool {
        layoutStore?.shouldFitDefaultContent(automaticallyFit: PanelHeightMode.fitsDefaultContent(
            storedValue: panelHeightMode, legacyAutomaticallyFit: panelAutoSize),
            isEditing: layoutEditor.isEditing, isOverview: selectedWidget == nil) == true
    }
    private var layoutSignature: String {
        layoutStore == nil ? "" : PanelGridGeometry.measurementSignature(
            for: dashboardConfiguration, fitsContent: usesDefaultContentFit)
    }

    @AppStorage("panelAutoSize") private var panelAutoSize = SettingsDefaults.bool(for: "panelAutoSize")
    @AppStorage("panelHeightMode") private var panelHeightMode = SettingsDefaults.string(for: "panelHeightMode")
    @AppStorage("showTaskInboxShortcut") private var showTaskInboxShortcut = SettingsDefaults.bool(for: "showTaskInboxShortcut", fallback: true)
    @AppStorage("reduceMotion") private var reduceMotion = SettingsDefaults.bool(for: "reduceMotion")
    @AppStorage("islandBackgroundStyle") private var backgroundStyle = SettingsDefaults.string(for: "islandBackgroundStyle")

    private var shouldReduceMotion: Bool { reduceMotion || systemReduceMotion }
    private var usesCompactDetailHeader: Bool { selectedWidget != nil && panelWidth < 240 }
    private var showsLayoutEditorButton: Bool {
        layoutStore != nil && !layoutEditor.isEditing && !usesCompactDetailHeader
    }
    private var headerTopInset: CGFloat {
        ExpandedPanelLayout.headerTopInset(
            width: panelWidth,
            deadZoneWidth: deadZone.width,
            deadZoneHeight: deadZone.height,
            toolbarWidth: max(showsLayoutEditorButton ? 94 : 60,
                selectedWidget == nil ? 0 : usesCompactDetailHeader ? 68 : 100)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("expandedPanelHeader")
                .expandedPanelDebugFrame(id: "expandedPanelHeader")
            Divider()
                .frame(height: 1)
            if layoutEditor.isEditing {
                PanelLayoutEditorToolbar(editor: layoutEditor, selection: $layoutSelection,
                    onSave: { if let layoutStore { _ = layoutEditor.save(to: layoutStore) } },
                    onCancel: layoutEditor.cancel, availableWidth: panelWidth,
                    onShowLibrary: {
                        if let layoutStore {
                            layoutProfiles = PanelLayoutProfileStore(defaults: layoutStore.defaults)
                            showsLayoutLibrary = true
                        }
                    })
                    .clipShape(RoundedRectangle(cornerRadius: IslandTokens.Radius.sheet))
                    .padding(.horizontal, ExpandedPanelLayout.outerPadding)
                    .padding(.top, ExpandedPanelLayout.outerPadding)
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(key: PanelEditorToolbarHeightKey.self, value: geometry.size.height)
                        }
                    }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: IslandTokens.Spacing.compact) {
                    if let activityCoordinator, let event = activityCoordinator.current {
                        PanelActivitySummaryView(event: event,
                            onDismiss: { activityCoordinator.dismissCurrent(event) },
                            onAction: { activityCoordinator.performCurrentAction(event) })
                            .accessibilityIdentifier("panelActivitySummary")
                    }
                    // 两页叠在同一位置，且**硬切**，不做交叉淡入。
                    //
                    // 1.1.4.2 试过三种写法，只有硬切能保证新页一次铺开：
                    //    a. 作为 VStack 兄弟节点 → 转场期间两页同时占位，高度先涨到两页之和再回落；
                    //    b. 叠放 + 交叉淡入 → 退场中的旧页仍按旧宽度布局，被窄容器裁掉右半截；
                    //    c. 叠放 + 硬切 → 新页在正确的宽度下一次性铺开。
                    // 1.4.4 给媒体卡片加英雄转场时又踩了一次：`matchedGeometryEffect` 在这个
                    // 自定义 Layout（`PanelDashboardLayout` 直接 place 到算好的 frame）里不插值，
                    // 卡片是一帧到位的；而 `.animation(value:)` 还会给页面切换套上默认的
                    // 透明度转场，于是详情页半透明地叠在概览上，出现重影。
                    // 现在改成显式几何：见 `CardMorphIn`，由它把卡片从源矩形缩放到自身矩形。
                    ZStack(alignment: .topLeading) {
                        if selectedWidget == nil {
                            overviewPage
                        } else if let selectedWidget {
                            detailPage(selectedWidget)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .coordinateSpace(name: Self.cardSpace)
                    .onPreferenceChange(MediaCardFrameKey.self) { frames in
                        cardMorph.frames.merge(frames) { _, new in new }
                    }
                }
                .padding(ExpandedPanelLayout.outerPadding)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: PanelContentHeightKey.self, value: ExpandedPanelMeasurement(
                            width: geometry.size.width,
                            height: geometry.size.height + ExpandedPanelLayout.headerHeight + headerTopInset
                                + (layoutEditor.isEditing ? editorToolbarHeight : 0),
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
        .onPreferenceChange(PanelEditorToolbarHeightKey.self) { height in
            guard height.isFinite, height >= 0, abs(editorToolbarHeight - height) > 0.5 else { return }
            editorToolbarHeight = height
        }
        .onAppear { handleEditRequest() }
        .onChange(of: editRequest) { _, _ in handleEditRequest() }
        .onChange(of: layoutEditor.isEditing) { _, editing in
            onEditingChanged(editing)
            reportInteractions()
        }
        .onChange(of: confirmsLayoutRecovery) { _, _ in reportInteractions() }
        .onChange(of: showsFallbackInbox) { _, _ in reportInteractions() }
        .onChange(of: showTaskInboxShortcut) { _, enabled in
            if !enabled { showsFallbackInbox = false }
        }
        .onChange(of: showsLayoutLibrary) { _, _ in reportInteractions() }
        .onChange(of: dashboardConfiguration.signature) { _, _ in
            reportInteractions()
            onLinksPresentationChanged(!linkingModules.intersection(visibleModuleIDs).isEmpty)
        }
        .onDisappear { onEditingChanged(false); onInteractionChanged(false); onLinksPresentationChanged(false) }
        .popover(isPresented: $showsLayoutLibrary) {
            if let layoutProfiles {
                PanelLayoutLibraryView(store: layoutProfiles, currentLayout: layoutEditor.draft,
                    isEditing: true, hasUnsavedChanges: layoutEditor.hasChanges,
                    onApply: { configuration in
                        try configuration.validate()
                        layoutEditor.draft = configuration
                        layoutSelection = configuration.visibleItems.first?.id ?? .media
                        showsLayoutLibrary = false
                    }, onClose: { showsLayoutLibrary = false })
            }
        }
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
            if showsLayoutLibrary { showsLayoutLibrary = false }
            else if layoutEditor.isEditing { layoutEditor.cancel() }
            else if selectedWidget != nil { select(nil) }
            else { onClose() }
        }
    }

    private var header: some View {
        VStack(spacing: 0) {
            if headerTopInset > 0 {
                Color.clear
                    .frame(height: headerTopInset)
                    .allowsHitTesting(false)
            }
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    if deadZone.isPresent && headerTopInset == 0 {
                        let sideWidth = max(0, (geometry.size.width - ExpandedPanelLayout.outerPadding * 2 - deadZone.width) / 2)
                        navigation.frame(width: sideWidth, alignment: .leading)
                        NotchDeadZoneSpacer(zone: deadZone)
                        toolbarActions.frame(width: sideWidth, alignment: .trailing)
                    } else {
                        HStack(spacing: IslandTokens.Spacing.compact) {
                            navigation
                            toolbarActions
                        }
                    }
                }
                .padding(.horizontal, ExpandedPanelLayout.outerPadding)
                .frame(height: IslandTokens.Layout.headerHeight)
            }
            .frame(height: IslandTokens.Layout.headerHeight)
        }
        .frame(height: IslandTokens.Layout.headerHeight + headerTopInset)
    }

    private var toolbarActions: some View {
        HStack(spacing: IslandTokens.Spacing.compact) {
            if showsLayoutEditorButton {
                headerButton(icon: "rectangle.3.group", help: L10n.localized(zh: "编辑布局", en: "Edit Layout"), action: beginLayoutEditing)
                    .accessibilityIdentifier("panelLayoutBegin")
                    .expandedPanelDebugFrame(id: "panelLayoutBegin")
                    .disabled(layoutStore?.canEdit != true)
            }
            headerButton(icon: "gearshape", help: L10n.preferences, action: onSettings)
                .expandedPanelDebugFrame(id: "expandedPanelSettings")
            headerButton(icon: "xmark", help: layoutEditor.hasChanges
                ? L10n.localized(zh: "放弃布局更改并收起面板", en: "Discard layout changes and close panel")
                : L10n.panelClose, action: { layoutEditor.cancel(); onClose() })
                .expandedPanelDebugFrame(id: "expandedPanelClose")
        }
        .fixedSize()
    }

    private func headerButton(icon: String, help: String, action: @escaping () -> Void) -> some View {
        PanelHeaderButton(icon: icon, title: help, reduceMotion: shouldReduceMotion, action: action)
    }

    private var navigation: some View {
        Group {
            if selectedWidget != nil {
                Button {
                    guard !notesManager.isEditing || notesManager.closeEditor() else { return }
                    select(nil)
                } label: {
                    HStack(spacing: usesCompactDetailHeader ? 4 : 8) {
                        Image(systemName: "square.grid.2x2")
                        Text(L10n.panelOverview).lineLimit(1)
                    }
                        .font(.system(size: usesCompactDetailHeader ? 12 : IslandTokens.Font.body, weight: .medium))
                        .padding(.horizontal, usesCompactDetailHeader ? 4 : 8)
                        .frame(minHeight: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help(L10n.panelBack)
                .accessibilityLabel(L10n.panelOverview)
                .accessibilityIdentifier("expandedPanelOverview")
                .expandedPanelDebugFrame(id: "expandedPanelOverview")
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: IslandTokens.Spacing.compact) {
                        Text("Nook")
                            .font(.system(size: IslandTokens.Font.title, weight: .semibold, design: .rounded))
                        navigationButtons(showsTitles: true)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    navigationButtons(showsTitles: true)
                        .fixedSize(horizontal: true, vertical: false)
                    navigationButtons(showsTitles: false)
                        .fixedSize(horizontal: true, vertical: false)
                    navigationMenu
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("expandedPanelNavigation")
        .disabled(layoutEditor.isEditing)
        .expandedPanelDebugFrame(id: "expandedPanelNavigation")
    }

    private func navigationButtons(showsTitles: Bool) -> some View {
        HStack(spacing: IslandTokens.Spacing.tight) {
            navigationButton(title: L10n.panelOverview, icon: "square.grid.2x2", widget: nil, showsTitle: showsTitles)
            ForEach(navigationWidgets, id: \.self) { widget in
                navigationButton(title: widget.localizedName, icon: widget.icon, widget: widget, showsTitle: showsTitles)
            }
        }
    }

    private var navigationMenu: some View {
        Menu {
            Picker(L10n.panelNavigation, selection: selectionBinding) {
                Label(L10n.panelOverview, systemImage: "square.grid.2x2").tag(nil as Widget?)
                ForEach(navigationWidgets, id: \.self) { widget in
                    Label(widget.localizedName, systemImage: widget.icon).tag(Optional(widget))
                }
            }
        } label: {
            HStack(spacing: IslandTokens.Spacing.inline) {
                Image(systemName: selectedWidget?.icon ?? "square.grid.2x2")
                Image(systemName: "chevron.down")
                    .font(.system(size: IslandTokens.Font.micro, weight: .semibold))
            }
            .font(.system(size: IslandTokens.Font.body, weight: .medium))
            .frame(width: 36, height: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L10n.panelNavigation)
        .accessibilityLabel(L10n.panelNavigation)
    }

    /// 隐藏的工具仍可从任务记录打开；进入详情后临时保留其导航入口。
    private var navigationWidgets: [Widget] {
        guard let selectedWidget, !enabledWidgets.contains(selectedWidget) else { return enabledWidgets }
        return enabledWidgets + [selectedWidget]
    }

    private func navigationButton(title: String, icon: String, widget: Widget?, showsTitle: Bool) -> some View {
        let isSelected = selectedWidget == widget
        return Button { select(widget) } label: {
            HStack(spacing: IslandTokens.Spacing.inline) {
                Image(systemName: icon)
                if showsTitle { Text(title) }
            }
            .font(.system(size: IslandTokens.Font.body, weight: .medium))
            .padding(.horizontal, showsTitle ? 8 : 0)
            .frame(minWidth: 28, minHeight: 28)
            .background(isSelected ? IslandStyle.insetFill(for: colorScheme) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: IslandTokens.Radius.control))
            .fixedSize()
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
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
            onLinksPresentationChanged: { reportModuleLinks(.currentTask, active: $0) },
            resources: focusResources, pendingTasks: pendingTasks
        )
        .padding(ExpandedPanelLayout.cardPadding)
        .background(moduleFill, in: RoundedRectangle(cornerRadius: IslandTokens.Radius.sheet))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("expandedPanelRecentTasks")
        .expandedPanelDebugFrame(id: "expandedPanelRecentTasks")
    }

    /// 概览页：配置了布局时走仪表盘网格，否则退回旧的等分概览 + 任务卡。
    @ViewBuilder
    private var overviewPage: some View {
        if let layoutStore {
            if let layoutEntryError { Text(layoutEntryError).font(.caption).foregroundStyle(.secondary) }
            if !layoutEditor.isEditing, let issue = layoutRecoveryError ?? layoutStore.loadError {
                VStack(alignment: .leading, spacing: 8) {
                    Text(issue).font(.caption).foregroundStyle(.secondary)
                    Button(L10n.localized(zh: "恢复默认布局…", en: "Restore Default Layout…")) { confirmsLayoutRecovery = true }
                }
            }
            PanelDashboardGrid(
                configuration: Binding(get: { dashboardConfiguration }, set: { if layoutEditor.isEditing { layoutEditor.draft = $0 } }),
                selection: $layoutSelection, width: max(1, panelWidth - ExpandedPanelLayout.outerPadding * 2),
                isEditing: layoutEditor.isEditing, summary: moduleSummary, moduleFill: moduleFill,
                fitsContent: usesDefaultContentFit
            ) { item, size in moduleView(item.id, size: size) }
            if showTaskInboxShortcut, let pendingTasks, !layoutEditor.isEditing,
               !visibleModuleIDs.contains(.currentTask), !visibleModuleIDs.contains(.recentTasks) {
                Button { showsFallbackInbox = true } label: {
                    Label("\(L10n.inboxShortTitle) \(pendingTasks.visibleTasks.count)", systemImage: "tray")
                }
                .accessibilityLabel(L10n.inboxTitle)
                .accessibilityIdentifier("panelTaskInboxFallback")
                .expandedPanelDebugFrame(id: "panelTaskInboxFallback")
                .popover(isPresented: $showsFallbackInbox) {
                    TaskInboxView(coordinator: pendingTasks, onClose: { showsFallbackInbox = false })
                }
            }
        } else {
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
        }
    }

    private func detailPage(_ widget: Widget) -> some View {
        let card = widgetView(for: widget, isDetail: true)
            .padding(ExpandedPanelLayout.cardPadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(moduleFill, in: RoundedRectangle(cornerRadius: IslandTokens.Radius.sheet))
        return Group {
            if widget == .media {
                card
                    .modifier(MediaCardFrameReporter(isDetail: true))
                    .modifier(CardMorphIn(source: cardMorph.source(forDetail: true)))
            } else {
                card
            }
        }
    }

    // MARK: - 换页

    /// 换页时给卡片英雄转场准备源矩形。
    ///
    /// 必须**先**写形变、**再**改 `selectedWidget`，两处在同一个 runloop 里 SwiftUI 会合并成
    /// 一次求值，详情卡片首帧就带着正确的 source；晚一拍补的话首帧已经是终态，动画整段不会出现。
    private func select(_ widget: Widget?) {
        guard widget != selectedWidget else { return }
        cardMorph.beginTransition(toDetail: widget == .media ? true : (widget == nil ? false : nil))
        selectedWidget = widget
    }

    /// 菜单里的 Picker 只能拿到 Binding，套一层让选择走同一条路径。
    private var selectionBinding: Binding<Widget?> {
        Binding(get: { selectedWidget }, set: { select($0) })
    }

    private var overview: some View {
        let count = ExpandedPanelLayout.columnCount(width: panelWidth, widgetCount: enabledWidgets.count)
        let mediaColumn = count == enabledWidgets.count ? enabledWidgets.firstIndex(of: .media) : nil
        return PanelWidgetGrid(columns: count, emphasizedColumn: mediaColumn) {
            ForEach(enabledWidgets, id: \.self) { widget in
                widgetView(for: widget, isDetail: false)
                    .padding(ExpandedPanelLayout.cardPadding)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(moduleFill, in: RoundedRectangle(cornerRadius: IslandTokens.Radius.sheet))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("expandedPanelWidget-\(widget.rawValue)")
                    .expandedPanelDebugFrame(id: "expandedPanelWidget-\(widget.rawValue)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("expandedPanelWidgets")
        .expandedPanelDebugFrame(id: "expandedPanelWidgets")
    }

    private var moduleFill: Color {
        let style = IslandBackgroundStyle.resolved(from: backgroundStyle)
        let glass = IslandBackgroundPolicy.usesGlass(style: style,
            supportsGlass: IslandCapabilities.supportsLiquidGlass && IslandCapabilities.useLiquidGlassBackground,
            isDark: colorScheme == .dark, reduceTransparency: reduceTransparency)
        return glass ? Color.black.opacity(0.18)
            : (colorScheme == .dark ? Color(white: 17.0 / 255.0) : Color(white: 0.92))
    }

    @ViewBuilder
    private func widgetView(for widget: Widget, isDetail: Bool) -> some View {
        switch widget {
        case .media:
            MediaWidgetView(mediaManager: mediaManager, isDetail: isDetail, onShowAll: { select(.media) })
        case .calendar:
            CalendarWidgetView(
                calendarManager: calendarManager,
                recenterTrigger: $calendarRecenterTrigger,
                onStartFocus: onStartFocus,
                isDetail: isDetail,
                onShowAll: { select(.calendar) }
            )
        case .notes:
            NotesWidgetView(notesManager: notesManager, isDetail: isDetail, onShowAll: { select(.notes) }, onInteractionChanged: { reportModuleInteraction(.notes, active: $0) })
        case .tray:
            TrayWidgetView(trayManager: trayManager, isDetail: isDetail, onShowAll: { select(.tray) })
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
        select(nil)
        layoutEditor.begin(from: layoutStore)
        if layoutEditor.isEditing {
            if !layoutEditor.draft.visibleItems.contains(where: { $0.id == layoutSelection }) {
                layoutSelection = layoutEditor.draft.visibleItems.first?.id ?? .media
            }
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
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
        onInteractionChanged(layoutEditor.isEditing || confirmsLayoutRecovery || showsFallbackInbox || showsLayoutLibrary
            || !interactingModules.intersection(visibleModuleIDs).isEmpty)
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
            MediaWidgetView(mediaManager: mediaManager, isDetail: false, onShowAll: { select(.media) }, availableHeight: size.height)
                .environment(\.mediaAmbientAnimationEnabled,
                    ambientAnimationEnabled && visibleModuleIDs.contains(.media) && !layoutEditor.isEditing)
                // 概览端的矩形上报 + 反向变形（从详情卡片缩回网格位置）。
                // 只在非编辑态挂，避免布局编辑器里的预览卡跟着动。
                .modifier(MediaCardFrameReporter(isDetail: false, enabled: !layoutEditor.isEditing))
                .modifier(CardMorphIn(source: layoutEditor.isEditing ? nil
                    : cardMorph.source(forDetail: false)))
        case .calendar:
            CalendarWidgetView(calendarManager: calendarManager, recenterTrigger: $calendarRecenterTrigger,
                onStartFocus: onStartFocus, isDetail: false, onShowAll: { select(.calendar) }, availableHeight: size.height)
        case .notes:
            NotesWidgetView(notesManager: notesManager, isDetail: false, onShowAll: { select(.notes) },
                onInteractionChanged: { reportModuleInteraction(.notes, active: $0) }, availableHeight: size.height)
        case .tray:
            TrayWidgetView(trayManager: trayManager, isDetail: false, onShowAll: { select(.tray) }, availableHeight: size.height)
        case .currentTask, .recentTasks:
            FocusSessionView(manager: focusSessionManager, historyDisplayLimit: historyDisplayLimit,
                trayFileCount: trayManager.files.count, onCreateLinkedNote: onCreateLinkedNote,
                onLinkTrayFiles: onLinkTrayFiles, onEndSession: onEndSession, showHistory: true,
                onOpenNote: onOpenNote, onOpenFile: onOpenFile,
                onInteractionChanged: { reportModuleInteraction(id, active: $0) },
                onLinksPresentationChanged: { reportModuleLinks(id, active: $0) },
                section: id == .currentTask ? .currentTask : .recentTasks, availableHeight: size.height,
                resources: focusResources, pendingTasks: pendingTasks)
        }
    }

}

/// 媒体卡片两端的矩形上报。两端都量到「面板内容区」坐标系里，换页时才能互相换算。
private struct MediaCardFrameReporter: ViewModifier {
    let isDetail: Bool
    var enabled = true

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.background {
                GeometryReader { geometry in
                    Color.clear.preference(key: MediaCardFrameKey.self,
                                           value: [isDetail: geometry.frame(in: .named(ExpandedPanelView.cardSpace))])
                }
            }
        } else {
            content
        }
    }
}

private struct MediaCardFrameKey: PreferenceKey {
    static var defaultValue: [Bool: CGRect] = [:]
    static func reduce(value: inout [Bool: CGRect], nextValue: () -> [Bool: CGRect]) {
        value.merge(nextValue()) { _, next in next }
    }
}

/// 换页时的卡片英雄转场：把卡片**从源矩形缩放到自身矩形**。
///
/// 为什么不用 `matchedGeometryEffect`：这里的网格是自定义 `Layout`（`PanelDashboardLayout`
/// 直接 `place` 到算好的 frame），几何效果不会插值；实测详情卡片在换页那一帧就是终态尺寸，
/// 只有原点是瞬移的。而且它需要换页过程带 `withAnimation`，那会把面板宽度也做成弹簧，
/// 新页面的测量会被 `ExpandedPanelMeasurement.matches` 的 0.5pt 门限挡掉（1.4.2 的闪烁根因）。
///
/// 这里改成完全显式：源矩形由 `select` 记录，目标矩形是本视图自己的布局 frame（`scaleEffect`
/// 不参与布局，所以量到的一定是终态），插值只落在渲染层。
private struct CardMorphIn: ViewModifier {
    let source: CGRect?

    @State private var target: CGRect?
    @State private var progress: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { measure(geometry) }
                        .onChange(of: geometry.size) { _, _ in measure(geometry) }
                }
            }
            .scaleEffect(x: scaleX, y: scaleY, anchor: .topLeading)
            .offset(x: offsetX, y: offsetY)
            // 目标矩形要等这一帧布局完才量得到；在这之前按终态尺寸画出来会闪一下，
            // 所以先藏着。通常 `onAppear` 就已经量好，最多藏一帧。
            .opacity(source != nil && target == nil ? 0 : 1)
    }

    private var scaleX: CGFloat { scale(for: target?.width) }
    private var scaleY: CGFloat { scale(for: target?.height) }

    private func scale(for length: CGFloat?) -> CGFloat {
        guard let source, let length, length > 1 else { return 1 }
        let start = (source.width > 0 ? source.width : length) / length
        return start + (1 - start) * progress
    }

    private var offsetX: CGFloat {
        guard let source, let target else { return 0 }
        return (source.minX - target.minX) * (1 - progress)
    }

    private var offsetY: CGFloat {
        guard let source, let target else { return 0 }
        return (source.minY - target.minY) * (1 - progress)
    }

    private func measure(_ geometry: GeometryProxy) {
        let frame = geometry.frame(in: .named(ExpandedPanelView.cardSpace))
        guard frame.width > 1, frame.height > 1 else { return }
        guard target == nil else {
            // `GeometryReader` 在被 `scaleEffect` 缩放的子树里，量到的是**渲染后**的矩形，
            // 所以只在动画结束（progress == 1，变换为恒等）时刷新，否则会拿缩放中的尺寸
            // 反过来改写缩放比例，形成反馈。
            if progress == 1,
               abs(frame.width - (target?.width ?? 0)) > 0.5 || abs(frame.height - (target?.height ?? 0)) > 0.5 {
                target = frame
            }
            return
        }
        target = frame
        guard source != nil, !systemReduceMotion else {
            progress = 1
            return
        }
        progress = 0
        // 下一拍再启动：让首帧先画在源矩形上。
        DispatchQueue.main.async {
            withAnimation(IslandMotion.panelSwitch.animation) { progress = 1 }
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

private struct PanelEditorToolbarHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

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
    var emphasizedColumn: Int? = nil
    private var spacing: CGFloat { ExpandedPanelLayout.columnSpacing }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = resolvedWidth(proposal.width, subviews: subviews)
        let heights = rowHeights(width: width, subviews: subviews)
        return CGSize(width: width, height: heights.reduce(0, +) + CGFloat(max(0, heights.count - 1)) * spacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let count = max(1, columns)
        let widths = ExpandedPanelLayout.columnWidths(contentWidth: bounds.width,
            columns: count, emphasizedColumn: emphasizedColumn)
        let heights = rowHeights(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for index in subviews.indices {
            let row = index / count
            let column = index % count
            if column == 0, row > 0 { y += heights[row - 1] + spacing }
            subviews[index].place(
                at: CGPoint(x: bounds.minX + widths.prefix(column).reduce(0, +) + CGFloat(column) * spacing, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: widths[column], height: heights[row])
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
        let widths = ExpandedPanelLayout.columnWidths(contentWidth: width,
            columns: count, emphasizedColumn: emphasizedColumn)
        var heights: [CGFloat] = []
        for index in subviews.indices {
            let height = subviews[index].sizeThatFits(ProposedViewSize(width: widths[index % count], height: nil)).height
            if index % count == 0 { heights.append(0) }
            heights[index / count] = max(heights[index / count], height.isFinite ? max(0, height) : 0)
        }
        return heights
    }
}

/// 媒体卡片在「概览网格」与「详情页」两端的矩形，以及本次换页的形变起点。
///
/// 为什么要有这个共享对象：换页的入口有两个（面板内部的 `select`、外壳
/// `NotchContentView` 直接改绑定）。两端矩形的测量结果住在面板里，而外壳改绑定的时候
/// 面板还没机会插入一句「记下源矩形」。把状态提到外面后，外壳可以先 `beginTransition`
/// 再改 `selectedWidget`——同一个 runloop 内 SwiftUI 合并成一次求值，新页面首帧就带着
/// 正确的 source。晚一拍再补的话首帧已经画成终态，整段动画都不会出现。
@MainActor
final class PanelCardMorphStore: ObservableObject {
    struct Morph: Equatable {
        let source: CGRect
        let toDetail: Bool
    }

    /// key 用 `isDetail` 区分：false 是概览网格里的卡片，true 是详情页里的卡片。
    @Published var frames: [Bool: CGRect] = [:]
    @Published var morph: Morph?

    /// 换页前调用。`toDetail` 为 nil 表示这次不是媒体卡片的进出（例如切到日历）。
    func beginTransition(toDetail: Bool?) {
        switch toDetail {
        case .some(true):
            morph = frames[false].map { Morph(source: $0, toDetail: true) }
        case .some(false):
            morph = frames[true].map { Morph(source: $0, toDetail: false) }
        case .none:
            morph = nil
        }
        // 弹簧收敛后清掉，避免之后的布局变化把卡片重新拉回源矩形。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in self?.morph = nil }
    }

    /// 该端卡片这次是否要做入场形变。
    func source(forDetail isDetail: Bool) -> CGRect? {
        guard let morph, morph.toDetail == isDetail else { return nil }
        return morph.source
    }
}
