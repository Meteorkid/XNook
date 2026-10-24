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

    private var item: PanelModulePlacement? { editor.draft.items.first { $0.id == selection } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack { title; Spacer(); actions }
                VStack(alignment: .leading, spacing: 8) { title; actions }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { modulePicker; sizePickers; visibility }
                VStack(alignment: .leading, spacing: 8) { modulePicker; sizePickers; visibility }
            }
            HStack(spacing: 12) {
                Button { editor.draft.reorder(selection, offset: -1) } label: {
                    Label(L10n.localized(zh: "前移", en: "Earlier"), systemImage: "arrow.up")
                }.accessibilityIdentifier("panelLayoutEarlier")
                .expandedPanelDebugFrame(id: "panelLayoutEarlier")
                Button { editor.draft.reorder(selection, offset: 1) } label: {
                    Label(L10n.localized(zh: "后移", en: "Later"), systemImage: "arrow.down")
                }.accessibilityIdentifier("panelLayoutLater")
                .expandedPanelDebugFrame(id: "panelLayoutLater")
            }
            .disabled(item?.isVisible != true)
            Text(L10n.localized(zh: "拖动标题移动，拖动右下角调整大小。", en: "Drag a title to move, or its corner to resize."))
                .font(.caption).foregroundStyle(.secondary)
            if let error = editor.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .controlSize(.small)
        .padding(12)
        .background(IslandStyle.cardRest(for: colorScheme).opacity(0.35))
        .accessibilityIdentifier("panelLayoutEditor")
                .expandedPanelDebugFrame(id: "panelLayoutEditor")
    }

    private var title: some View {
        Label(L10n.localized(zh: "编辑布局", en: "Edit Layout"), systemImage: "rectangle.3.group")
            .font(.headline)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button(L10n.localized(zh: "恢复默认", en: "Default")) { editor.restoreDefault() }
                .accessibilityIdentifier("panelLayoutDefault")
                .expandedPanelDebugFrame(id: "panelLayoutDefault")
            Button(L10n.localized(zh: "取消", en: "Cancel"), action: onCancel)
                .accessibilityIdentifier("panelLayoutCancel")
                .expandedPanelDebugFrame(id: "panelLayoutCancel")
            Button(L10n.save, action: onSave).buttonStyle(.borderedProminent)
                .accessibilityIdentifier("panelLayoutSave")
                .expandedPanelDebugFrame(id: "panelLayoutSave")
                .keyboardShortcut("s", modifiers: .command)
        }
    }

    private var modulePicker: some View {
        Picker(L10n.localized(zh: "组件", en: "Module"), selection: $selection) {
            ForEach(PanelModuleID.allCases) { Text($0.localizedName).tag($0) }
        }.accessibilityIdentifier("panelLayoutModule")
                .expandedPanelDebugFrame(id: "panelLayoutModule")
    }

    private var sizePickers: some View {
        HStack(spacing: 8) {
            Picker(L10n.localized(zh: "宽度", en: "Width"), selection: Binding(
                get: { item?.columns ?? 4 },
                set: { editor.draft.resize(selection, columns: $0, rows: item?.rows ?? selection.minimumRows) }
            )) {
                ForEach(PanelLayoutConfiguration.allowedColumns, id: \.self) { value in
                    Text([4: "⅓", 6: "½", 8: "⅔", 12: "1"] [value]!).tag(value)
                }
            }.accessibilityIdentifier("panelLayoutWidth")
                .expandedPanelDebugFrame(id: "panelLayoutWidth")
            Picker(L10n.localized(zh: "高度", en: "Height"), selection: Binding(
                get: { item?.rows ?? selection.minimumRows },
                set: { editor.draft.resize(selection, columns: item?.columns ?? 4, rows: $0) }
            )) {
                ForEach(PanelLayoutConfiguration.allowedRows.filter { $0 >= selection.minimumRows }, id: \.self) { value in
                    Text("\(value)").tag(value)
                }
            }.accessibilityIdentifier("panelLayoutHeight")
                .expandedPanelDebugFrame(id: "panelLayoutHeight")
        }
    }

    private var visibility: some View {
        Toggle(L10n.localized(zh: "显示", en: "Visible"), isOn: Binding(
            get: { item?.isVisible ?? false },
            set: { editor.draft.setVisible(selection, visible: $0) }
        )).accessibilityIdentifier("panelLayoutVisible")
                .expandedPanelDebugFrame(id: "panelLayoutVisible")
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
    @ViewBuilder let content: (PanelModulePlacement, CGSize) -> Content
    @Environment(\.colorScheme) private var colorScheme
    @State private var drag: GridDrag?

    private struct GridDrag {
        let id: PanelModuleID
        let resizing: Bool
        let original: PanelLayoutConfiguration
        let placement: PanelModulePlacement
    }

    var body: some View {
        let frames = PanelGridGeometry.frames(for: configuration, width: width, isEditing: isEditing)
        PanelDashboardLayout(frames: frames) {
            ForEach(configuration.items) { item in
                let size = frames[item.id]?.size ?? CGSize(width: 248, height: 184)
                ZStack(alignment: .topLeading) {
                    content(item, CGSize(width: max(1, size.width - 24), height: max(1, size.height - 24)))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(12)
                        .opacity(isEditing ? 0 : 1)
                        .allowsHitTesting(!isEditing && item.isVisible)
                        .disabled(isEditing || !item.isVisible)
                        .accessibilityHidden(isEditing || !item.isVisible)
                    if isEditing {
                        VStack(alignment: .leading, spacing: 12) {
                            Button { selection = item.id } label: {
                                Label(item.id.localizedName, systemImage: "line.3.horizontal")
                                    .font(.system(size: 13, weight: .semibold))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 4)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .gesture(gesture(for: item, resizing: false))
                            .accessibilityLabel(L10n.localized(zh: "移动", en: "Move") + " " + item.id.localizedName)
                            .accessibilityIdentifier("panelLayoutMove-\(item.id.rawValue)")
                .expandedPanelDebugFrame(id: "panelLayoutMove-\(item.id.rawValue)")
                            Text(summary(item.id)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            Text("\(item.columns)/12 · \(item.rows)")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }.padding(12)
                    }
                }
                .background(moduleFill ?? IslandStyle.cardRest(for: colorScheme))
                .clipShape(RoundedRectangle(cornerRadius: IslandTokens.Radius.sheet))
                .overlay {
                    if isEditing && selection == item.id {
                        RoundedRectangle(cornerRadius: IslandTokens.Radius.sheet)
                            .stroke(Color.accentColor, lineWidth: 2).allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if isEditing {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 28, height: 28).contentShape(Rectangle())
                            .gesture(gesture(for: item, resizing: true))
                            .accessibilityLabel(L10n.localized(zh: "调整大小", en: "Resize") + " " + item.id.localizedName)
                            .accessibilityIdentifier("panelLayoutResize-\(item.id.rawValue)")
                .expandedPanelDebugFrame(id: "panelLayoutResize-\(item.id.rawValue)")
                    }
                }
                .opacity(item.isVisible ? 1 : 0)
                .allowsHitTesting(item.isVisible)
                .accessibilityHidden(!item.isVisible)
                .layoutValue(key: PanelDashboardModuleKey.self, value: item.id)
                .expandedPanelDebugFrame(id: "panelModule-\(item.id.rawValue)")
            }
        }
        .coordinateSpace(name: "panelGridEditor")
        .frame(width: max(1, width), height: max(44, PanelGridGeometry.height(for: configuration, width: width, isEditing: isEditing)), alignment: .topLeading)
        .overlay {
            if configuration.visibleItems.isEmpty {
                Text(L10n.localized(zh: "组件已隐藏，可在编辑布局中重新显示。", en: "All modules are hidden. Edit the layout to show them again."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: isEditing) { _, _ in drag = nil }
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
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 800, height: frames.values.map(\.maxY).max() ?? 44)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for view in subviews {
            guard let id = view[PanelDashboardModuleKey.self], let frame = frames[id] else {
                view.place(at: bounds.origin, anchor: .topLeading, proposal: .zero)
                continue
            }
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                       anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }
}
