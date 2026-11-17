import Foundation
import XCTest
@testable import XNook

@MainActor
final class PanelActivityCoordinatorTests: XCTestCase {
    func testStartsBlockedUntilPresentationIsConfigured() {
        let fixture = ActivityFixture()
        let coordinator = PanelActivityCoordinator(now: { fixture.time }, schedule: fixture.schedule)
        let event = fixture.event("first")
        XCTAssertTrue(coordinator.enqueue(event))
        XCTAssertNil(coordinator.current)
        XCTAssertEqual(coordinator.pendingCount, 1)
        coordinator.configurePresentation { true }
        XCTAssertEqual(coordinator.current, event)
        XCTAssertEqual(coordinator.pendingCount, 0)
        coordinator.shutdown()
    }

    func testOneHundredDuplicatesAreAcceptedAndPresentedOnlyOnce() {
        let fixture = ActivityFixture()
        let event = fixture.event("duplicate")
        let accepted = (0..<100).filter { _ in fixture.coordinator.enqueue(event) }
        XCTAssertEqual(accepted.count, 1)
        XCTAssertEqual(fixture.presented, [event])
        XCTAssertEqual(fixture.coordinator.pendingCount, 0)
        XCTAssertEqual(fixture.activeTimers.count, 1)
        fixture.advance(by: 5)
        XCTAssertNil(fixture.coordinator.current)
        XCTAssertFalse(fixture.coordinator.enqueue(event), "展示结束也不能在原 TTL 内重复消费")
        XCTAssertTrue(fixture.activeTimers.isEmpty)
    }

    func testSourceAndIDTogetherIdentifyAnEvent() {
        let fixture = ActivityFixture()
        let first = fixture.event("same", source: "calendar")
        let second = fixture.event("same", source: "focus")
        XCTAssertTrue(fixture.coordinator.enqueue(first))
        XCTAssertTrue(fixture.coordinator.enqueue(second))
        fixture.advance(by: 5)
        XCTAssertEqual(fixture.coordinator.current, second)
        fixture.coordinator.dismissCurrent(first)
        fixture.coordinator.performCurrentAction(first)
        XCTAssertEqual(fixture.coordinator.current, second, "旧视图不能操作另一来源的同 ID 提示")
    }

    func testTwentyEventBurstKeepsCurrentAndFiveNewestEqualPriorityEvents() {
        let fixture = ActivityFixture()
        for index in 0..<20 {
            XCTAssertTrue(fixture.coordinator.enqueue(fixture.event("event-\(index)")))
            XCTAssertLessThanOrEqual(fixture.coordinator.pendingCount, 5)
            XCTAssertEqual(fixture.activeTimers.count, 1)
        }
        XCTAssertEqual(fixture.coordinator.current?.id, "event-0")
        fixture.advance(by: 30)
        XCTAssertEqual(fixture.presented.map(\.id), ["event-0", "event-15", "event-16", "event-17", "event-18", "event-19"])
        XCTAssertNil(fixture.coordinator.current)
        XCTAssertTrue(fixture.activeTimers.isEmpty)
    }

    func testPriorityThenFIFOWithoutInterruptingCurrent() {
        let fixture = ActivityFixture()
        let events = [
            fixture.event("current", kind: .information),
            fixture.event("information", kind: .information),
            fixture.event("completion", kind: .completion),
            fixture.event("failure-first", kind: .failure),
            fixture.event("deadline", kind: .deadline),
            fixture.event("failure-second", kind: .failure)
        ]
        events.forEach { fixture.coordinator.enqueue($0) }
        fixture.advance(by: 4.99)
        XCTAssertEqual(fixture.coordinator.current, events[0])
        fixture.advance(by: 25.01)
        XCTAssertEqual(fixture.presented.map(\.id), ["current", "failure-first", "failure-second", "deadline", "completion", "information"])
    }

    func testOverflowDropsOldestOfLowestPriorityEvenWhenHigherPriorityIsOlder() {
        let fixture = ActivityFixture()
        fixture.isAllowed = false
        let events = [
            fixture.event("failure-old", kind: .failure),
            fixture.event("information-old", kind: .information),
            fixture.event("completion", kind: .completion),
            fixture.event("information-new", kind: .information),
            fixture.event("deadline", kind: .deadline),
            fixture.event("failure-new", kind: .failure)
        ]
        events.forEach { fixture.coordinator.enqueue($0) }
        XCTAssertEqual(fixture.coordinator.pendingCount, 5)
        XCTAssertFalse(fixture.coordinator.enqueue(events[1]), "被容量淘汰的项仍已消费")
        fixture.isAllowed = true
        fixture.coordinator.refreshPresentation()
        fixture.advance(by: 25)
        XCTAssertEqual(fixture.presented.map(\.id), ["failure-old", "failure-new", "deadline", "completion", "information-new"])
    }

    func testBlockedEventsExpireAndCannotBeRevived() {
        let fixture = ActivityFixture()
        fixture.isAllowed = false
        let event = fixture.event("expired")
        fixture.coordinator.enqueue(event)
        XCTAssertEqual(fixture.activeTimers.map(\.date), [event.expiresAt])
        fixture.advance(by: 60)
        XCTAssertNil(fixture.coordinator.current)
        XCTAssertEqual(fixture.coordinator.pendingCount, 0)
        XCTAssertTrue(fixture.activeTimers.isEmpty)
        fixture.isAllowed = true
        fixture.coordinator.refreshPresentation()
        XCTAssertTrue(fixture.presented.isEmpty)
        XCTAssertFalse(fixture.coordinator.enqueue(event))
        XCTAssertTrue(fixture.coordinator.enqueue(fixture.event("expired")), "原 TTL 结束后可接受新的同 ID 事件")
    }

    func testEnqueueCleansExpiredIdentityEvenBeforeItsTimerRuns() {
        let fixture = ActivityFixture()
        fixture.coordinator.enqueue(fixture.event("reused"))
        fixture.time = fixture.time.addingTimeInterval(60)
        let replacement = fixture.event("reused")
        XCTAssertTrue(fixture.coordinator.enqueue(replacement))
        XCTAssertEqual(fixture.coordinator.current, replacement)
        XCTAssertEqual(fixture.presented.count, 2)
    }

    func testBlockingPreservesOriginalTTLAndRemainingReadingTimeWithoutSecondPresentation() {
        let fixture = ActivityFixture()
        let event = fixture.event("resume")
        fixture.coordinator.enqueue(event)
        fixture.advance(by: 2)
        fixture.isAllowed = false
        fixture.coordinator.refreshPresentation()
        XCTAssertNil(fixture.coordinator.current)
        XCTAssertEqual(fixture.coordinator.pendingCount, 1)
        XCTAssertEqual(fixture.activeTimers.map(\.date), [event.expiresAt])
        fixture.advance(by: 10)
        fixture.isAllowed = true
        fixture.coordinator.refreshPresentation()
        XCTAssertEqual(fixture.coordinator.current, event)
        XCTAssertEqual(fixture.presented, [event])
        fixture.advance(by: 2.99)
        XCTAssertEqual(fixture.coordinator.current, event)
        fixture.advance(by: 0.01)
        XCTAssertNil(fixture.coordinator.current)
        XCTAssertEqual(fixture.presented, [event])
        XCTAssertTrue(fixture.activeTimers.isEmpty)
    }

    func testTimerReadsCurrentPermissionAndDoesNotUseAnOldAllowedValue() {
        let fixture = ActivityFixture()
        fixture.coordinator.enqueue(fixture.event("current"))
        fixture.coordinator.enqueue(fixture.event("waiting"))
        fixture.isAllowed = false
        fixture.advance(by: 5)
        XCTAssertNil(fixture.coordinator.current)
        XCTAssertEqual(fixture.coordinator.pendingCount, 1)
        XCTAssertEqual(fixture.presented.map(\.id), ["current"])
        fixture.isAllowed = true
        fixture.coordinator.refreshPresentation()
        XCTAssertEqual(fixture.coordinator.current?.id, "waiting")
    }

    func testExpiryCanEndPresentationBeforeFiveSeconds() {
        let fixture = ActivityFixture()
        let event = fixture.event("short", lifetime: 2)
        fixture.coordinator.enqueue(event)
        XCTAssertEqual(fixture.activeTimers.map(\.date), [event.expiresAt])
        fixture.advance(by: 2)
        XCTAssertNil(fixture.coordinator.current)
        XCTAssertTrue(fixture.activeTimers.isEmpty)
    }

    func testOldCancelledCallbackCannotReplaceCurrentTimerOrAdvanceTheQueue() {
        let fixture = ActivityFixture()
        fixture.coordinator.enqueue(fixture.event("first"))
        let oldTimer = fixture.activeTimers[0]
        fixture.coordinator.enqueue(fixture.event("short-lived", lifetime: 2))
        fixture.coordinator.enqueue(fixture.event("second"))
        let liveTimer = fixture.activeTimers[0]
        let count = fixture.entries.count
        XCTAssertTrue(oldTimer.isCancelled)
        oldTimer.fire()
        XCTAssertEqual(fixture.entries.count, count)
        XCTAssertTrue(fixture.activeTimers[0] === liveTimer)
        XCTAssertEqual(fixture.coordinator.current?.id, "first")
        fixture.advance(by: 5)
        XCTAssertEqual(fixture.coordinator.current?.id, "second")
        oldTimer.fire()
        XCTAssertEqual(fixture.coordinator.current?.id, "second")
    }

    func testOneHundredRefreshesReuseTheTimerUntilItsDeadline() {
        let fixture = ActivityFixture()
        fixture.coordinator.enqueue(fixture.event("first"))
        fixture.coordinator.enqueue(fixture.event("second"))
        let timer = fixture.activeTimers[0]
        for _ in 0..<100 {
            fixture.advance(by: 0.02)
            fixture.coordinator.refreshPresentation()
        }
        XCTAssertEqual(fixture.entries.count, 1)
        XCTAssertTrue(fixture.activeTimers[0] === timer)
        XCTAssertEqual(fixture.coordinator.current?.id, "first")

        fixture.advance(by: timer.date.timeIntervalSince(fixture.time))
        XCTAssertEqual(fixture.coordinator.current?.id, "second")
        XCTAssertEqual(fixture.entries.count, 2)
        XCTAssertEqual(fixture.activeTimers.count, 1)
        timer.fire()
        XCTAssertEqual(fixture.entries.count, 2, "已触发的旧回调不能清除后继定时器")
        fixture.advance(by: 5)
        XCTAssertNil(fixture.coordinator.current)
        XCTAssertTrue(fixture.activeTimers.isEmpty)
    }

    func testBlockedRefreshesReuseExpiryTimerAndExpiryLeavesNoTimer() {
        let fixture = ActivityFixture()
        fixture.isAllowed = false
        let event = fixture.event("waiting")
        fixture.coordinator.enqueue(event)
        for _ in 0..<100 { fixture.coordinator.refreshPresentation() }
        XCTAssertEqual(fixture.entries.count, 1)
        fixture.advance(by: 60)
        XCTAssertNil(fixture.coordinator.current)
        XCTAssertEqual(fixture.coordinator.pendingCount, 0)
        XCTAssertTrue(fixture.activeTimers.isEmpty)
        XCTAssertEqual(fixture.entries.count, 1)
    }

    func testDisableClearsEverythingAndShutdownCannotBeReenabled() {
        let fixture = ActivityFixture()
        let event = fixture.event("first")
        fixture.coordinator.enqueue(event)
        fixture.coordinator.enqueue(fixture.event("second"))
        let oldTimer = fixture.activeTimers[0]
        fixture.coordinator.setEnabled(false)
        XCTAssertFalse(fixture.coordinator.isEnabled)
        XCTAssertNil(fixture.coordinator.current)
        XCTAssertEqual(fixture.coordinator.pendingCount, 0)
        XCTAssertTrue(fixture.activeTimers.isEmpty)
        XCTAssertFalse(fixture.coordinator.enqueue(event))
        oldTimer.fire()
        XCTAssertNil(fixture.coordinator.current)
        fixture.coordinator.setEnabled(true)
        XCTAssertTrue(fixture.coordinator.enqueue(event))
        fixture.coordinator.shutdown()
        fixture.coordinator.setEnabled(true)
        fixture.coordinator.configurePresentation { true }
        XCTAssertFalse(fixture.coordinator.isEnabled)
        XCTAssertFalse(fixture.coordinator.enqueue(fixture.event("after-shutdown")))
        XCTAssertNil(fixture.coordinator.current)
        XCTAssertTrue(fixture.activeTimers.isEmpty)
    }

    func testActionRequiresMatchingCurrentEventAndRunsOnlyOnce() {
        let fixture = ActivityFixture()
        let event = fixture.event("calendar", action: .openCalendar)
        fixture.coordinator.enqueue(event)
        fixture.coordinator.performCurrentAction(fixture.event("other", action: .openCalendar))
        XCTAssertTrue(fixture.actions.isEmpty)
        fixture.coordinator.performCurrentAction(event)
        fixture.coordinator.performCurrentAction(event)
        XCTAssertEqual(fixture.actions, [.openCalendar])
        XCTAssertNil(fixture.coordinator.current)
        let information = fixture.event("information")
        fixture.coordinator.enqueue(information)
        fixture.coordinator.performCurrentAction(information)
        XCTAssertEqual(fixture.coordinator.current, information)
        XCTAssertEqual(fixture.actions.count, 1)
    }

    func testDeduplicationCacheIsBoundedAndProtectsStillQueuedEvents() {
        let fixture = ActivityFixture()
        fixture.coordinator.enqueue(fixture.event("active", kind: .failure))
        fixture.coordinator.enqueue(fixture.event("protected", kind: .failure))
        for index in 0..<257 {
            fixture.coordinator.enqueue(fixture.event("overflow-\(index)"))
        }
        XCTAssertFalse(fixture.coordinator.enqueue(fixture.event("active", kind: .failure)))
        XCTAssertFalse(fixture.coordinator.enqueue(fixture.event("protected", kind: .failure)))
        XCTAssertTrue(fixture.coordinator.enqueue(fixture.event("overflow-0")), "已淘汰且离开有界去重缓存的 ID 可重新受理")
        XCTAssertEqual(fixture.coordinator.pendingCount, 5)
        XCTAssertEqual(fixture.activeTimers.count, 1)
    }

    func testInvalidInternalEventsAreRejected() {
        let fixture = ActivityFixture()
        let invalid = [
            fixture.event(" "),
            fixture.event("id", source: "\n"),
            fixture.event("id", title: String(repeating: "字", count: 161)),
            fixture.event("id", lifetime: 61),
            fixture.event("id", lifetime: 0),
            PanelActivityEvent(source: "focus", id: "future", title: "未来", kind: .completion, createdAt: fixture.time.addingTimeInterval(6)),
            PanelActivityEvent(source: "focus", id: "invalid-date", title: "无效", kind: .completion, createdAt: Date(timeIntervalSince1970: .infinity))
        ]
        invalid.forEach { XCTAssertFalse(fixture.coordinator.enqueue($0)) }
        XCTAssertNil(fixture.coordinator.current)
        XCTAssertTrue(fixture.activeTimers.isEmpty)
    }

    func testPresentationCallbackCanDisableCoordinatorWithoutLeavingATimer() {
        let fixture = ActivityFixture()
        var coordinator: PanelActivityCoordinator?
        coordinator = PanelActivityCoordinator(
            now: { fixture.time }, schedule: fixture.schedule, isPresentationAllowed: { true },
            onPresent: { _ in coordinator?.setEnabled(false) }
        )
        XCTAssertEqual(coordinator?.enqueue(fixture.event("first")), true)
        XCTAssertEqual(coordinator?.isEnabled, false)
        XCTAssertNil(coordinator?.current)
        XCTAssertTrue(fixture.activeTimers.isEmpty)
        coordinator = nil
    }

    func testReleaseCancelsTheTimerAndOldCallbackDoesNotRetainCoordinator() {
        let fixture = ActivityFixture()
        var coordinator: PanelActivityCoordinator? = PanelActivityCoordinator(
            now: { fixture.time }, schedule: fixture.schedule, isPresentationAllowed: { true }
        )
        coordinator?.enqueue(fixture.event("first"))
        let entry = fixture.activeTimers[0]
        weak var weakCoordinator = coordinator
        coordinator = nil
        XCTAssertNil(weakCoordinator)
        XCTAssertTrue(entry.isCancelled)
        entry.fire()
    }
}

@MainActor
private final class ActivityFixture {
    var time = Date(timeIntervalSince1970: 1_700_000_000)
    var isAllowed = true
    var entries: [ActivityTimer] = []
    var presented: [PanelActivityEvent] = []
    var actions: [PanelActivityEvent.Action] = []
    var activeTimers: [ActivityTimer] { entries.filter { !$0.isCancelled } }

    lazy var coordinator = PanelActivityCoordinator(
        now: { [unowned self] in time },
        schedule: { [unowned self] date, callback in schedule(date, callback) },
        isPresentationAllowed: { [unowned self] in isAllowed },
        onPresent: { [unowned self] in presented.append($0) },
        onAction: { [unowned self] in actions.append($0) }
    )

    func schedule(_ date: Date, _ callback: @escaping @MainActor () -> Void) -> () -> Void {
        let entry = ActivityTimer(date: date, callback: callback)
        entries.append(entry)
        return { entry.isCancelled = true }
    }

    func event(
        _ id: String, source: String = "focus", title: String = "已完成任务",
        kind: PanelActivityEvent.Kind = .completion, lifetime: TimeInterval = 60,
        action: PanelActivityEvent.Action = .none
    ) -> PanelActivityEvent {
        PanelActivityEvent(
            source: source, id: id, title: title, kind: kind, createdAt: time,
            expiresAt: time.addingTimeInterval(lifetime), action: action
        )
    }

    func advance(by interval: TimeInterval) {
        let target = time.addingTimeInterval(interval)
        while let next = activeTimers.filter({ $0.date <= target }).min(by: { $0.date < $1.date }) {
            time = next.date
            next.isCancelled = true
            next.fire()
        }
        time = target
    }
}

private final class ActivityTimer {
    let date: Date
    let callback: @MainActor () -> Void
    var isCancelled = false

    init(date: Date, callback: @escaping @MainActor () -> Void) {
        self.date = date
        self.callback = callback
    }

    // 故意允许已取消回调投递，覆盖进入主队列后才被取消的竞态。
    @MainActor func fire() { callback() }
}
