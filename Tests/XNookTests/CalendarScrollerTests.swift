import AppKit
import Observation
import SwiftUI
import XCTest
@testable import XNook

/// XNOOK_RENDER_UI=1 swift test --filter CalendarScrollerTests
@MainActor
final class CalendarScrollerTests: XCTestCase {
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
            let stack = try XCTUnwrap(scroll.documentView as? NSStackView)
            let dates = CalendarManager.visibleDates(today: manager.currentDate, selectedDate: selected)
            let index = try XCTUnwrap(dates.firstIndex { Calendar.current.isDate($0, inSameDayAs: selected) })
            let button = try XCTUnwrap(stack.arrangedSubviews[index + 1] as? NSButton)
            button.performClick(nil)
            settle(host)
            XCTAssertTrue(Calendar.current.isDate(manager.displayedDate, inSameDayAs: dates[index + 1]))
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
                        let stack = try XCTUnwrap(scroll.documentView as? NSStackView)
                        let dates = CalendarManager.visibleDates(today: today, selectedDate: expected)
                        let index = try XCTUnwrap(dates.firstIndex { Calendar.current.isDate($0, inSameDayAs: expected) })
                        XCTAssertTrue(scroll.contentView.bounds.contains(stack.arrangedSubviews[index].frame),
                                      "箭头外部选日后，原生日期条必须滚动到可见位置")
                    }

                    let scroll = try dateScroller(in: host)
                    let stack = try XCTUnwrap(scroll.documentView as? NSStackView)
                    let dates = CalendarManager.visibleDates(today: today, selectedDate: manager.displayedDate)
                    let index = direction > 0 ? dates.count - 2 : 1
                    let button = try XCTUnwrap(stack.arrangedSubviews[index] as? NSButton)
                    button.performClick(nil)
                    settle(host)
                    XCTAssertTrue(Calendar.current.isDate(manager.displayedDate, inSameDayAs: dates[index]),
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

    private func withCalendar(isDetail: Bool,
                              verify: (NSView, NSWindow, CalendarScrollerTestModel, CalendarManager) throws -> Void) throws {
        let originalArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        var arguments = originalArguments
        arguments["reduceMotion"] = true
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(originalArguments, forName: UserDefaults.argumentDomain) }
        let now = Date()
        let manager = CalendarManager(now: { now }, observeChanges: false,
            readAuthorization: { .denied }, fetchCalendars: { [] },
            requestFullAccess: { XCTFail("日期滚动不能触发权限请求"); return false }, didRefreshAuthorization: {})
        manager.loadEvents(for: try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 5, to: now)))
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
