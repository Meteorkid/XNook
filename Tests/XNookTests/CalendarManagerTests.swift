import XCTest
@testable import XNook

@MainActor
final class CalendarManagerTests: XCTestCase {
    func testEventIntervalCoversSelectedCalendarDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let selectedDate = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 6, day: 30, hour: 14))
        )

        let interval = try XCTUnwrap(
            CalendarManager.eventInterval(for: selectedDate, calendar: calendar)
        )

        XCTAssertEqual(calendar.component(.hour, from: interval.start), 0)
        XCTAssertEqual(calendar.component(.day, from: interval.start), 30)
        XCTAssertEqual(calendar.component(.day, from: interval.end), 1)
    }
}
