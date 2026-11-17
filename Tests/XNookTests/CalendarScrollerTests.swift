import AppKit
import Observation
import SwiftUI
import XCTest
@testable import XNook

/// XNOOK_RENDER_UI=1 swift test --filter CalendarScrollerTests
@MainActor
final class CalendarScrollerTests: XCTestCase {
    func testNativeViewportScrollingContinuesAcrossMonthBoundaries() throws {
        try requireRendering()
        for isDetail in [false, true] {
            for direction in [-1, 1] {
                try withCalendar(isDetail: isDetail, initialDayOffset: 0) { host, _, _, manager in
                    let scroll = try dateScroller(in: host)
                    let originalClip = scroll.contentView
                    let originalStack = try XCTUnwrap(scroll.documentView as? NSStackView)
                    let outerScroll = try XCTUnwrap(scroll.enclosingScrollView)
                    let outerOrigin = outerScroll.contentView.bounds.origin
                    let today = manager.displayedDate
                    // 保留不足一天的手势位移，窗口滑移也不能把它吸回日期中心。
                    scrollViewport(by: CGFloat(direction) * 12, in: scroll, host: host)
                    let initialButton = try dateButton(for: today, in: scroll)
                    let centerOffset = initialButton.frame.midX - scroll.contentView.bounds.midX
                    XCTAssertEqual(centerOffset, -CGFloat(direction) * 12, accuracy: 0.5)
                    for step in 1...40 {
                        let previous = manager.displayedDate
                        let previousButton = try dateButton(for: previous, in: scroll)
                        // 只推进原生视口，不借助箭头或外部选日越过日期范围边界。
                        let proposedBounds = scroll.contentView.bounds.offsetBy(dx: CGFloat(direction) * 72, dy: 0)
                        scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(proposedBounds).origin)
                        scroll.reflectScrolledClipView(scroll.contentView)
                        settle(host)

                        XCTAssertEqual(outerScroll.contentView.bounds.origin, outerOrigin,
                                       "跨月横滚不应移动父级纵向面板")
                        XCTAssertTrue(try dateScroller(in: host) === scroll)
                        XCTAssertTrue(scroll.contentView === originalClip)
                        XCTAssertTrue(scroll.documentView === originalStack,
                                      "日期窗口滑移应保留原生文档视图")
                        XCTAssertEqual(originalStack.arrangedSubviews.count, 181,
                                       "连续滚动不能让日期窗口无限增长")
                        guard !Calendar.current.isDate(manager.displayedDate, inSameDayAs: previous) else {
                            XCTFail("连续横滚在第 \(step) 步停止选日：\(manager.displayedDate)，方向 \(direction)，详情 \(isDetail)，origin=\(scroll.contentView.bounds.origin.x)，viewport=\(scroll.contentSize.width)")
                            return
                        }
                        let expected = try XCTUnwrap(Calendar.current.date(byAdding: .day,
                            value: direction * step * 2, to: today))
                        XCTAssertTrue(Calendar.current.isDate(manager.displayedDate, inSameDayAs: expected),
                                      "日期范围更新后应继续按原生位移选日，不能跳动或回弹")
                        let button = try dateButton(for: expected, in: scroll)
                        XCTAssertTrue(try dateButton(for: previous, in: scroll) === previousButton,
                                      "窗口滑移应复用仍在可见区域的日期按钮")
                        XCTAssertEqual(button.frame.midX - scroll.contentView.bounds.midX, centerOffset, accuracy: 0.5,
                                       "日期范围滑移应保持所选日期在视口中的位置")
                    }
                    XCTAssertEqual(Calendar.current.component(.month, from: manager.displayedDate), direction < 0 ? 8 : 1,
                                   "从固定的 10 月 30 日出发，纯横滚必须能连续跨月")
                    XCTAssertEqual(Calendar.current.component(.year, from: manager.displayedDate), direction < 0 ? 2026 : 2027)
                    let clickedDate = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: direction,
                                                                         to: manager.displayedDate))
                    try dateButton(for: clickedDate, in: scroll).performClick(nil)
                    settle(host)
                    try assertCenteredSelection(clickedDate, manager: manager, scroll: scroll)
                }
            }
        }
    }

    func testOverviewAndDetailSelectCenteredDayWhenNativeViewportScrolls() throws {
        try requireRendering()
        for isDetail in [false, true] {
            try withCalendar(isDetail: isDetail) { host, _, model, manager in
                let scroll = try dateScroller(in: host)
                let outerScroll = try XCTUnwrap(scroll.enclosingScrollView)
                let origin = scroll.contentView.bounds.origin
                let outerOrigin = outerScroll.contentView.bounds.origin
                let selected = manager.displayedDate
                XCTAssertEqual(scroll.frame.height, isDetail ? 48 : 40, accuracy: 0.5)

                // 隐藏测试窗口不运行触控板滚动动画，直接改变原生视口验证选日链路。
                scroll.contentView.scroll(to: CGPoint(x: origin.x - 84, y: origin.y))
                scroll.reflectScrolledClipView(scroll.contentView)
                settle(host)

                XCTAssertEqual(scroll.contentView.bounds.origin.x, origin.x - 84, accuracy: 0.5,
                               "原生选日后的 SwiftUI 更新不能把横滚吸回日期中心")
                XCTAssertEqual(outerScroll.contentView.bounds.origin, outerOrigin,
                               "日期横滚不应移动父级纵向面板")
                let expected = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -2, to: selected))
                XCTAssertTrue(Calendar.current.isDate(manager.displayedDate, inSameDayAs: expected),
                              "概览与详情的原生视口横移应选择相同的中心日期")

                model.recenterTrigger += 1
                settle(host)
                XCTAssertTrue(Calendar.current.isDate(manager.displayedDate, inSameDayAs: manager.currentDate))
            }
        }
    }

    func testNativeViewportRemainsResponsiveAfterResizeExternalSelectionAndRecenter() throws {
        try requireRendering()
        for isDetail in [false, true] {
            try withCalendar(isDetail: isDetail, initialDayOffset: 180) { host, window, model, manager in
                let scroll = try dateScroller(in: host)
                let outerScroll = try XCTUnwrap(scroll.enclosingScrollView)
                let outerOrigin = outerScroll.contentView.bounds.origin
                let initial = manager.displayedDate

                scrollViewport(by: -84, in: scroll, host: host)
                let selected = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -2, to: initial))
                XCTAssertTrue(Calendar.current.isDate(manager.displayedDate, inSameDayAs: selected))
                let scrolledOrigin = scroll.contentView.bounds.origin
                settle(host)
                XCTAssertEqual(scroll.contentView.bounds.origin.x, scrolledOrigin.x, accuracy: 0.5,
                               "原生横滚后的后续更新不能吸回日期中心")

                for width: CGFloat in [480, 720, 320, 220] {
                    model.width = width
                    window.setContentSize(CGSize(width: width, height: 220))
                    settle(host)
                    try assertCenteredSelection(selected, manager: manager, scroll: scroll)
                }
                scrollViewport(by: 72, in: scroll, host: host)
                try assertCenteredSelection(initial, manager: manager, scroll: scroll)

                let external = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -400, to: manager.currentDate))
                manager.loadEvents(for: external)
                settle(host)
                try assertCenteredSelection(external, manager: manager, scroll: scroll)
                scrollViewport(by: 72, in: scroll, host: host)
                let afterExternal = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 2, to: external))
                try assertCenteredSelection(afterExternal, manager: manager, scroll: scroll)

                model.recenterTrigger += 1
                settle(host)
                try assertCenteredSelection(manager.currentDate, manager: manager, scroll: scroll)
                scrollViewport(by: -72, in: scroll, host: host)
                let afterToday = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -2, to: manager.currentDate))
                settle(host)
                try assertCenteredSelection(afterToday, manager: manager, scroll: scroll)
                XCTAssertEqual(outerScroll.contentView.bounds.origin, outerOrigin,
                               "缩放、外部选日与回今天都不应移动父级纵向面板")
            }
        }
    }

    func testExternalSelectionNearWindowEdgesKeepsBothSidesScrollable() throws {
        try requireRendering()
        for isDetail in [false, true] {
            try withCalendar(isDetail: isDetail, initialDayOffset: 0) { host, _, _, manager in
                let scroll = try dateScroller(in: host)
                let today = manager.currentDate
                for dayOffset in [-90, -89, 89, 90] {
                    manager.loadEvents(for: today)
                    settle(host)
                    let selected = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: dayOffset, to: today))
                    manager.loadEvents(for: selected)
                    settle(host)
                    try assertCenteredSelection(selected, manager: manager, scroll: scroll)
                    for bufferOffset in [-90, 90] {
                        let date = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: bufferOffset, to: selected))
                        _ = try dateButton(for: date, in: scroll)
                    }

                    scrollViewport(by: -72, in: scroll, host: host)
                    let previous = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -2, to: selected))
                    try assertCenteredSelection(previous, manager: manager, scroll: scroll)
                    scrollViewport(by: 144, in: scroll, host: host)
                    let next = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 2, to: selected))
                    try assertCenteredSelection(next, manager: manager, scroll: scroll)
                }
            }
        }
    }

    func testOverviewResizeKeepsSelectedDayAndDateButtonsStillSelect() throws {
        try requireRendering()
        try withCalendar(isDetail: false) { host, window, model, manager in
            let selected = manager.displayedDate
            for width: CGFloat in [480, 720, 320, 220] {
                model.width = width
                window.setContentSize(CGSize(width: width, height: 220))
                settle(host)
                let scroll = try dateScroller(in: host)
                XCTAssertEqual(scroll.frame.width, width - 24 - 44, accuracy: 0.5)
                XCTAssertEqual(scroll.frame.height, 40, accuracy: 0.5)
                XCTAssertTrue(Calendar.current.isDate(manager.displayedDate, inSameDayAs: selected),
                              "宽度变化只调整可见日期，不应改变选中日期")
            }

            let scroll = try dateScroller(in: host)
            let expected = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 1, to: selected))
            let button = try dateButton(for: expected, in: scroll)
            button.performClick(nil)
            settle(host)
            XCTAssertTrue(Calendar.current.isDate(manager.displayedDate, inSameDayAs: expected))
        }
    }

    func testOverviewNavigationKeepsPagingBeyondTwoWeeksAndAllowsDateSelection() throws {
        try requireRendering()
        try withCalendar(isDetail: false) { host, window, model, manager in
            let today = Calendar.current.startOfDay(for: manager.currentDate)
            let widget = CalendarWidgetView(calendarManager: manager, recenterTrigger: .constant(0), availableHeight: 160)
            for (width, step): (CGFloat, Int) in [(220, 3), (320, 5), (480, 7)] {
                model.width = width
                window.setContentSize(CGSize(width: width, height: 220))
                settle(host)
                for direction in [-1, 1] {
                    manager.loadEvents(for: today)
                    settle(host)
                    for page in 1...6 {
                        // 离屏 SwiftUI 不暴露箭头 AX 节点，调用两个按钮共用的生产动作。
                        widget.navigateOverviewDates(forward: direction > 0, width: width - 24)
                        settle(host)
                        let expected = try XCTUnwrap(Calendar.current.date(byAdding: .day,
                            value: direction * step * page, to: today))
                        XCTAssertTrue(Calendar.current.isDate(manager.displayedDate, inSameDayAs: expected),
                                      "概览箭头需保留原宽度对应的翻页步长，并可翻过两周")
                        let scroll = try dateScroller(in: host)
                        let button = try dateButton(for: expected, in: scroll)
                        XCTAssertTrue(scroll.contentView.bounds.contains(button.frame),
                                      "箭头外部选日后，原生日期条必须滚动到可见位置")
                    }

                    let scroll = try dateScroller(in: host)
                    let expected = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -direction, to: manager.displayedDate))
                    let button = try dateButton(for: expected, in: scroll)
                    button.performClick(nil)
                    settle(host)
                    XCTAssertTrue(Calendar.current.isDate(manager.displayedDate, inSameDayAs: expected),
                                  "翻到原两周范围以外后仍应可以点击选日")

                    let selectedBeforeScroll = manager.displayedDate
                    let origin = scroll.contentView.bounds.origin
                    scroll.contentView.scroll(to: CGPoint(x: origin.x - CGFloat(direction) * 72, y: origin.y))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    settle(host)
                    XCTAssertFalse(Calendar.current.isDate(manager.displayedDate, inSameDayAs: selectedBeforeScroll),
                                   "翻到原两周范围以外后仍应可以滚动选日")
                }
            }
        }
    }

    private func requireRendering() throws {
        guard ProcessInfo.processInfo.environment["XNOOK_RENDER_UI"] == "1" else {
            throw XCTSkip("使用 XNOOK_RENDER_UI=1 执行隔离原生日期滚动验证")
        }
        _ = NSApplication.shared
    }

    private func withCalendar(isDetail: Bool, initialDayOffset: Int = 5,
                              verify: (NSView, NSWindow, CalendarScrollerTestModel, CalendarManager) throws -> Void) throws {
        let originalArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        var arguments = originalArguments
        arguments["reduceMotion"] = true
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(originalArguments, forName: UserDefaults.argumentDomain) }
        let now = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 12)))
        let manager = CalendarManager(now: { now }, observeChanges: false,
            readAuthorization: { .denied }, fetchCalendars: { [] },
            requestFullAccess: { XCTFail("日期滚动不能触发权限请求"); return false }, didRefreshAuthorization: {})
        manager.loadEvents(for: try XCTUnwrap(Calendar.current.date(byAdding: .day, value: initialDayOffset, to: now)))
        let model = CalendarScrollerTestModel()
        let host = NSHostingView(rootView: CalendarScrollerTestSurface(model: model, manager: manager, isDetail: isDetail))
        host.frame = CGRect(x: 0, y: 0, width: model.width, height: 220)
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: model.width, height: 220),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close(); manager.stopMonitoring() }
        settle(host)
        XCTAssertFalse(window.isVisible)
        try verify(host, window, model, manager)
    }

    private func dateScroller(in host: NSView) throws -> NSScrollView {
        try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }
            .first { $0.documentView is NSStackView }, "概览与详情都必须有原生日期滚动条")
    }

    private func dateButton(for date: Date, in scroll: NSScrollView) throws -> NSButton {
        let stack = try XCTUnwrap(scroll.documentView as? NSStackView)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L10n.isChinese ? "zh_CN" : "en_US")
        formatter.dateStyle = .full
        let label = formatter.string(from: date)
        return try XCTUnwrap(stack.arrangedSubviews.compactMap { $0 as? NSButton }
            .first { $0.accessibilityLabel() == label }, "日期条缺少日期 \(label)")
    }

    private func scrollViewport(by distance: CGFloat, in scroll: NSScrollView, host: NSView) {
        let proposedBounds = scroll.contentView.bounds.offsetBy(dx: distance, dy: 0)
        scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(proposedBounds).origin)
        scroll.reflectScrolledClipView(scroll.contentView)
        settle(host)
    }

    private func assertCenteredSelection(_ date: Date, manager: CalendarManager, scroll: NSScrollView,
                                         file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(Calendar.current.isDate(manager.displayedDate, inSameDayAs: date),
                      "布局或程序定位后的原生滚动必须保持预期选日", file: file, line: line)
        let button = try dateButton(for: date, in: scroll)
        let stack = try XCTUnwrap(scroll.documentView as? NSStackView)
        XCTAssertEqual(stack.arrangedSubviews.count, 181,
                       "外部选日、缩放和回今天都应保持日期窗口有界", file: file, line: line)
        XCTAssertEqual(button.frame.midX, scroll.contentView.bounds.midX, accuracy: 0.5,
                       "布局或程序定位后应以所选日期居中", file: file, line: line)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func settle(_ host: NSView) {
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }
}

@MainActor @Observable
private final class CalendarScrollerTestModel {
    var width: CGFloat = 220
    var recenterTrigger = 0
}

@MainActor
private struct CalendarScrollerTestSurface: View {
    @Bindable var model: CalendarScrollerTestModel
    let manager: CalendarManager
    let isDetail: Bool

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                CalendarWidgetView(calendarManager: manager, recenterTrigger: $model.recenterTrigger,
                                   isDetail: isDetail, availableHeight: 160)
                    .frame(width: model.width - 24)
                    .padding(12)
                Color.clear.frame(height: 600)
            }
        }
        .frame(width: model.width, height: 220)
    }
}
