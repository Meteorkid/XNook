import XCTest
import AppKit
import EventKit
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

    func testSelectedCalendarsUseAllCalendarsWhenNoPreferenceExists() {
        XCTAssertEqual(
            CalendarManager.selectedCalendarIdentifiers(
                availableIdentifiers: ["work", "personal"],
                storedIdentifiers: nil
            ),
            ["work", "personal"]
        )
    }

    func testVisibleDatesKeepNinetyDaysOnEitherSideOfTheSelection() throws {
        let fixture = CalendarFixture()
        let dates = CalendarManager.visibleDates(centeredOn: fixture.now, calendar: fixture.calendar)
        let selected = fixture.calendar.startOfDay(for: fixture.now)
        XCTAssertEqual(dates.count, 181)
        XCTAssertEqual(dates.dropFirst(90).first, selected)
        XCTAssertEqual(dates.first, try XCTUnwrap(fixture.calendar.date(byAdding: .day, value: -90, to: selected)))
        XCTAssertEqual(dates.last, try XCTUnwrap(fixture.calendar.date(byAdding: .day, value: 90, to: selected)))
    }

    func testVisibleDatesNormalizeSelectionToTheCalendarDay() throws {
        let fixture = CalendarFixture()
        let selected = try XCTUnwrap(fixture.calendar.date(from: DateComponents(year: 2026, month: 12, day: 31,
                                                                                hour: 23, minute: 59, second: 59)))
        let dates = CalendarManager.visibleDates(centeredOn: selected, calendar: fixture.calendar)
        XCTAssertEqual(dates.dropFirst(90).first, fixture.calendar.startOfDay(for: selected))
        XCTAssertTrue(dates.allSatisfy { $0 == fixture.calendar.startOfDay(for: $0) })
        XCTAssertEqual(fixture.calendar.component(.year, from: try XCTUnwrap(dates.last)), 2027)
    }

    func testVisibleDatesStayBoundedForDistantSelections() throws {
        let fixture = CalendarFixture()
        for dayOffset in [-3650, -400, 400, 3650] {
            let selected = try XCTUnwrap(fixture.calendar.date(byAdding: .day, value: dayOffset, to: fixture.now))
            let dates = CalendarManager.visibleDates(centeredOn: selected, calendar: fixture.calendar)
            XCTAssertEqual(dates.count, 181)
            XCTAssertEqual(dates.dropFirst(90).first, fixture.calendar.startOfDay(for: selected))
            XCTAssertFalse(dates.contains(fixture.calendar.startOfDay(for: fixture.now)),
                           "远期浏览只保留所选日期周围的缓冲，不铺满今天至目标日之间的日期")
            XCTAssertEqual(Set(dates).count, dates.count)
        }
    }

    func testVisibleDatesRemainContiguousAcrossMonthAndYearBoundaries() throws {
        let fixture = CalendarFixture()
        for month in [1, 10, 12] {
            let selected = try XCTUnwrap(fixture.calendar.date(from: DateComponents(year: 2026, month: month, day: 1)))
            let dates = CalendarManager.visibleDates(centeredOn: selected, calendar: fixture.calendar)
            XCTAssertEqual(Set(dates).count, 181)
            for (previous, next) in zip(dates, dates.dropFirst()) {
                XCTAssertEqual(next, fixture.calendar.date(byAdding: .day, value: 1, to: previous),
                               "跨月和跨年日期必须连续，不能遗漏或重复")
            }
        }
    }

    func testVisibleDatesStayOnCalendarDaysAcrossSpringDaylightSavingChange() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let selected = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 12)))
        let dates = CalendarManager.visibleDates(centeredOn: selected, calendar: calendar)
        XCTAssertEqual(dates.count, 181)
        XCTAssertEqual(dates.dropFirst(90).first, calendar.startOfDay(for: selected))
        XCTAssertTrue(dates.allSatisfy { $0 == calendar.startOfDay(for: $0) })
        XCTAssertEqual(zip(dates, dates.dropFirst()).filter { $0.1.timeIntervalSince($0.0) == 23 * 3600 }.count, 1)
    }

    func testVisibleDatesStayOnCalendarDaysAcrossAutumnDaylightSavingChange() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let selected = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 12)))
        let dates = CalendarManager.visibleDates(centeredOn: selected, calendar: calendar)
        XCTAssertEqual(dates.count, 181)
        XCTAssertEqual(dates.dropFirst(90).first, calendar.startOfDay(for: selected))
        XCTAssertTrue(dates.allSatisfy { $0 == calendar.startOfDay(for: $0) })
        XCTAssertEqual(zip(dates, dates.dropFirst()).filter { $0.1.timeIntervalSince($0.0) == 25 * 3600 }.count, 1)
    }

    func testSelectedCalendarsPreserveExplicitEmptyPreference() {
        XCTAssertEqual(
            CalendarManager.selectedCalendarIdentifiers(
                availableIdentifiers: ["work", "personal"],
                storedIdentifiers: []
            ),
            []
        )
    }

    func testOverviewSkipsEndedEventsAndKeepsActiveBeforeUpcoming() {
        let fixture = CalendarFixture()
        let ended = fixture.event("Ended", start: -3600, end: -60)
        let active = fixture.event("Active", start: -600, end: 600)
        let next = fixture.event("Next", start: 1200, end: 1800)
        let results = CalendarManager.overviewEvents([next, ended, active], date: fixture.now, now: fixture.now, calendar: fixture.calendar)
        XCTAssertEqual(results.map(\.title), ["Active", "Next"])
    }

    func testOverviewIsEmptyWhenAllEventsEndedButFullDayRetainsThem() {
        let fixture = CalendarFixture()
        let ended = fixture.event("Ended", start: -3600, end: -60)
        XCTAssertTrue(CalendarManager.overviewEvents([ended], date: fixture.now, now: fixture.now, calendar: fixture.calendar).isEmpty)
        XCTAssertEqual(CalendarManager.eventsForDay([ended], date: fixture.now, calendar: fixture.calendar).count, 1)
    }

    func testPastDayOverviewDoesNotHideItsEvents() {
        let fixture = CalendarFixture()
        let yesterday = fixture.now.addingTimeInterval(-86400)
        let event = fixture.event("Yesterday", start: -86400, end: -85800)
        XCTAssertEqual(CalendarManager.overviewEvents([event], date: yesterday, now: fixture.now, calendar: fixture.calendar).count, 1)
    }

    func testDayFilterIncludesSpanningEventsAndExcludesMidnightBoundary() throws {
        let fixture = CalendarFixture()
        let interval = try XCTUnwrap(CalendarManager.eventInterval(for: fixture.now, calendar: fixture.calendar))
        let spanning = fixture.event("Spanning", start: -600, end: 600)
        spanning.startDate = interval.start.addingTimeInterval(-60)
        spanning.endDate = interval.end.addingTimeInterval(60)
        let previous = fixture.event("Previous", start: -600, end: 0)
        previous.startDate = interval.start.addingTimeInterval(-600)
        previous.endDate = interval.start
        let next = fixture.event("Next", start: 0, end: 600)
        next.startDate = interval.end
        next.endDate = interval.end.addingTimeInterval(600)
        XCTAssertEqual(CalendarManager.eventsForDay([previous, next, spanning], date: fixture.now, calendar: fixture.calendar).map(\.title), ["Spanning"])
    }

    func testZeroDurationEventsAreVisibleAtTheirStartButNotAfter() {
        let fixture = CalendarFixture()
        let event = fixture.event("Instant", start: 0, end: 0)
        XCTAssertEqual(CalendarManager.overviewEvents([event], date: fixture.now, now: fixture.now, calendar: fixture.calendar).count, 1)
        XCTAssertTrue(CalendarManager.overviewEvents([event], date: fixture.now, now: fixture.now.addingTimeInterval(1), calendar: fixture.calendar).isEmpty)
    }

    func testEnsureAccessDoesNotRequestPermissionAndSkipsUnauthorizedReads() {
        let fixture = CalendarFixture()
        fixture.status = .notDetermined
        let manager = fixture.makeManager()
        manager.ensureAccess()
        manager.ensureAccess()
        XCTAssertFalse(manager.hasAccess)
        XCTAssertEqual(fixture.accessRequests, 0)
        XCTAssertEqual(fixture.calendarReads, 0)
        XCTAssertTrue(fixture.requestedIntervals.isEmpty)
    }

    func testExplicitAccessRequestRefreshesGrantedEvents() async {
        let fixture = CalendarFixture()
        fixture.status = .notDetermined
        fixture.events = [fixture.event("Next", start: 600, end: 1200)]
        let manager = fixture.makeManager()
        await manager.requestAccess()
        XCTAssertTrue(manager.hasAccess)
        XCTAssertEqual(fixture.accessRequests, 1)
        XCTAssertEqual(manager.upcomingEvents.count, 1)
        XCTAssertFalse(manager.isRequestingAccess)
    }

    func testDeniedPermissionDoesNotTriggerRepeatedRequests() async {
        let fixture = CalendarFixture()
        fixture.status = .denied
        let manager = fixture.makeManager()
        await manager.requestAccess()
        manager.ensureAccess()
        XCTAssertEqual(fixture.accessRequests, 0)
        XCTAssertEqual(manager.authorizationStatus, .denied)
        XCTAssertTrue(manager.upcomingEvents.isEmpty)
    }

    func testRevokingPermissionClearsPreviouslyVisibleEvents() {
        let fixture = CalendarFixture()
        fixture.events = [fixture.event("Private", start: 0, end: 600)]
        let manager = fixture.makeManager()
        manager.refresh()
        XCTAssertEqual(manager.upcomingEvents.count, 1)
        fixture.status = .denied
        manager.refresh()
        XCTAssertFalse(manager.hasAccess)
        XCTAssertTrue(manager.calendars.isEmpty)
        XCTAssertTrue(manager.selectedCalendars.isEmpty)
        XCTAssertTrue(manager.upcomingEvents.isEmpty)
        XCTAssertEqual(fixture.calendarReads, 1)
    }

    func testWriteOnlyPermissionCannotReadEvents() {
        let fixture = CalendarFixture()
        fixture.status = .writeOnly
        let manager = fixture.makeManager()
        manager.refresh()
        XCTAssertFalse(manager.hasAccess)
        XCTAssertEqual(fixture.calendarReads, 0)
    }

    func testStoreChangeRefreshesDisplayedDate() async {
        let fixture = CalendarFixture()
        let manager = fixture.makeManager(observeChanges: true)
        manager.refresh()
        let date = fixture.now.addingTimeInterval(86400)
        manager.loadEvents(for: date)
        let refreshed = expectation(description: "Store change refreshed selected date")
        fixture.onFetch = { refreshed.fulfill() }
        fixture.events = [fixture.event("Tomorrow", start: 86400, end: 87000)]
        fixture.notifications.post(name: .EKEventStoreChanged, object: nil)
        await fulfillment(of: [refreshed], timeout: 1)
        XCTAssertEqual(manager.displayedDate, date)
        XCTAssertEqual(manager.upcomingEvents.map(\.title), ["Tomorrow"])
    }

    func testForegroundNotificationRefreshesAuthorization() async {
        let fixture = CalendarFixture()
        let manager = fixture.makeManager(observeChanges: true)
        manager.refresh()
        let checked = expectation(description: "Foreground checked authorization")
        fixture.status = .denied
        fixture.onReadAuthorization = { checked.fulfill() }
        fixture.notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await fulfillment(of: [checked], timeout: 1)
        XCTAssertFalse(manager.hasAccess)
    }

    func testDayChangeFollowsToday() async {
        let fixture = CalendarFixture()
        let manager = fixture.makeManager(observeChanges: true)
        manager.refresh()
        fixture.now = fixture.now.addingTimeInterval(86400)
        let refreshed = expectation(description: "Day change refreshed")
        fixture.onFetch = { refreshed.fulfill() }
        fixture.notifications.post(name: .NSCalendarDayChanged, object: nil)
        await fulfillment(of: [refreshed], timeout: 1)
        XCTAssertTrue(fixture.calendar.isDate(manager.displayedDate, inSameDayAs: fixture.now))
        XCTAssertEqual(manager.currentDate, fixture.now)
    }

    func testDayChangePreservesExplicitlySelectedDate() {
        let fixture = CalendarFixture()
        let manager = fixture.makeManager()
        manager.refresh()
        let selected = fixture.now.addingTimeInterval(-86400)
        manager.loadEvents(for: selected)
        fixture.now = fixture.now.addingTimeInterval(86400)
        manager.refresh()
        XCTAssertEqual(manager.displayedDate, selected)
    }

    func testEmptyCalendarPreferenceSkipsFetchingEvents() {
        let fixture = CalendarFixture()
        fixture.defaults.set([String](), forKey: CalendarManager.selectedCalendarIdentifiersKey)
        let manager = fixture.makeManager()
        manager.refresh()
        XCTAssertTrue(manager.selectedCalendars.isEmpty)
        XCTAssertTrue(fixture.requestedIntervals.isEmpty)
    }

    func testObserversDoNotRetainManagerOrReadAfterRelease() async {
        let fixture = CalendarFixture()
        var manager: CalendarManager? = fixture.makeManager(observeChanges: true)
        weak var releasedManager = manager
        manager?.refresh()
        let previousReads = fixture.calendarReads
        manager = nil
        XCTAssertNil(releasedManager)
        fixture.notifications.post(name: .EKEventStoreChanged, object: nil)
        await Task.yield()
        XCTAssertEqual(fixture.calendarReads, previousReads)
    }

}


/// 只创建未保存的 EventKit 模型；所有权限和读取路径都由内存闭包提供。
@MainActor
private final class CalendarFixture {
    let store = EKEventStore()
    let notifications = NotificationCenter()
    let defaults: UserDefaults
    let defaultsName = "XNook.CalendarTests.\(UUID().uuidString)"
    let calendar: Calendar
    var now: Date
    lazy var eventCalendar = EKCalendar(for: .event, eventStore: store)
    var status: EKAuthorizationStatus = .fullAccess
    var events: [EKEvent] = []
    var calendarReads = 0
    var accessRequests = 0
    var requestedIntervals: [DateInterval] = []
    var onFetch: (() -> Void)?
    var onReadAuthorization: (() -> Void)?

    init() {
        defaults = UserDefaults(suiteName: defaultsName)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        self.calendar = calendar
        now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 16, hour: 12))!
    }

    deinit { defaults.removePersistentDomain(forName: defaultsName) }

    func event(_ title: String, start: TimeInterval, end: TimeInterval) -> EKEvent {
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = now.addingTimeInterval(start)
        event.endDate = now.addingTimeInterval(end)
        event.calendar = eventCalendar
        return event
    }

    func makeManager(observeChanges: Bool = false) -> CalendarManager {
        CalendarManager(
            eventStore: store,
            defaults: defaults,
            notificationCenter: notifications,
            now: { self.now },
            calendar: calendar,
            observeChanges: observeChanges,
            readAuthorization: {
                self.onReadAuthorization?()
                return self.status
            },
            fetchCalendars: {
                self.calendarReads += 1
                return [self.eventCalendar]
            },
            fetchEvents: { interval, _ in
                self.requestedIntervals.append(interval)
                self.onFetch?()
                return self.events
            },
            requestFullAccess: {
                self.accessRequests += 1
                self.status = .fullAccess
                return true
            },
            didRefreshAuthorization: {}
        )
    }
}
