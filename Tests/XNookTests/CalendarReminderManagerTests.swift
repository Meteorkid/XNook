import XCTest
@testable import XNook

@MainActor
final class CalendarReminderManagerTests: XCTestCase {
    func testQuietHoursDisabledReturnsFalse() {
        XCTAssertFalse(
            CalendarReminderManager.isQuietHoursActive(
                enabled: false,
                start: "22:00",
                end: "07:00",
                now: date(hour: 23, minute: 0)
            )
        )
    }

    func testQuietHoursHandlesSameDayWindow() {
        XCTAssertTrue(
            CalendarReminderManager.isQuietHoursActive(
                enabled: true,
                start: "09:00",
                end: "18:00",
                now: date(hour: 10, minute: 30)
            )
        )
        XCTAssertFalse(
            CalendarReminderManager.isQuietHoursActive(
                enabled: true,
                start: "09:00",
                end: "18:00",
                now: date(hour: 20, minute: 0)
            )
        )
    }

    func testQuietHoursHandlesOvernightWindow() {
        XCTAssertTrue(
            CalendarReminderManager.isQuietHoursActive(
                enabled: true,
                start: "22:00",
                end: "07:00",
                now: date(hour: 23, minute: 15)
            )
        )
        XCTAssertTrue(
            CalendarReminderManager.isQuietHoursActive(
                enabled: true,
                start: "22:00",
                end: "07:00",
                now: date(hour: 6, minute: 45)
            )
        )
        XCTAssertFalse(
            CalendarReminderManager.isQuietHoursActive(
                enabled: true,
                start: "22:00",
                end: "07:00",
                now: date(hour: 12, minute: 0)
            )
        )
    }

    func testNextReminderReturnsEarliestDueUnnotifiedEvent() {
        let now = date(hour: 9, minute: 0)
        let candidates = [
            CalendarReminderManager.ReminderCandidate(identifier: "later", startDate: date(hour: 9, minute: 8)),
            CalendarReminderManager.ReminderCandidate(identifier: "soon", startDate: date(hour: 9, minute: 3)),
        ]

        let result = CalendarReminderManager.nextReminder(
            candidates: candidates,
            now: now,
            leadTime: 5 * 60,
            notifiedKeys: []
        )

        XCTAssertEqual(result?.identifier, "soon")
    }

    func testNextReminderSkipsNotifiedAndOutOfWindowEvents() {
        let now = date(hour: 9, minute: 0)
        let soonDate = date(hour: 9, minute: 3)
        let farDate = date(hour: 9, minute: 12)
        let notifiedKey = "soon@\(soonDate.timeIntervalSince1970)"
        let candidates = [
            CalendarReminderManager.ReminderCandidate(identifier: "soon", startDate: soonDate),
            CalendarReminderManager.ReminderCandidate(identifier: "far", startDate: farDate),
        ]

        let result = CalendarReminderManager.nextReminder(
            candidates: candidates,
            now: now,
            leadTime: 5 * 60,
            notifiedKeys: [notifiedKey]
        )

        XCTAssertNil(result)
    }

    private func date(hour: Int, minute: Int) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 7
        components.day = 4
        components.hour = hour
        components.minute = minute
        components.second = 0
        return Calendar(identifier: .gregorian).date(from: components)!
    }
}
