import Foundation

/// 高度是去掉卡片内边距后的正文预算；未提供时保持旧调用的行数。
enum GridWidgetContentLayout {
    static func rowLimit(height: CGFloat?, reserved: CGFloat, rowHeight: CGFloat, maximum: Int) -> Int {
        guard let height, height.isFinite else { return maximum }
        return Int(min(CGFloat(maximum), max(1, (height - reserved) / rowHeight)))
    }

    static func calendarDayCount(width: CGFloat) -> Int {
        if width >= 328 { return 7 }
        if width >= 248 { return 5 }
        return 3
    }

    static func calendarDates(selected: Date, width: CGFloat, calendar: Calendar = .current) -> [Date] {
        let radius = calendarDayCount(width: width) / 2
        let day = calendar.startOfDay(for: selected)
        return (-radius...radius).compactMap { calendar.date(byAdding: .day, value: $0, to: day) }
    }
}

/// NSClipView 在尺寸变化时也发布 bounds 通知，只有尺寸不变的位移才是滚动。
struct GridWidgetCalendarScrollState {
    enum Change: Equatable { case layout, scroll, unchanged }
    private var previousBounds: CGRect?

    mutating func update(_ bounds: CGRect) -> Change {
        defer { previousBounds = bounds }
        guard let previousBounds, previousBounds.size == bounds.size else { return .layout }
        return previousBounds.origin == bounds.origin ? .unchanged : .scroll
    }
}
