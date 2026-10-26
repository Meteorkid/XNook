import SwiftUI

extension Notification.Name {
    static let xnookEditPanelLayout = Notification.Name("xnookEditPanelLayout")
}

struct PanelLayoutEditorToolbar: View {
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var editor: PanelLayoutEditingSession
    @Binding var selection: PanelModuleID
    let onSave: () -> Void
    let onCancel: () -> Void
    var availableWidth: CGFloat = 800

    private var item: PanelModulePlacement? { editor.draft.items.first { $0.id == selection } }
    private var selectedIndex: Int? { editor.draft.visibleItems.firstIndex { $0.id == selection } }
    private var hiddenItems: [PanelModulePlacement] { editor.draft.items.filter { !$0.isVisible } }
    private var isNarrow: Bool { availableWidth < 768 }
    private var isCompact: Bool { availableWidth < 560 }
    private var isVeryNarrow: Bool { availableWidth < 260 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { title; Spacer(minLength: 8); actions }.fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 6) { title; actions }
            }
            Text(isVeryNarrow ? L10n.layoutEditorVeryNarrowGuide : isNarrow ? L10n.layoutEditorNarrowGuide : L10n.layoutEditorGuide)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("panelLayoutHelp")
                .expandedPanelDebugFrame(id: "panelLayoutHelp")
            if isCompact {
                if isVeryNarrow {
                    VStack(alignment: .leading, spacing: 8) {
                        modulePicker
                        visibility
                        reorderActions
                    }
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .bottom, spacing: 8) { modulePicker; visibility; reorderActions }
                            .fixedSize(horizontal: true, vertical: false)
                        VStack(alignment: .leading, spacing: 8) {
                            modulePicker
                            HStack(spacing: 8) { visibility; Spacer(minLength: 0); reorderActions }
                        }
                    }
                }
                if isVeryNarrow {
                    VStack(alignment: .leading, spacing: 6) { widthPicker; heightPicker }
                } else {
                    HStack(alignment: .top, spacing: 8) { widthPicker; heightPicker }
                }
            } else {
                HStack(alignment: .bottom, spacing: 10) {
                    modulePicker; widthPicker; heightPicker; visibility; reorderActions
                }
            }
            if !hiddenItems.isEmpty { hiddenModules }
            if let error = editor.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .controlSize(.small)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(IslandStyle.cardRest(for: colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: IslandTokens.Radius.sheet))
        .accessibilityIdentifier("panelLayoutEditor")
        .expandedPanelDebugFrame(id: "panelLayoutEditor")
    }

    @ViewBuilder
    private var title: some View {
        if isVeryNarrow {
            VStack(alignment: .leading, spacing: 2) { editorLabel; changeStatus }
        } else {
            HStack(spacing: 8) { editorLabel; changeStatus }
        }
    }

    private var editorLabel: some View {
        Label(isVeryNarrow ? L10n.localized(zh: "布局", en: "Layout") : L10n.layoutEditorTitle,
              systemImage: "rectangle.3.group")
            .font(.system(size: 13, weight: .semibold))
    }

    private var changeStatus: some View {
        // 状态切换不改变工具栏占位，避免首次拖动时画布突然下移。
        ZStack(alignment: .leading) {
            Text(changedTitle).hidden().accessibilityHidden(true)
            Text(unchangedTitle).hidden().accessibilityHidden(true)
            Text(editor.hasChanges ? changedTitle : unchangedTitle)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(editor.hasChanges ? Color.primary : Color.secondary)
        .accessibilityIdentifier("panelLayoutChangeStatus")
    }

    private var changedTitle: String {
        isVeryNarrow ? L10n.localized(zh: "未保存", en: "Unsaved") : L10n.layoutEditorChanged
    }

    private var unchangedTitle: String {
        isVeryNarrow ? L10n.localized(zh: "未修改", en: "No edits") : L10n.layoutEditorUnchanged
    }

    @ViewBuilder
    private var actions: some View {
        if isVeryNarrow {
            VStack(alignment: .leading, spacing: 6) {
                defaultAction
                HStack(spacing: 8) { cancelAction; saveAction }
            }
        } else {
            HStack(spacing: 8) { defaultAction; cancelAction; saveAction }
        }
    }

    private var defaultAction: some View {
        Button(L10n.localized(zh: "恢复默认", en: "Default")) { editor.restoreDefault() }
            .help(L10n.localized(zh: "先恢复草稿，保存后生效", en: "Reset the draft; save to apply"))
            .accessibilityIdentifier("panelLayoutDefault")
            .expandedPanelDebugFrame(id: "panelLayoutDefault")
    }

    private var cancelAction: some View {
        Button(L10n.localized(zh: "取消", en: "Cancel"), action: onCancel)
            .help(L10n.localized(zh: "放弃本次布局修改", en: "Discard these layout changes"))
            .accessibilityIdentifier("panelLayoutCancel")
            .expandedPanelDebugFrame(id: "panelLayoutCancel")
    }

    private var saveAction: some View {
        Button(action: onSave) {
            ZStack {
                Text(isVeryNarrow ? L10n.save : L10n.layoutEditorSave).hidden().accessibilityHidden(true)
                Text(L10n.layoutEditorDone).hidden().accessibilityHidden(true)
                Text(editor.hasChanges ? (isVeryNarrow ? L10n.save : L10n.layoutEditorSave) : L10n.layoutEditorDone)
            }
        }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel(editor.hasChanges ? L10n.layoutEditorSave : L10n.layoutEditorDone)
            .accessibilityIdentifier("panelLayoutSave")
            .expandedPanelDebugFrame(id: "panelLayoutSave")
            .keyboardShortcut("s", modifiers: .command)
    }

    private var modulePicker: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L10n.layoutEditorSelected).font(.caption2).foregroundStyle(.secondary)
            Group {
                if isVeryNarrow {
                    compactMenu(selection.localizedName, help: L10n.layoutEditorSelected) { moduleOptions }
                } else {
                    moduleOptions
                }
            }
            .accessibilityLabel(L10n.layoutEditorSelected)
            .accessibilityIdentifier("panelLayoutModule")
            .expandedPanelDebugFrame(id: "panelLayoutModule")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var moduleOptions: some View {
        Picker(L10n.layoutEditorSelected, selection: $selection) {
            ForEach(PanelModuleID.allCases) { module in
                let hidden = editor.draft.items.first { $0.id == module }?.isVisible != true
                Text(module.localizedName + (hidden ? " · " + L10n.layoutEditorHidden : "")).tag(module)
            }
        }.labelsHidden()
    }

    private var widthPicker: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L10n.layoutEditorWidth).font(.caption2).foregroundStyle(.secondary)
            Group {
                if isVeryNarrow {
                    compactMenu(L10n.layoutWidth(item?.columns ?? 4), help: L10n.layoutEditorWidth) { widthOptions }
                } else {
                    widthOptions
                }
            }
            .accessibilityLabel(L10n.layoutEditorWidth)
            .accessibilityIdentifier("panelLayoutWidth")
            .expandedPanelDebugFrame(id: "panelLayoutWidth")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var widthOptions: some View {
        Picker(L10n.layoutEditorWidth, selection: Binding(
            get: { item?.columns ?? 4 },
            set: { editor.draft.resize(selection, columns: $0, rows: item?.rows ?? selection.minimumRows) }
        )) {
            ForEach(PanelLayoutConfiguration.allowedColumns, id: \.self) { value in
                Text(L10n.layoutWidth(value)).tag(value)
            }
        }.labelsHidden()
    }

    private var heightPicker: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L10n.layoutEditorHeight).font(.caption2).foregroundStyle(.secondary)
            Group {
                if isVeryNarrow {
                    compactMenu(L10n.layoutHeightName(item?.rows ?? selection.minimumRows),
                                help: L10n.layoutHeight(item?.rows ?? selection.minimumRows)) { heightOptions }
                } else {
                    heightOptions
                }
            }
            .accessibilityLabel(L10n.layoutEditorHeight)
            .accessibilityIdentifier("panelLayoutHeight")
            .expandedPanelDebugFrame(id: "panelLayoutHeight")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var heightOptions: some View {
        Picker(L10n.layoutEditorHeight, selection: Binding(
            get: { item?.rows ?? selection.minimumRows },
            set: { editor.draft.resize(selection, columns: item?.columns ?? 4, rows: $0) }
        )) {
            ForEach(PanelLayoutConfiguration.allowedRows.filter { $0 >= selection.minimumRows }, id: \.self) { value in
                Text(L10n.layoutHeight(value)).tag(value)
            }
        }.labelsHidden()
    }

    /// 极窄面板使用可收缩的菜单标签，避免原生 Picker 按最长菜单项撑大整个工具栏。
    private func compactMenu<Options: View>(_ value: String, help: String,
                                           @ViewBuilder options: () -> Options) -> some View {
        Menu { options() } label: {
            HStack(spacing: 4) {
                Text(value).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 12))
            .padding(.horizontal, 6)
            .frame(width: max(1, availableWidth - 48), height: 22, alignment: .leading)
            .background(IslandStyle.insetFill(for: colorScheme), in: RoundedRectangle(cornerRadius: 5))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help(help)
        .accessibilityValue(value)
    }

    private var visibility: some View {
        Toggle(L10n.localized(zh: "显示", en: "Visible"), isOn: Binding(
            get: { item?.isVisible ?? false },
            set: { editor.draft.setVisible(selection, visible: $0) }
        ))
        .fixedSize()
        .accessibilityIdentifier("panelLayoutVisible")
        .expandedPanelDebugFrame(id: "panelLayoutVisible")
    }

    private var reorderActions: some View {
        HStack(spacing: 4) {
            Button { editor.draft.reorder(selection, offset: -1) } label: {
                Image(systemName: "arrow.up").frame(width: 16, height: 16)
            }
            .disabled(selectedIndex == nil || selectedIndex == 0)
            .help(L10n.layoutEditorEarlierHelp)
            .accessibilityLabel(L10n.localized(zh: "前移", en: "Earlier"))
            .accessibilityIdentifier("panelLayoutEarlier")
            .expandedPanelDebugFrame(id: "panelLayoutEarlier")
            Button { editor.draft.reorder(selection, offset: 1) } label: {
                Image(systemName: "arrow.down").frame(width: 16, height: 16)
            }
            .disabled(selectedIndex == nil || selectedIndex == editor.draft.visibleItems.count - 1)
            .help(L10n.layoutEditorLaterHelp)
            .accessibilityLabel(L10n.localized(zh: "后移", en: "Later"))
            .accessibilityIdentifier("panelLayoutLater")
            .expandedPanelDebugFrame(id: "panelLayoutLater")
        }
        .fixedSize()
    }

    private var hiddenModules: some View {
        HStack(spacing: 6) {
            Text(L10n.layoutEditorHidden).font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(hiddenItems) { hidden in
                        Button {
                            editor.draft.setVisible(hidden.id, visible: true)
                            selection = hidden.id
                        } label: {
                            Label(hidden.id.localizedName, systemImage: "plus")
                        }
                        .accessibilityLabel(L10n.localized(zh: "显示", en: "Show") + " " + hidden.id.localizedName)
                        .accessibilityIdentifier("panelLayoutShow-\(hidden.id.rawValue)")
                        .expandedPanelDebugFrame(id: "panelLayoutShow-\(hidden.id.rawValue)")
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(height: 26)
            .accessibilityIdentifier("panelLayoutHiddenModules")
            .expandedPanelDebugFrame(id: "panelLayoutHiddenModules")
        }
    }
}

/// 组件始终由固定 ID 挂载；编辑遮罩不移除真实内容，避免拖动丢失输入状态。
struct PanelDashboardGrid<Content: View>: View {
    @Binding var configuration: PanelLayoutConfiguration
    @Binding var selection: PanelModuleID
    let width: CGFloat
    let isEditing: Bool
    let summary: (PanelModuleID) -> String
    var moduleFill: Color? = nil
    var fitsContent = false
    @ViewBuilder let content: (PanelModulePlacement, CGSize) -> Content
    @Environment(\.colorScheme) private var colorScheme
    @State private var drag: GridDrag?
    @State private var hoveredResize: PanelModuleID?

    private struct GridDrag {
        let id: PanelModuleID
        let resizing: Bool
        let original: PanelLayoutConfiguration
        let placement: PanelModulePlacement
    }

    var body: some View {
        let frames = PanelGridGeometry.frames(for: configuration, width: width, isEditing: isEditing)
        let contentFit = fitsContent && !isEditing
        PanelDashboardLayout(frames: frames, configuration: configuration, width: width, fitsContent: contentFit) {
            ForEach(configuration.items) { item in
                let size = frames[item.id]?.size ?? CGSize(width: 248, height: 184)
                ZStack(alignment: .topLeading) {
                    content(item, CGSize(width: max(1, size.width - 24), height: max(1, size.height - 24)))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(12)
                        .opacity(isEditing ? (usesSummaryPreview(item.id) ? 0 : 0.60) : 1)
                        .allowsHitTesting(!isEditing && item.isVisible)
                        .disabled(isEditing || !item.isVisible)
                        .accessibilityHidden(isEditing || !item.isVisible)
                    if isEditing { editingCard(item) }
                }
                .background(moduleFill ?? IslandStyle.cardRest(for: colorScheme))
                .clipShape(RoundedRectangle(cornerRadius: IslandTokens.Radius.sheet))
                .overlay {
                    if isEditing && selection == item.id {
                        RoundedRectangle(cornerRadius: IslandTokens.Radius.sheet)
                            .strokeBorder(Color.accentColor, lineWidth: 2).allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if isEditing { resizeHandle(item).padding(8) }
                }
                .opacity(item.isVisible ? 1 : 0)
                .allowsHitTesting(item.isVisible)
                .accessibilityHidden(!item.isVisible)
                .layoutValue(key: PanelDashboardModuleKey.self, value: item.id)
                .expandedPanelDebugFrame(id: "panelModule-\(item.id.rawValue)")
            }
        }
        .coordinateSpace(name: "panelGridEditor")
        .frame(width: max(1, width),
               height: contentFit ? nil : max(44, PanelGridGeometry.height(for: configuration, width: width, isEditing: isEditing)),
               alignment: .topLeading)
        .overlay {
            if configuration.visibleItems.isEmpty {
                Text(L10n.localized(zh: "组件已隐藏，可在编辑布局中重新显示。", en: "All modules are hidden. Edit the layout to show them again."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: isEditing) { _, _ in drag = nil; hoveredResize = nil }
    }

    private func editingCard(_ item: PanelModulePlacement) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { selection = item.id } label: {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 11, weight: .semibold))
                    Text(item.id.localizedName)
                        .font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 0)
                    if selection == item.id {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 11))
                    }
                }
                .foregroundStyle(selection == item.id ? Color.accentColor : Color.primary)
                .padding(.horizontal, 8)
                .frame(minHeight: 28)
                .background {
                    RoundedRectangle(cornerRadius: 6).fill(editingChromeFill)
                        .overlay {
                            if selection == item.id {
                                RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.12))
                            }
                        }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // 拖动只从标题开始；卡片其余区域负责单击选择，不与角部缩放争抢。
            .highPriorityGesture(gesture(for: item, resizing: false))
            .help(L10n.layoutEditorMoveHelp)
            .accessibilityLabel(L10n.localized(zh: "移动", en: "Move") + " " + item.id.localizedName)
            .accessibilityIdentifier("panelLayoutMove-\(item.id.rawValue)")
            .expandedPanelDebugFrame(id: "panelLayoutMove-\(item.id.rawValue)")
            if usesSummaryPreview(item.id) {
                // 任务模块没有通用标题行，摘要避免被拖动条遮住半行文字。
                Text(summary(item.id)).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).padding(.top, 8)
            }
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Text(interactionStatus(for: item))
                    .font(.caption2.weight(.medium))
                    .layoutPriority(1)
                    .accessibilityIdentifier("panelLayoutSelection-\(item.id.rawValue)")
                Text("·").foregroundStyle(.secondary)
                Text(L10n.layoutWidth(item.columns) + " · " + L10n.layoutHeight(item.rows))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("panelLayoutSize-\(item.id.rawValue)")
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(editingChromeFill, in: Capsule())
            .help(interactionStatus(for: item) + " · " + L10n.layoutWidth(item.columns) + " · " + L10n.layoutHeight(item.rows))
            .padding(.trailing, 34)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture { selection = item.id }
        .help(L10n.layoutEditorSelectHelp)
    }

    private var editingChromeFill: Color {
        Color(white: colorScheme == .dark ? 0.10 : 0.94)
    }

    private func usesSummaryPreview(_ id: PanelModuleID) -> Bool {
        id == .currentTask || id == .recentTasks
    }

    private func interactionStatus(for item: PanelModulePlacement) -> String {
        guard let drag, drag.id == item.id else {
            return selection == item.id ? L10n.layoutEditorCardSelected : L10n.layoutEditorCardUnselected
        }
        if !drag.resizing { return L10n.layoutEditorMoving }
        return width < 752 ? L10n.layoutEditorResizingHeight : L10n.layoutEditorResizing
    }

    private func resizeHandle(_ item: PanelModulePlacement) -> some View {
        let highlighted = selection == item.id || hoveredResize == item.id
        return Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(highlighted ? Color.accentColor : Color.primary)
            .frame(width: 28, height: 28)
            .background {
                RoundedRectangle(cornerRadius: 6).fill(editingChromeFill)
                    .overlay {
                        if highlighted { RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.18)) }
                    }
            }
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5) }
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { hoveredResize = item.id }
                else if hoveredResize == item.id { hoveredResize = nil }
            }
            .gesture(gesture(for: item, resizing: true))
            .help(width < 752 ? L10n.layoutEditorResizeHeightHelp : L10n.layoutEditorResizeHelp)
            .accessibilityLabel(L10n.localized(zh: "调整大小", en: "Resize") + " " + item.id.localizedName)
            .accessibilityIdentifier("panelLayoutResize-\(item.id.rawValue)")
            .expandedPanelDebugFrame(id: "panelLayoutResize-\(item.id.rawValue)")
    }

    private func gesture(for item: PanelModulePlacement, resizing: Bool) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("panelGridEditor"))
            .onChanged { value in
                guard isEditing else { return }
                selection = item.id
                if drag == nil { drag = GridDrag(id: item.id, resizing: resizing, original: configuration, placement: item) }
                guard let drag, drag.id == item.id else { return }
                let next = PanelLayoutDragUpdate.configuration(from: drag.original, id: item.id,
                    translation: value.translation, resizing: resizing, width: width)

                configuration = next
            }
            .onEnded { _ in drag = nil }
    }
}

private struct PanelDashboardModuleKey: LayoutValueKey {
    static let defaultValue: PanelModuleID? = nil
}

private struct PanelDashboardLayout: Layout {
    let frames: [PanelModuleID: CGRect]
    let configuration: PanelLayoutConfiguration
    let width: CGFloat
    let fitsContent: Bool

    private func displayedFrames(subviews: Subviews) -> [PanelModuleID: CGRect] {
        guard fitsContent else { return frames }
        var measuredHeights: [PanelModuleID: CGFloat] = [:]
        for view in subviews {
            guard let id = view[PanelDashboardModuleKey.self], let frame = frames[id] else { continue }
            // 同一视图树按既定内容预算测自然高度，不把测得高度反馈成新的条数预算。
            measuredHeights[id] = view.sizeThatFits(ProposedViewSize(width: frame.width, height: nil)).height
        }
        return PanelGridGeometry.contentFittedFrames(for: configuration, width: width, measuredHeights: measuredHeights)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let displayed = displayedFrames(subviews: subviews)
        return CGSize(width: proposal.width ?? width, height: max(44, displayed.values.map(\.maxY).max() ?? 44))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let displayed = displayedFrames(subviews: subviews)
        for view in subviews {
            guard let id = view[PanelDashboardModuleKey.self], let frame = displayed[id] else {
                view.place(at: bounds.origin, anchor: .topLeading, proposal: .zero)
                continue
            }
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                       anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }
}
