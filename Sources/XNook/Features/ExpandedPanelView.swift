import SwiftUI
import EventKit

/// 纯内容面板，窗口与悬停逻辑由 NotchContentView 管理。
struct ExpandedPanelView: View {
    typealias Widget = NotchContentView.WidgetType

    @Environment(\.colorScheme) private var colorScheme
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
    let onMeasuredHeight: (CGFloat) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            navigation
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if selectedWidget == nil {
                        focusContent
                        if enabledWidgets.isEmpty {
                            Text(L10n.panelNoWidgets)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 20)
                        } else {
                            overview
                        }
                    } else if let selectedWidget {
                        widgetView(for: selectedWidget, isDetail: true)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .frame(minHeight: 260)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: PanelContentHeightKey.self, value: geometry.size.height)
                    }
                }
            }
            .onPreferenceChange(PanelContentHeightKey.self) { height in
                onMeasuredHeight(height + ExpandedPanelLayout.headerHeight)
            }
        }
        .onExitCommand {
            if selectedWidget != nil { selectedWidget = nil }
            else { onClose() }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("Nook", systemImage: "square.grid.2x2")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button(action: onSettings) { Image(systemName: "gearshape").frame(width: 26, height: 26) }
                .help(L10n.preferences)
                .accessibilityLabel(L10n.preferences)
            Button(action: onClose) { Image(systemName: "xmark").frame(width: 26, height: 26) }
                .help(L10n.panelClose)
                .accessibilityLabel(L10n.panelClose)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .frame(height: 40)
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
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12)
            .frame(height: 36)
        } else {
            HStack(spacing: 6) {
                navigationButton(title: L10n.panelOverview, icon: "square.grid.2x2", widget: nil)
                ForEach(navigationWidgets, id: \.self) { widget in
                    navigationButton(title: widget.localizedName, icon: widget.icon, widget: widget)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
        }
    }

    /// 隐藏的工具仍可从任务记录打开；进入详情后临时保留其导航入口。
    private var navigationWidgets: [Widget] {
        guard let selectedWidget, !enabledWidgets.contains(selectedWidget) else { return enabledWidgets }
        return enabledWidgets + [selectedWidget]
    }

    private func navigationButton(title: String, icon: String, widget: Widget?) -> some View {
        Button { selectedWidget = widget } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(selectedWidget == widget ? IslandStyle.insetFill(for: colorScheme) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .fixedSize()
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selectedWidget == widget ? [.isSelected] : [])
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
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var overview: some View {
        let count = ExpandedPanelLayout.columnCount(width: panelWidth, widgetCount: enabledWidgets.count)
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 12), count: count), spacing: 12) {
            ForEach(enabledWidgets, id: \.self) { widget in
                widgetView(for: widget, isDetail: false)
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .frame(height: ExpandedPanelLayout.compactWidgetHeight, alignment: .top)
                    .background(IslandStyle.cardRest(for: colorScheme))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
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

private struct PanelContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
