import Foundation
import XCTest
@testable import XNook

@MainActor
final class PanelActivityStateTests: XCTestCase {
    func testWindowStartsInactiveAndSleepPreservesVisibilityIntent() {
        let state = PanelActivityState()
        XCTAssertFalse(state.isActive)
        state.setWindowVisible(true)
        XCTAssertTrue(state.isActive)
        state.setSystemAwake(false)
        XCTAssertFalse(state.isActive)
        XCTAssertTrue(state.isWindowVisible)
        state.setSystemAwake(true)
        XCTAssertTrue(state.isActive)
    }

    func testWakeCannotActivateAWindowHiddenBeforeOrDuringSleep() {
        for hideDuringSleep in [false, true] {
            let state = PanelActivityState()
            state.setWindowVisible(hideDuringSleep)
            state.setSystemAwake(false)
            state.setWindowVisible(false)
            state.setSystemAwake(true)
            XCTAssertFalse(state.isWindowVisible)
            XCTAssertFalse(state.isActive)
        }
    }

    func testTrackingStopsWhenHiddenAndRestoresOnlyOneTimer() {
        let fixture = TrackingFixture()
        fixture.controller.setActive(false)
        XCTAssertTrue(fixture.entries.isEmpty)
        fixture.controller.setActive(true)
        fixture.controller.setActive(true)
        XCTAssertEqual(fixture.entries.count, 1)
        fixture.entries[0].fire()
        XCTAssertEqual(fixture.ticks, 1)

        fixture.controller.setActive(false)
        fixture.entries[0].fire()
        XCTAssertEqual(fixture.ticks, 1)
        XCTAssertTrue(fixture.entries[0].isCancelled)

        fixture.controller.setActive(true)
        fixture.controller.setActive(true)
        fixture.entries[0].fire()
        XCTAssertEqual(fixture.ticks, 1, "隐藏前已经排队的旧回调在恢复后仍必须失效")
        fixture.entries[1].fire()
        XCTAssertEqual(fixture.ticks, 2)
        XCTAssertEqual(fixture.entries.filter { !$0.isCancelled }.count, 1)
        XCTAssertEqual(fixture.entries.map(\.interval), [0.5, 0.5])
    }

    func testTrackingControllerIsReleasedAndCancelsTimer() {
        var entry: TrackingEntry?
        var controller: PanelMouseTrackingController? = PanelMouseTrackingController(
            schedule: { interval, callback in
                let scheduled = TrackingEntry(interval: interval, callback: callback)
                entry = scheduled
                return { scheduled.isCancelled = true }
            }, onTick: { XCTFail("已销毁的控制器不能再轮询") }
        )
        controller?.setActive(true)
        weak var weakController = controller
        controller = nil
        XCTAssertNil(weakController)
        XCTAssertEqual(entry?.isCancelled, true)
        entry?.fire()
    }

    /// 每阶段虚拟 60 秒，计数是注入回调，不是系统唤醒次数。
    func testVirtualMinuteTrackingActivityPhases() throws {
        let fixture = TrackingFixture()
        let state = PanelActivityState()
        var phases: [[String: Any]] = []
        for phase in ["active", "expanded", "hidden", "restore"] {
            state.setWindowVisible(phase != "hidden")
            fixture.controller.setActive(state.isActive)
            fixture.controller.setActive(state.isActive)
            let before = fixture.ticks
            for _ in 0..<120 {
                for entry in fixture.entries where !entry.isCancelled { entry.fire() }
            }
            let callbacks = fixture.ticks - before
            XCTAssertEqual(callbacks, phase == "hidden" ? 0 : 120)
            phases.append(["phase": phase, "driverCallbacks": callbacks,
                           "activeTimers": fixture.entries.filter { !$0.isCancelled }.count])
        }
        guard let path = ProcessInfo.processInfo.environment["XNOOK_PERFORMANCE_OUTPUT"] else { return }
        let output = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let result: [String: Any] = [
            "scenario": "panel-mouse-tracking-virtual-60s", "virtualDurationSecondsPerPhase": 60,
            "timerIntervalSeconds": 0.5,
            "measurement": "injected timer callbacks; not kernel wakeups", "phases": phases
        ]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("panel-mouse-tracking-virtual-60s.json"), options: .atomic)
    }
}

@MainActor
private final class TrackingFixture {
    var ticks = 0
    var entries: [TrackingEntry] = []
    lazy var controller = PanelMouseTrackingController(
        schedule: { [unowned self] interval, callback in
            let entry = TrackingEntry(interval: interval, callback: callback)
            entries.append(entry)
            return { entry.isCancelled = true }
        }, onTick: { [unowned self] in ticks += 1 }
    )
}

private final class TrackingEntry {
    let interval: TimeInterval
    let callback: @MainActor () -> Void
    var isCancelled = false

    init(interval: TimeInterval, callback: @escaping @MainActor () -> Void) {
        self.interval = interval
        self.callback = callback
    }

    // 故意允许取消后的投递，以检查已经进入主队列的旧任务。
    @MainActor func fire() { callback() }
}
