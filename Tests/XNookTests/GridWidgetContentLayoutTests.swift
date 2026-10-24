import XCTest
@testable import XNook

final class GridWidgetContentLayoutTests: XCTestCase {
    func testMinimumCardBodyBudgetsLeaveRoomForOverviewActions() {
        XCTAssertEqual(GridWidgetContentLayout.rowLimit(height: 160, reserved: 100, rowHeight: 36, maximum: 2), 1)
        XCTAssertEqual(GridWidgetContentLayout.rowLimit(height: 160, reserved: 54, rowHeight: 44, maximum: 4), 2)
        XCTAssertEqual(GridWidgetContentLayout.rowLimit(height: 160, reserved: 84, rowHeight: 44, maximum: 4), 1)
        XCTAssertEqual(GridWidgetContentLayout.rowLimit(height: 112, reserved: 36, rowHeight: 44, maximum: 4), 1)
        XCTAssertEqual(GridWidgetContentLayout.rowLimit(height: 160, reserved: 36, rowHeight: 44, maximum: 4), 2)
        XCTAssertEqual(GridWidgetContentLayout.rowLimit(height: 112, reserved: 58, rowHeight: 44, maximum: 4), 1)
    }

    func testUnboundedLegacyCallsAndExtremeBudgetsHaveFiniteLimits() {
        for height: CGFloat? in [nil, .infinity, .nan, .greatestFiniteMagnitude] {
            XCTAssertEqual(GridWidgetContentLayout.rowLimit(height: height, reserved: 54, rowHeight: 44, maximum: 4), 4)
        }
        XCTAssertEqual(GridWidgetContentLayout.rowLimit(height: -1, reserved: 54, rowHeight: 44, maximum: 4), 1)
    }

    func testResizingUsesWholeDateGroupsWithoutChangingTheirSelectedCenter() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let selected = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 18)))
        for (width, expectedCount) in [(CGFloat(196), 3), (CGFloat(296), 5), (CGFloat(456), 7), (CGFloat(196), 3)] {
            let dates = GridWidgetContentLayout.calendarDates(selected: selected, width: width, calendar: calendar)
            XCTAssertEqual(dates.count, expectedCount)
            XCTAssertEqual(dates[dates.count / 2], calendar.startOfDay(for: selected))
            XCTAssertEqual(Set(dates).count, expectedCount)
            XCTAssertTrue(dates.allSatisfy { calendar.component(.hour, from: $0) == 0 })
        }
    }

    func testCompleteDateGroupsFollowCalendarDaysAcrossDaylightSavingChange() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let selected = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12)))
        let dates = GridWidgetContentLayout.calendarDates(selected: selected, width: 456, calendar: calendar)
        XCTAssertEqual(dates.map { calendar.component(.day, from: $0) }, [5, 6, 7, 8, 9, 10, 11])
        XCTAssertTrue(dates.allSatisfy { calendar.component(.hour, from: $0) == 0 })
    }

    func testViewportResizeAndOriginClampingAreNotUserScrolls() {
        var state = GridWidgetCalendarScrollState()
        XCTAssertEqual(state.update(CGRect(x: 300, y: 0, width: 196, height: 48)), .layout)
        XCTAssertEqual(state.update(CGRect(x: 300, y: 0, width: 196, height: 48)), .unchanged)
        XCTAssertEqual(state.update(CGRect(x: 200, y: 0, width: 456, height: 48)), .layout)
        XCTAssertEqual(state.update(CGRect(x: 272, y: 0, width: 456, height: 48)), .scroll)
        XCTAssertEqual(state.update(CGRect(x: 272, y: 0, width: 456, height: 60)), .layout)
    }
}
