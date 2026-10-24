import SwiftUI
import EventKit

/// 概览突出下一项安排，详情保留所选日期的全部日程。
struct CalendarWidgetView: View {
    var calendarManager: CalendarManager
    @Binding var recenterTrigger: Int
    var onStartFocus: ((EKEvent) -> Void)?
    var isDetail: Bool = false
    var onShowAll: (() -> Void)? = nil
    @AppStorage("reduceMotion") private var reduceMotion = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var centeredDate = Date()
    @State private var calendarOpenFailed = false

    private var shouldReduceMotion: Bool { reduceMotion || systemReduceMotion }
    private var selectedDate: Binding<Date> {
        Binding(get: { calendarManager.displayedDate }, set: { calendarManager.loadEvents(for: $0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isDetail ? 12 : 8) {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .foregroundStyle(.secondary)
                Text(L10n.widgetCalendar)
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 4)
                Text(L10n.panelCalendarMonth(centeredDate))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .font(.system(size: 13))
            .frame(minHeight: 24)

            CalendarScroller(
                selectedDate: selectedDate,
                centeredDate: $centeredDate,
                recenterTrigger: $recenterTrigger,
                today: today,
                dateRange: dateRange,
                reduceMotion: shouldReduceMotion
            )
            .frame(height: 48)
            .expandedPanelDebugFrame(id: "expandedPanelCalendarDates")

            if !calendarManager.hasAccess {
                accessPrompt
            } else {
                TimelineView(.everyMinute) { context in
                    eventContent(now: context.date)
                }
            }

            if isDetail {
                Button(L10n.calendarOpenApp, systemImage: "calendar") { openCalendar() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.vertical, 6)
            }
            if calendarOpenFailed {
                Text(L10n.calendarOpenFailed).font(.system(size: 11)).foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            calendarManager.ensureAccess()
            centeredDate = calendarManager.displayedDate
        }
    }

    private var accessPrompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isDetail {
                Label(calendarManager.authorizationStatus == .restricted ? L10n.calendarAccessRestricted : L10n.calendarAccessRequired,
                      systemImage: "lock.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(accessActionTitle, action: handleAccessAction)
                    .buttonStyle(.bordered)
            } else {
                Button(action: handleAccessAction) {
                    Label(accessActionTitle, systemImage: "lock.fill")
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            if let error = calendarManager.accessError {
                Text(error).font(.system(size: 11)).foregroundStyle(.orange)
            }
        }
        .font(.system(size: 12))
        .disabled(calendarManager.isRequestingAccess)
    }

    private var accessActionTitle: String {
        calendarManager.authorizationStatus == .notDetermined || calendarManager.authorizationStatus == .writeOnly
            ? L10n.calendarEnableAccess : L10n.calendarOpenSettings
    }

    private func handleAccessAction() {
        if calendarManager.authorizationStatus == .notDetermined || calendarManager.authorizationStatus == .writeOnly {
            Task { await calendarManager.requestAccess() }
        } else {
            SystemPrivacySettings.openCalendars()
        }
    }

    @ViewBuilder
    private func eventContent(now: Date) -> some View {
        let overview = CalendarManager.overviewEvents(calendarManager.upcomingEvents, date: calendarManager.displayedDate, now: now)
        let events = isDetail ? calendarManager.upcomingEvents : Array(overview.prefix(1))
        VStack(alignment: .leading, spacing: 8) {
            if events.isEmpty {
                Label(emptyMessage, systemImage: "calendar.badge.checkmark")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(Array(events.enumerated()), id: \.offset) { index, event in
                    eventRow(event, now: now)
                        .expandedPanelDebugFrame(id: "expandedPanelCalendarEvent-\(index)")
                }
            }
            if !isDetail, !calendarManager.upcomingEvents.isEmpty {
                let hiddenCount = calendarManager.upcomingEvents.count - events.count
                Button {
                    if let onShowAll { onShowAll() } else { openCalendar() }
                } label: {
                    Text(hiddenCount > 0 ? L10n.calendarMoreEvents(hiddenCount) : L10n.calendarAllEvents)
                        .font(.system(size: 11, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyMessage: String {
        if calendarManager.selectedCalendars.isEmpty { return L10n.calendarNoCalendarsSelected }
        if !calendarManager.upcomingEvents.isEmpty { return L10n.calendarAllDone }
        return L10n.calendarNoEventsForDay
    }

    private func eventRow(_ event: EKEvent, now: Date) -> some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(eventColor(event))
                .frame(width: 3, height: isDetail ? 34 : 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.title ?? L10n.untitled)
                    .font(.system(size: isDetail ? 13 : 12, weight: .medium))
                    .lineLimit(isDetail ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(event.isAllDay ? L10n.calendarAllDay : timeString(from: event.startDate) + " – " + timeString(from: event.endDate))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                if event.startDate <= now && event.endDate > now {
                    Text(L10n.calendarInProgress).font(.system(size: 11)).foregroundStyle(Color.accentColor)
                } else if isDetail && event.endDate <= now {
                    Text(L10n.calendarEnded).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if let onStartFocus {
                Button { onStartFocus(event) } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 16))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .help(L10n.calendarStartTask)
                .accessibilityLabel(L10n.calendarStartTask + ": " + (event.title ?? L10n.untitled))
            }
        }
    }

    private func eventColor(_ event: EKEvent) -> Color {
        guard let color = event.calendar?.cgColor else { return .accentColor }
        return Color(cgColor: color)
    }

    private func openCalendar() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") else {
            calendarOpenFailed = true
            return
        }
        calendarOpenFailed = !NSWorkspace.shared.open(url)
    }

    private var today: Date { Calendar.current.startOfDay(for: calendarManager.currentDate) }
    private var dateRange: [Date] {
        CalendarManager.visibleDates(today: today, selectedDate: calendarManager.displayedDate)
    }
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
    private func timeString(from date: Date) -> String { Self.timeFormatter.string(from: date) }
}

// MARK: - AppKit 滚动日期条

private struct CalendarScroller: NSViewRepresentable {
    @Binding var selectedDate: Date
    @Binding var centeredDate: Date
    @Binding var recenterTrigger: Int
    let today: Date
    let dateRange: [Date]
    let reduceMotion: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        context.coordinator.rebuildDates(scrollView)
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator, selector: #selector(Coordinator.boundsChanged(_:)),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )
        DispatchQueue.main.async { [weak coordinator = context.coordinator, weak scrollView] in
            guard let coordinator, let scrollView else { return }
            coordinator.scrollToDate(scrollView, date: coordinator.parent.selectedDate, animated: false)
        }
        return scrollView
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.invalidate()
        NotificationCenter.default.removeObserver(coordinator)
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let datesChanged = context.coordinator.parent.dateRange != dateRange
        let motionChanged = context.coordinator.parent.reduceMotion != reduceMotion
        context.coordinator.parent = self
        if datesChanged { context.coordinator.rebuildDates(nsView) }
        let shouldRecenter = recenterTrigger != context.coordinator.lastTrigger
        context.coordinator.lastTrigger = recenterTrigger
        if shouldRecenter || datesChanged || motionChanged {
            DispatchQueue.main.async { [weak coordinator = context.coordinator, weak nsView] in
                guard let coordinator, let nsView else { return }
                let date = shouldRecenter ? coordinator.parent.today : coordinator.parent.selectedDate
                coordinator.scrollToDate(nsView, date: date, animated: false)
            }
        }
    }

    class Coordinator: NSObject {
        var parent: CalendarScroller
        var lastTrigger: Int
        private var lastIndex = -1
        private var programmaticScrollID = 0
        private var isProgrammaticScroll = true
        private var isInvalidated = false

        init(_ parent: CalendarScroller) {
            self.parent = parent
            lastTrigger = parent.recenterTrigger
        }

        func invalidate() {
            isInvalidated = true
            programmaticScrollID += 1
        }

        func rebuildDates(_ scrollView: NSScrollView) {
            isProgrammaticScroll = true
            programmaticScrollID += 1
            let stack = DateStackView()
            stack.orientation = .horizontal
            stack.spacing = 6
            stack.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 4, right: 12)
            for (index, date) in parent.dateRange.enumerated() {
                let cell = DateCell(date: date, isToday: Calendar.current.isDate(date, inSameDayAs: parent.today), index: index)
                cell.target = self
                cell.action = #selector(cellClicked(_:))
                stack.addArrangedSubview(cell)
            }
            stack.frame = NSRect(x: 0, y: 0, width: CGFloat(parent.dateRange.count) * 36 + 18, height: 48)
            scrollView.documentView = stack
            stack.layoutSubtreeIfNeeded()
        }

        @objc func cellClicked(_ sender: DateCell) {
            guard parent.dateRange.indices.contains(sender.index), let scrollView = sender.enclosingScrollView else { return }
            scrollToDate(scrollView, date: parent.dateRange[sender.index], animated: !parent.reduceMotion)
        }

        func scrollToDate(_ scrollView: NSScrollView, date: Date, animated: Bool) {
            // 即使布局重建后目标不再存在，也不能把日期条永久留在“程序滚动中”。
            isProgrammaticScroll = false
            programmaticScrollID += 1
            guard !isInvalidated,
                  let index = parent.dateRange.firstIndex(where: { Calendar.current.isDate($0, inSameDayAs: date) }),
                  let stack = scrollView.documentView as? DateStackView,
                  stack.arrangedSubviews.indices.contains(index) else { return }
            stack.layoutSubtreeIfNeeded()
            isProgrammaticScroll = true
            let scrollID = programmaticScrollID
            lastIndex = index
            select(index, in: scrollView, animated: animated)
            let offset = stack.arrangedSubviews[index].frame.midX - scrollView.contentSize.width / 2
            let maxOffset = max(0, stack.bounds.width - scrollView.contentSize.width)
            let point = NSPoint(x: min(max(0, offset), maxOffset), y: 0)
            if animated && !parent.reduceMotion {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.25
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    scrollView.contentView.animator().setBoundsOrigin(point)
                } completionHandler: { [weak self, weak scrollView] in
                    guard let self, let scrollView, !self.isInvalidated,
                          scrollID == self.programmaticScrollID else { return }
                    self.isProgrammaticScroll = false
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                }
            } else {
                scrollView.contentView.scroll(to: point)
                scrollView.reflectScrolledClipView(scrollView.contentView)
                isProgrammaticScroll = false
            }
        }

        @objc func boundsChanged(_ notification: Notification) {
            guard !isInvalidated, !isProgrammaticScroll,
                  let clipView = notification.object as? NSClipView,
                  let scrollView = clipView.enclosingScrollView,
                  let stack = scrollView.documentView as? DateStackView else { return }
            let center = clipView.bounds.midX
            guard let index = stack.arrangedSubviews.enumerated().min(by: {
                abs($0.element.frame.midX - center) < abs($1.element.frame.midX - center)
            })?.offset, index != lastIndex else { return }
            lastIndex = index
            select(index, in: scrollView, animated: false)
        }

        private func select(_ index: Int, in scrollView: NSScrollView, animated: Bool) {
            guard parent.dateRange.indices.contains(index), let stack = scrollView.documentView as? DateStackView else { return }
            let date = parent.dateRange[index]
            if !Calendar.current.isDate(parent.selectedDate, inSameDayAs: date) { parent.selectedDate = date }
            if parent.centeredDate != date { parent.centeredDate = date }
            for case let cell as DateCell in stack.arrangedSubviews {
                cell.updateMagnify(centerIndex: index, animated: animated && !parent.reduceMotion, reduceMotion: parent.reduceMotion)
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
    private var isCentered = false

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
        weekdayLabel.font = .systemFont(ofSize: 11, weight: .medium)
        weekdayLabel.alignment = .center
        weekdayLabel.textColor = isToday ? .systemBlue : .secondaryLabelColor
        weekdayLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(weekdayLabel)

        // 日期数字
        dayLabel.font = .systemFont(ofSize: 13, weight: .medium)
        dayLabel.alignment = .center
        dayLabel.textColor = isToday ? .systemBlue : .labelColor
        dayLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dayLabel)

        // 设置文字
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L10n.isChinese ? "zh_CN" : "en_US")
        formatter.dateFormat = "E"
        weekdayLabel.stringValue = formatter.string(from: date)
        dayLabel.stringValue = "\(Calendar.current.component(.day, from: date))"
        formatter.dateStyle = .full
        setAccessibilityLabel(formatter.string(from: date))

        // NSTextField 的 frame 还包含对齐外沿，限制其宽度时需一并扣除。
        let weekdayInsets = weekdayLabel.alignmentRectInsets
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 30),
            heightAnchor.constraint(equalToConstant: 40),

            weekdayLabel.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            weekdayLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            weekdayLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor,
                constant: -weekdayInsets.left - weekdayInsets.right),

            dayLabel.topAnchor.constraint(equalTo: weekdayLabel.bottomAnchor),
            dayLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            dayLabel.widthAnchor.constraint(equalToConstant: 24),
            dayLabel.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

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
    func updateMagnify(centerIndex: Int, animated: Bool = false, reduceMotion: Bool = false) {
        let dist = abs(index - centerIndex)
        let scale: CGFloat
        let yOffset: CGFloat
        switch dist {
        case 0:  scale = 1.08; yOffset = 1
        case 1:  scale = 1.04; yOffset = 0
        case 2:  scale = 1.0;  yOffset = 0
        case 3:  scale = 1.0;  yOffset = 0
        default: scale = 1.0; yOffset = 0
        }

        // 缩放 + 位移全部在 layer transform 中完成，不修改 frame
        var t = CATransform3DIdentity
        if !reduceMotion {
            t = CATransform3DScale(t, scale, scale, 1)
            t = CATransform3DTranslate(t, 0, yOffset, 0)
        }

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

        isCentered = dist == 0
        updateColors()

        // 字体始终更新，确保离开中心时字号正确重置
        dayLabel.font = .systemFont(ofSize: 13, weight: isCentered ? .bold : .medium)
        weekdayLabel.font = .systemFont(ofSize: 11, weight: isCentered ? .semibold : .medium)
    }

    private func updateColors() {
        let textColor: NSColor = isToday ? .systemBlue : (isCentered ? .labelColor : .secondaryLabelColor)
        weekdayLabel.textColor = textColor
        dayLabel.textColor = textColor
        // CALayer 保存的是解析后的 CGColor，切换外观时需要重新取语义颜色。
        effectiveAppearance.performAsCurrentDrawingAppearance {
            highlightLayer.backgroundColor = isCentered && !isToday
                ? NSColor.labelColor.withAlphaComponent(0.12).cgColor
                : NSColor.clear.cgColor
        }
    }
}

#if !XNOOK_DISABLE_PREVIEWS
#Preview {
    CalendarWidgetView(calendarManager: CalendarManager(), recenterTrigger: .constant(0), onStartFocus: nil)
        .background(Color.black)
}
#endif
