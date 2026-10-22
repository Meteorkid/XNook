import Foundation

enum ExpandedPanelLayout {
    static let headerHeight: CGFloat = 77
    static let compactWidgetHeight: CGFloat = 244

    static func columnCount(width: CGFloat, widgetCount: Int) -> Int {
        guard width.isFinite else { return 1 }
        let columns = max(1, Int((max(0, width - 24) + 12) / 272))
        return min(max(1, widgetCount), columns)
    }

    static func height(measuredContentHeight: CGFloat?, maximumHeight: CGFloat) -> CGFloat {
        let maximum = maximumHeight.isFinite ? max(120, maximumHeight) : 400
        guard let measuredContentHeight, measuredContentHeight.isFinite, measuredContentHeight > 0 else {
            return min(400, maximum)
        }
        return min(maximum, max(headerHeight + 44, ceil(measuredContentHeight)))
    }
}
