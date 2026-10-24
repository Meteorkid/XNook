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
    static let headerHeight: CGFloat = 77
    static let minimumWidgetContentWidth: CGFloat = 224
    static let outerPadding: CGFloat = 12
    static let cardPadding: CGFloat = 12
    static let columnSpacing: CGFloat = 12

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
