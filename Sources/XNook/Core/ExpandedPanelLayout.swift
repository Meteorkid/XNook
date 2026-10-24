import Foundation

struct ExpandedPanelMeasurement: Equatable {
    let width: CGFloat
    let height: CGFloat
    let selectedWidget: NotchContentView.WidgetType?
    /// 组合变化即使高度相同，也需要重新上报并拒绝旧组合的测量。
    let enabledWidgets: [NotchContentView.WidgetType]
    var layoutSignature: String = ""
    var isEditingLayout: Bool = false

    func matches(width: CGFloat, selectedWidget: NotchContentView.WidgetType?, enabledWidgets: [NotchContentView.WidgetType], layoutSignature: String = "", isEditingLayout: Bool = false) -> Bool {
        self.width.isFinite && self.width > 0 && abs(self.width - width) < 0.5
            && height.isFinite && height > 0 && self.selectedWidget == selectedWidget
            && self.enabledWidgets == enabledWidgets && self.layoutSignature == layoutSignature && self.isEditingLayout == isEditingLayout
    }

    func differs(from previous: Self?) -> Bool {
        guard let previous else { return true }
        return selectedWidget != previous.selectedWidget
            || enabledWidgets != previous.enabledWidgets || layoutSignature != previous.layoutSignature || isEditingLayout != previous.isEditingLayout
            || abs(width - previous.width) >= 0.5 || abs(height - previous.height) > 0.5
    }
}

enum ExpandedPanelLayout {
    static let headerHeight: CGFloat = 41
    static let minimumWidgetContentWidth: CGFloat = 200
    static let outerPadding: CGFloat = 8
    static let cardPadding: CGFloat = 12
    static let columnSpacing: CGFloat = 8

    /// 自动模式将设置宽度视为上限，少量组件与媒体详情不再撑满整条面板。
    static func width(preferred: CGFloat, available: CGFloat, automaticallyFit: Bool,
                      widgetCount: Int, selectedWidget: NotchContentView.WidgetType?) -> CGFloat {
        let preferred = preferred.isFinite && preferred > 0 ? max(160, preferred) : 800
        let available = available.isFinite && available > 0 ? available : 800
        var target = preferred
        if automaticallyFit {
            if selectedWidget == .media {
                target = min(target, 460)
            } else if selectedWidget == nil {
                if widgetCount <= 1 { target = min(target, 400) }
                else if widgetCount == 2 { target = min(target, 640) }
            }
        }
        return min(target, available)
    }

    /// 单行概览优先把余量给封面；其余模块仍保有完整的最小内容宽度。
    static func columnWidths(contentWidth: CGFloat, columns: Int, emphasizedColumn: Int?) -> [CGFloat] {
        guard columns > 0 else { return [] }
        let usable = max(0, contentWidth - CGFloat(columns - 1) * columnSpacing)
        let minimum = minimumWidgetContentWidth + cardPadding * 2
        let emphasis = emphasizedColumn.map { (0..<columns).contains($0) } == true && columns > 1
        let extra = emphasis ? min(88, max(0, usable - minimum * CGFloat(columns))) : 0
        let base = (usable - extra) / CGFloat(columns)
        return (0..<columns).map { base + ($0 == emphasizedColumn ? extra : 0) }
    }

    /// 两侧放不下导航与操作时，整条工具栏移到物理刘海下方。
    static func headerTopInset(width: CGFloat, deadZoneWidth: CGFloat, deadZoneHeight: CGFloat, toolbarWidth: CGFloat = 60) -> CGFloat {
        guard deadZoneWidth.isFinite, deadZoneWidth > 0,
              deadZoneHeight.isFinite, deadZoneHeight > 0 else { return 0 }
        // 60pt 操作组与外边距需要完整落在刘海的一侧。
        return (width - deadZoneWidth) / 2 >= toolbarWidth + 12 ? 0 : deadZoneHeight
    }

    static func columnCount(width: CGFloat, widgetCount: Int) -> Int {
        guard widgetCount > 0 else { return 0 }
        guard width.isFinite else { return 1 }
        let cellWidth = minimumWidgetContentWidth + cardPadding * 2
        let capacity = max(1, floor((max(0, width - outerPadding * 2) + columnSpacing) / (cellWidth + columnSpacing)))
        guard capacity < CGFloat(widgetCount) else { return widgetCount }
        let maximumColumns = Int(capacity)
        let rows = 1 + (widgetCount - 1) / maximumColumns
        // 保持最少行数并均衡分列：默认宽度下三个组件一行，四个组件为两行两列。
        return 1 + (widgetCount - 1) / rows
    }

    static func maximumHeight(availableHeight: CGFloat, automaticallyFit: Bool, manualMaxHeight: CGFloat) -> CGFloat {
        let available = availableHeight.isFinite && availableHeight > 0 ? availableHeight : 900
        guard !automaticallyFit else { return available }
        let manual = manualMaxHeight.isFinite && manualMaxHeight > 0 ? manualMaxHeight : 200
        return min(available, max(headerHeight + 1, manual))
    }

    static func height(measuredContentHeight: CGFloat?, maximumHeight: CGFloat) -> CGFloat {
        let maximum = maximumHeight.isFinite && maximumHeight > 0 ? maximumHeight : 400
        guard let measuredContentHeight, measuredContentHeight.isFinite, measuredContentHeight > 0 else {
            return min(400, maximum)
        }
        return min(maximum, max(headerHeight + 44, ceil(measuredContentHeight)))
    }
}
