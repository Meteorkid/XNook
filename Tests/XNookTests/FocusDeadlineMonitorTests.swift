import XCTest
@testable import XNook

@MainActor
final class FocusDeadlineMonitorTests: XCTestCase {
    func testNoTimerWithoutReadableActivePlan() {
        let f = Fixture()
        defer { f.cleanUp() }
        f.session = nil
        f.monitor.refresh()
        f.session = f.makeSession(deadline: nil)
        f.monitor.refresh()
        XCTAssertTrue(f.entries.isEmpty)
        XCTAssertTrue(f.events.isEmpty)
    }

    func testRepeatedRefreshReusesTimerAndDueDoesNotEndTask() throws {
        let f = Fixture()
        defer { f.cleanUp() }
        let original = f.session
        for _ in 0..<100 { f.monitor.refresh() }
        XCTAssertEqual(f.entries.count, 1)
        XCTAssertEqual(f.activeTimers.count, 1)
        f.time = try XCTUnwrap(f.session?.scheduledEndAt)
        f.entries[0].fire()
        for _ in 0..<100 { f.monitor.refresh() }
        XCTAssertEqual(f.events.count, 1)
        XCTAssertEqual(f.events.first?.source, "focus-deadline")
        XCTAssertEqual(f.events.first?.kind, .deadline)
        XCTAssertEqual(f.session, original)
        XCTAssertTrue(f.activeTimers.isEmpty)
        XCTAssertEqual(f.defaults.stringArray(forKey: FocusDeadlineMonitor.notifiedKey)?.count, 1)
    }

    func testReschedulingInvalidatesOldCallbackAndUsesCurrentTitle() throws {
        let f = Fixture()
        defer { f.cleanUp() }
        f.monitor.refresh()
        let old = try XCTUnwrap(f.activeTimers.first)
        f.session?.scheduledEndAt = f.time.addingTimeInterval(120)
        f.session?.title = "新名称"
        f.monitor.refresh()
        let current = try XCTUnwrap(f.activeTimers.first)
        XCTAssertTrue(old.cancelled)
        f.time = old.date
        old.fire()
        XCTAssertTrue(f.events.isEmpty)
        XCTAssertTrue(f.activeTimers.first === current)
        f.time = current.date
        current.fire()
        XCTAssertEqual(f.events.first?.title, L10n.flowBudgetDue("新名称"))
    }

    func testClearingPlanCancelsTimerAndCannotEmitFromOldCallback() throws {
        let f = Fixture()
        defer { f.cleanUp() }
        f.monitor.refresh()
        let old = try XCTUnwrap(f.activeTimers.first)
        f.session?.scheduledEndAt = nil
        f.monitor.refresh()
        f.time = old.date
        old.fire()
        XCTAssertTrue(old.cancelled)
        XCTAssertTrue(f.events.isEmpty)
        XCTAssertTrue(f.activeTimers.isEmpty)
    }

    func testCallbackRechecksEndAndUnreadableStorageWithoutViewRefresh() throws {
        let f = Fixture()
        defer { f.cleanUp() }
        f.monitor.refresh()
        let old = try XCTUnwrap(f.activeTimers.first)
        f.session?.state = .ended
        f.session?.endedAt = f.time
        f.time = old.date
        old.fire()
        XCTAssertTrue(f.events.isEmpty)
        f.session = f.makeSession(deadline: f.time.addingTimeInterval(60))
        f.monitor.refresh()
        let second = try XCTUnwrap(f.activeTimers.first)
        f.session = nil
        f.time = second.date
        second.fire()
        XCTAssertTrue(f.events.isEmpty)
        XCTAssertTrue(f.activeTimers.isEmpty)
    }

    func testStorageRecoveryRearmsUnconsumedPlan() throws {
        let f = Fixture()
        defer { f.cleanUp() }
        let saved = f.session
        f.monitor.refresh()
        f.session = nil
        f.monitor.refresh()
        XCTAssertTrue(f.activeTimers.isEmpty)
        f.time = try XCTUnwrap(saved?.scheduledEndAt)
        f.session = saved
        f.monitor.refresh()
        XCTAssertEqual(f.events.count, 1)
    }

    func testDisablingCancelsWithoutConsumingAndReenableDeliversDuePlan() throws {
        let f = Fixture()
        defer { f.cleanUp() }
        f.monitor.refresh()
        let old = try XCTUnwrap(f.activeTimers.first)
        f.enabled = false
        f.monitor.refresh()
        f.time = old.date
        old.fire()
        XCTAssertTrue(f.events.isEmpty)
        XCTAssertNil(f.defaults.object(forKey: FocusDeadlineMonitor.notifiedKey))
        f.enabled = true
        f.monitor.refresh()
        XCTAssertEqual(f.events.count, 1)
    }

    func testDeclinedEventDoesNotConsumeOrStartRetryLoop() {
        let f = Fixture()
        defer { f.cleanUp() }
        f.session?.scheduledEndAt = f.time
        f.accept = false
        f.monitor.refresh()
        XCTAssertEqual(f.events.count, 1)
        XCTAssertNil(f.defaults.object(forKey: FocusDeadlineMonitor.notifiedKey))
        XCTAssertTrue(f.entries.isEmpty)
        f.accept = true
        f.monitor.refresh()
        f.monitor.refresh()
        XCTAssertEqual(f.events.count, 2)
        XCTAssertEqual(f.defaults.stringArray(forKey: FocusDeadlineMonitor.notifiedKey)?.count, 1)
    }

    func testRestartDeduplicatesButNewPlanCanNotifyAgain() {
        let f = Fixture()
        defer { f.cleanUp() }
        f.session?.scheduledEndAt = f.time
        f.monitor.refresh()
        f.monitor.shutdown()
        let replacement = f.makeMonitor()
        defer { replacement.shutdown() }
        replacement.refresh()
        XCTAssertEqual(f.events.count, 1)
        f.session?.scheduledEndAt = f.time.addingTimeInterval(-1)
        replacement.refresh()
        XCTAssertEqual(f.events.count, 2)
    }

    func testClockForwardDeliversAndStaleCallbackCannotRedeliver() throws {
        let f = Fixture()
        defer { f.cleanUp() }
        f.monitor.refresh()
        let old = try XCTUnwrap(f.activeTimers.first)
        f.time = old.date.addingTimeInterval(3600)
        f.monitor.resynchronize()
        old.fire()
        XCTAssertTrue(old.cancelled)
        XCTAssertEqual(f.events.count, 1)
        XCTAssertTrue(f.activeTimers.isEmpty)
    }

    func testClockBackwardOrEarlyWakeRechecksAbsoluteDeadline() throws {
        let f = Fixture()
        defer { f.cleanUp() }
        f.monitor.refresh()
        let old = try XCTUnwrap(f.activeTimers.first)
        f.time = f.time.addingTimeInterval(-3600)
        f.monitor.resynchronize()
        old.fire()
        let current = try XCTUnwrap(f.activeTimers.first)
        XCTAssertEqual(current.date, old.date)
        XCTAssertTrue(f.events.isEmpty)
        // 模拟系统过早唤醒：不能依据旧相对延迟直接投递。
        current.fire()
        XCTAssertTrue(f.events.isEmpty)
        XCTAssertEqual(f.activeTimers.count, 1)
        f.time = old.date
        f.activeTimers[0].fire()
        XCTAssertEqual(f.events.count, 1)
    }

    func testFarFuturePlanUsesBoundedOneShotChecks() throws {
        let f = Fixture()
        defer { f.cleanUp() }
        f.session?.scheduledEndAt = f.time.addingTimeInterval(172_900)
        f.monitor.refresh()
        let first = try XCTUnwrap(f.activeTimers.first)
        XCTAssertEqual(first.date.timeIntervalSince(f.time), 86_400)
        f.time = first.date
        first.fire()
        XCTAssertEqual(f.activeTimers.count, 1)
        XCTAssertEqual(f.activeTimers[0].date.timeIntervalSince(f.time), 86_400)
        XCTAssertTrue(f.events.isEmpty)
    }

    func testInvalidDateDoesNotScheduleOrEmit() {
        let f = Fixture()
        defer { f.cleanUp() }
        for invalid in [Double.nan, .infinity, -.infinity] {
            f.session?.scheduledEndAt = Date(timeIntervalSince1970: invalid)
            f.monitor.refresh()
        }
        f.session = f.makeSession(deadline: Date(timeIntervalSince1970: 2000))
        f.time = Date(timeIntervalSince1970: .nan)
        f.monitor.refresh()
        XCTAssertTrue(f.entries.isEmpty)
        XCTAssertTrue(f.events.isEmpty)
    }

    func testPersistentDedupeIsBounded() {
        let f = Fixture()
        defer { f.cleanUp() }
        for index in 0..<300 {
            f.session = f.makeSession(deadline: f.time.addingTimeInterval(-Double(index)))
            f.monitor.refresh()
        }
        XCTAssertEqual(f.events.count, 300)
        XCTAssertEqual(f.defaults.stringArray(forKey: FocusDeadlineMonitor.notifiedKey)?.count, 256)
        f.monitor.shutdown()
        let replacement = f.makeMonitor()
        defer { replacement.shutdown() }
        replacement.refresh()
        XCTAssertEqual(f.events.count, 300)
    }

    func testSuspendIsReusableAndShutdownIsFinal() throws {
        let f = Fixture()
        defer { f.cleanUp() }
        f.monitor.refresh()
        let first = try XCTUnwrap(f.activeTimers.first)
        f.monitor.suspend()
        first.fire()
        XCTAssertTrue(f.activeTimers.isEmpty)
        f.monitor.refresh()
        let second = try XCTUnwrap(f.activeTimers.first)
        f.monitor.shutdown()
        f.monitor.shutdown()
        f.time = second.date
        second.fire()
        f.monitor.resynchronize()
        XCTAssertTrue(f.events.isEmpty)
        XCTAssertTrue(f.activeTimers.isEmpty)
        XCTAssertEqual(f.entries.count, 2)
    }

    func testDeinitCancelsOutstandingTimer() throws {
        let f = Fixture()
        defer { f.cleanUp() }
        var temporary: FocusDeadlineMonitor? = f.makeMonitor()
        temporary?.refresh()
        let timer = try XCTUnwrap(f.activeTimers.first)
        temporary = nil
        XCTAssertTrue(timer.cancelled)
        f.time = timer.date
        timer.fire()
        XCTAssertTrue(f.events.isEmpty)
    }

    private final class TimerEntry {
        let date: Date
        let action: @MainActor () -> Void
        var cancelled = false
        var fired = false
        init(date: Date, action: @escaping @MainActor () -> Void) { self.date = date; self.action = action }
        @MainActor func fire() { fired = true; action() }
    }

    @MainActor
    private final class Fixture {
        let suiteName = "XNook.FocusDeadline.\(UUID().uuidString)"
        let defaults: UserDefaults
        var time = Date(timeIntervalSince1970: 1_700_000_000)
        var session: FocusSession?
        var enabled = true
        var accept = true
        var entries: [TimerEntry] = []
        var events: [PanelActivityEvent] = []
        lazy var monitor = makeMonitor()
        var activeTimers: [TimerEntry] { entries.filter { !$0.cancelled && !$0.fired } }

        init() {
            defaults = UserDefaults(suiteName: suiteName)!
            session = makeSession(deadline: time.addingTimeInterval(60))
        }
        func makeSession(deadline: Date?) -> FocusSession {
            FocusSession(id: UUID(), title: "测试任务", startedAt: time, scheduledEndAt: deadline,
                         state: .active, linkedFiles: [])
        }
        func makeMonitor() -> FocusDeadlineMonitor {
            FocusDeadlineMonitor(defaults: defaults, currentSession: { [unowned self] in session },
                notificationsEnabled: { [unowned self] in enabled }, emit: { [unowned self] event in
                    events.append(event)
                    return accept
                }, now: { [unowned self] in time }, schedule: { [unowned self] date, action in
                    let entry = TimerEntry(date: date, action: action)
                    entries.append(entry)
                    return { entry.cancelled = true }
                })
        }
        func cleanUp() {
            monitor.shutdown()
            defaults.removePersistentDomain(forName: suiteName)
        }
    }
}
