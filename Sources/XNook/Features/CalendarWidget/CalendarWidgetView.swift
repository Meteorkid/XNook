import SwiftUI
import EventKit

/// 日历 Widget 视图
struct CalendarWidgetView: View {
    var calendarManager: CalendarManager
    @Binding var recenterTrigger: Int
    @State private var selectedDate = Date()
    @State private var centeredDate = Date()

    var body: some View {
        VStack(spacing: 8) {
            Spacer()

            // 月份标题
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(monthString(for: centeredDate))
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
                    .contentTransition(.numericText())
                Text(L10n.monthSuffix)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .animation(.easeInOut(duration: 0.15), value: centeredDate)

            // 可滚动日期行
            CalendarScroller(
                selectedDate: $selectedDate,
                centeredDate: $centeredDate,
                recenterTrigger: $recenterTrigger,
                today: today,
                dateRange: dateRange
            )
            .frame(height: 48)

            // 事件状态
            if !calendarManager.hasAccess {
                HStack(spacing: 4) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 8))
                    Text(L10n.calendarAccessRequired)
                        .font(.system(size: 9))
                }
                .foregroundColor(.secondary)
            } else if calendarManager.upcomingEvents.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "calendar.badge.checkmark")
                        .font(.system(size: 8))
                    Text(L10n.noUpcomingEvents)
                        .font(.system(size: 9))
                }
                .foregroundColor(.secondary)
            } else {
                VStack(spacing: 3) {
                    ForEach(calendarManager.upcomingEvents.prefix(2), id: \.eventIdentifier) { event in
                        HStack(spacing: 4) {
                            Circle()
                                .fill(.blue)
                                .frame(width: 4, height: 4)
                            Text(event.title ?? L10n.untitled)
                                .font(.system(size: 9, weight: .medium))
                                .lineLimit(1)
                            Spacer()
                            Text(timeString(from: event.startDate))
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            Spacer()
        }
        .onChange(of: selectedDate) { _, date in
            guard calendarManager.hasAccess else { return }
            calendarManager.loadEvents(for: date)
        }
        .onChange(of: calendarManager.hasAccess) { _, hasAccess in
            guard hasAccess else { return }
            calendarManager.loadEvents(for: selectedDate)
        }
    }

    private var today: Date {
        Calendar.current.startOfDay(for: Date())
    }

    private var dateRange: [Date] {
        let calendar = Calendar.current
        return (-14...14).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: today)
        }
    }

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M"
        f.locale = L10n.isChinese ? Locale(identifier: "zh_CN") : Locale.current
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.locale = L10n.isChinese ? Locale(identifier: "zh_CN") : Locale.current
        return f
    }()

    private func monthString(for date: Date) -> String {
        Self.monthFormatter.string(from: date)
    }

    private func timeString(from date: Date) -> String {
        Self.timeFormatter.string(from: date)
    }
}

// MARK: - AppKit 滚动日期条

private struct CalendarScroller: NSViewRepresentable {
    @Binding var selectedDate: Date
    @Binding var centeredDate: Date
    @Binding var recenterTrigger: Int
    let today: Date
    let dateRange: [Date]

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        let stackView = DateStackView()
        stackView.orientation = .horizontal
        stackView.spacing = 6
        stackView.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        stackView.translatesAutoresizingMaskIntoConstraints = false

        let calendar = Calendar.current
        for (index, date) in dateRange.enumerated() {
            let isToday = calendar.isDate(date, inSameDayAs: today)
            let cell = DateCell(date: date, isToday: isToday, index: index)
            cell.target = context.coordinator
            cell.action = #selector(Coordinator.cellClicked(_:))
            stackView.addArrangedSubview(cell)
        }

        scrollView.documentView = stackView

        // 约束内容高度
        stackView.translatesAutoresizingMaskIntoConstraints = false
        // 设置初始滚动位置到今天
        DispatchQueue.main.async {
            context.coordinator.scrollToToday(scrollView, animated: false)
        }

        // 监听滚动
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.boundsChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        return scrollView
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        // recenterTrigger 变化时重新居中到今天（面板重新展开）
        if recenterTrigger != context.coordinator.lastTrigger {
            context.coordinator.lastTrigger = recenterTrigger
            DispatchQueue.main.async {
                context.coordinator.scrollToToday(nsView, animated: false)
            }
        }
    }

    // MARK: - Coordinator

    class Coordinator: NSObject {
        var parent: CalendarScroller
        private var lastIndex: Int = -1
        var lastTrigger: Int = 0
        private var isProgrammaticScroll = false
        private var programmaticScrollID = 0
        /// 上次更新的中心索引，用于清理远距离跳转时的旧高亮
        private var lastCenterIndex: Int = -1

        init(_ parent: CalendarScroller) { self.parent = parent }

        @objc func cellClicked(_ sender: DateCell) {
            let index = sender.index
            guard index < parent.dateRange.count else { return }
            let date = parent.dateRange[index]

            parent.selectedDate = date
            parent.centeredDate = date

            if let scrollView = sender.enclosingScrollView {
                isProgrammaticScroll = true
                lastIndex = index
                updateAllCells(scrollView, centerIndex: index, animated: true)
                scrollToCell(scrollView, index: index)
            }
        }

        @objc func boundsChanged(_ notification: Notification) {
            guard let clipView = notification.object as? NSClipView,
                  let scrollView = clipView.enclosingScrollView else { return }
            detectCenteredDate(scrollView, animated: false)
        }

        func scrollToToday(_ scrollView: NSScrollView, animated: Bool) {
            guard let stackView = scrollView.documentView as? DateStackView else { return }
            let todayIndex = parent.dateRange.firstIndex(of: parent.today) ?? 14
            guard todayIndex < stackView.arrangedSubviews.count else { return }
            programmaticScrollID += 1
            isProgrammaticScroll = false

            let cell = stackView.arrangedSubviews[todayIndex]
            let offset = cell.frame.midX - scrollView.contentSize.width / 2
            let point = NSPoint(x: max(0, offset), y: 0)

            CATransaction.begin()
            CATransaction.setDisableActions(!animated)
            if animated {
                CATransaction.setAnimationDuration(0.3)
                CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
            }
            scrollView.contentView.scroll(to: point)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            CATransaction.commit()

            lastIndex = todayIndex
            parent.selectedDate = parent.today
            parent.centeredDate = parent.today
            updateAllCells(scrollView, centerIndex: todayIndex, animated: animated)
        }

        func scrollToCell(_ scrollView: NSScrollView, index: Int) {
            guard let stackView = scrollView.documentView as? DateStackView,
                  index < stackView.arrangedSubviews.count else { return }
            programmaticScrollID += 1
            let scrollID = programmaticScrollID

            let cell = stackView.arrangedSubviews[index]
            let offset = cell.frame.midX - scrollView.contentSize.width / 2
            let point = NSPoint(x: max(0, offset), y: 0)

            CATransaction.begin()
            CATransaction.setAnimationDuration(0.3)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
            scrollView.contentView.animator().scroll(to: point)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            CATransaction.commit()

            // 动画结束后恢复用户滚动检测，并重新确认点击的日期。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self,
                      scrollID == self.programmaticScrollID,
                      index < self.parent.dateRange.count else { return }
                self.isProgrammaticScroll = false
                self.lastIndex = index
                let date = self.parent.dateRange[index]
                self.parent.selectedDate = date
                self.parent.centeredDate = date
                self.updateAllCells(scrollView, centerIndex: index, animated: true)
            }
        }

        func detectCenteredDate(_ scrollView: NSScrollView, animated: Bool) {
            guard !isProgrammaticScroll else { return }
            guard let stackView = scrollView.documentView as? DateStackView else { return }

            let visibleCenterX = scrollView.contentView.bounds.midX
            var bestIndex = 0
            var bestDist: CGFloat = .greatestFiniteMagnitude

            for (index, subview) in stackView.arrangedSubviews.enumerated() {
                let cellCenterX = subview.frame.midX
                let dist = abs(cellCenterX - visibleCenterX)
                if dist < bestDist {
                    bestDist = dist
                    bestIndex = index
                }
            }

            // 中心没变则跳过（避免滚动时每帧都更新）
            guard bestIndex != lastIndex else { return }
            lastIndex = bestIndex

            updateAllCells(scrollView, centerIndex: bestIndex, animated: animated)

            if bestIndex < parent.dateRange.count {
                let date = parent.dateRange[bestIndex]
                parent.selectedDate = date
                parent.centeredDate = date
            }
        }

        /// 更新受影响的 cell（中心 ±3 范围内），并清理旧中心的残留高亮
        private func updateAllCells(_ scrollView: NSScrollView, centerIndex: Int, animated: Bool) {
            guard let stackView = scrollView.documentView as? DateStackView else { return }

            let oldCenter = lastCenterIndex
            lastCenterIndex = centerIndex

            for subview in stackView.arrangedSubviews {
                if let cell = subview as? DateCell {
                    let dist = abs(cell.index - centerIndex)
                    let oldDist = oldCenter >= 0 ? abs(cell.index - oldCenter) : Int.max

                    if dist <= 3 {
                        // 新中心 ±3 范围内：更新放大/高亮
                        cell.updateMagnify(centerIndex: centerIndex, animated: animated)
                    } else if oldDist <= 3 {
                        // 旧中心 ±3 范围内但现在超出新中心范围：重置为默认状态
                        cell.updateMagnify(centerIndex: -999, animated: false)
                    }
                }
            }
        }
    }
}

// MARK: - DateStackView

private class DateStackView: NSStackView {
    override var isFlipped: Bool { true }
}

// MARK: - DateCell

private class DateCell: NSButton {
    let date: Date
    let isToday: Bool
    let index: Int

    private let weekdayLabel = NSTextField(labelWithString: "")
    private let dayLabel = NSTextField(labelWithString: "")
    private let highlightLayer = CALayer()

    init(date: Date, isToday: Bool, index: Int) {
        self.date = date
        self.isToday = isToday
        self.index = index
        super.init(frame: .zero)

        isBordered = false
        wantsLayer = true
        title = ""
        attributedTitle = NSAttributedString(string: "")

        // 高亮背景圆（非今天使用，今天只有文字蓝色）
        highlightLayer.cornerRadius = 12
        highlightLayer.backgroundColor = NSColor.clear.cgColor
        highlightLayer.zPosition = -1
        layer?.addSublayer(highlightLayer)

        // 星期标签
        weekdayLabel.font = .systemFont(ofSize: 8, weight: .medium)
        weekdayLabel.alignment = .center
        weekdayLabel.textColor = isToday ? .systemBlue : .secondaryLabelColor
        weekdayLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(weekdayLabel)

        // 日期数字
        dayLabel.font = .systemFont(ofSize: 11, weight: .medium)
        dayLabel.alignment = .center
        dayLabel.textColor = isToday ? .systemBlue : .labelColor
        dayLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dayLabel)

        // 设置文字
        let formatter = DateFormatter()
        formatter.locale = L10n.isChinese ? Locale(identifier: "zh_CN") : Locale.current
        formatter.dateFormat = "E"
        weekdayLabel.stringValue = formatter.string(from: date)
        dayLabel.stringValue = "\(Calendar.current.component(.day, from: date))"

        // 约束
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 30),
            heightAnchor.constraint(equalToConstant: 40),

            weekdayLabel.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            weekdayLabel.centerXAnchor.constraint(equalTo: centerXAnchor),

            dayLabel.topAnchor.constraint(equalTo: weekdayLabel.bottomAnchor, constant: 2),
            dayLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            dayLabel.widthAnchor.constraint(equalToConstant: 24),
            dayLabel.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // 高亮圆只覆盖日期数字区域
        let size: CGFloat = 24
        highlightLayer.frame = CGRect(
            x: (bounds.width - size) / 2,
            y: bounds.height - size - 2,
            width: size,
            height: size
        )
    }

    // 放大镜效果：根据与中心的距离调整大小
    func updateMagnify(centerIndex: Int, animated: Bool = false) {
        let dist = abs(index - centerIndex)
        let scale: CGFloat
        let yOffset: CGFloat
        switch dist {
        case 0:  scale = 1.3;  yOffset = 4
        case 1:  scale = 1.15; yOffset = 2
        case 2:  scale = 1.05; yOffset = 1
        case 3:  scale = 1.0;  yOffset = 0
        default: scale = 0.92; yOffset = 0
        }

        // 缩放 + 位移全部在 layer transform 中完成，不修改 frame
        var t = CATransform3DIdentity
        t = CATransform3DScale(t, scale, scale, 1)
        t = CATransform3DTranslate(t, 0, yOffset, 0)

        if animated {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.2)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
            layer?.transform = t
            CATransaction.commit()
        } else {
            // 滚动时：禁用隐式动画，直接设置
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.transform = t
            CATransaction.commit()
        }

        // 高亮状态：今天=蓝色文字，中心=白色文字+背景
        let isCenter = dist == 0
        weekdayLabel.textColor = isToday ? .systemBlue : (isCenter ? .white : .secondaryLabelColor)
        dayLabel.textColor = isToday ? .systemBlue : (isCenter ? .labelColor : .secondaryLabelColor)
        highlightLayer.backgroundColor = isCenter && !isToday
            ? NSColor.white.withAlphaComponent(0.15).cgColor
            : NSColor.clear.cgColor

        // 字体始终更新，确保离开中心时字号正确重置
        dayLabel.font = .systemFont(ofSize: isCenter ? 13 : 11, weight: isCenter ? .bold : .medium)
        weekdayLabel.font = .systemFont(ofSize: isCenter ? 9 : 8, weight: isCenter ? .semibold : .medium)
    }
}

#Preview {
    CalendarWidgetView(calendarManager: CalendarManager(), recenterTrigger: .constant(0))
        .background(Color.black)
}
