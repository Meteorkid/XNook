import AppKit
import XCTest
@testable import XNook

@MainActor
final class NotchWindowVisibilityTests: XCTestCase {
    func testCloseDiscardsPendingFullscreenRestore() async throws {
        let started = expectation(description: "等待全屏回读")
        let probe = FullscreenProbe(started: [started])
        let fixture = try makeFixture(probe: { await probe.result() })
        defer { fixture.close() }
        fixture.window.showWindow()
        let check = try XCTUnwrap(fixture.window.refreshFullscreenVisibility())
        await fulfillment(of: [started], timeout: 1)
        fixture.window.close()
        await probe.complete(0, fullscreen: false)
        await check.value
        XCTAssertFalse(fixture.window.isVisible)
        XCTAssertFalse(fixture.window.activityState.isActive)
        XCTAssertNil(fixture.window.refreshFullscreenVisibility())
    }

    func testWorkspaceSleepAndWakePreserveIslandHiddenIntent() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        // fixture 为其他测试隔离了 Workspace 通知；本例单独注册本窗口的公开通知选择器。
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(fixture.window, selector: NSSelectorFromString("systemWillSleep:"),
            name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(fixture.window, selector: NSSelectorFromString("systemDidWake:"),
            name: NSWorkspace.didWakeNotification, object: nil)
        defer { center.removeObserver(fixture.window) }
        fixture.window.showWindow()
        XCTAssertTrue(fixture.window.activityState.isActive)
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertFalse(fixture.window.activityState.isActive)
        fixture.window.hideWindowForIslandSwitch(animated: false)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertFalse(fixture.window.isVisible)
        XCTAssertFalse(fixture.window.activityState.isActive)
        XCTAssertTrue(fixture.window.isHiddenByIslandSwitch)
    }

    func testExplicitShowsCancelPendingSwitchAndRecordShowTime() throws {
        var pendingSwitch = true
        var cancellationCount = 0
        let fixture = try makeFixture(onExplicitShow: {
            pendingSwitch = false
            cancellationCount += 1
        })
        defer { fixture.close() }
        let beforeShow = Date().timeIntervalSince1970

        fixture.window.showWindow()

        XCTAssertFalse(pendingSwitch)
        XCTAssertEqual(cancellationCount, 1)
        XCTAssertGreaterThanOrEqual(fixture.window.lastExplicitShowTime, beforeShow)
        let firstShow = fixture.window.lastExplicitShowTime
        pendingSwitch = true

        fixture.window.showAtMouseScreen()

        XCTAssertFalse(pendingSwitch)
        XCTAssertEqual(cancellationCount, 2)
        XCTAssertGreaterThanOrEqual(fixture.window.lastExplicitShowTime, firstShow)
    }

    func testExplicitMouseScreenShowClearsBothHiddenIntents() throws {
        var visibleMarks = 0
        let fixture = try makeFixture(markVisible: { visibleMarks += 1 })
        defer { fixture.close() }
        fixture.window.hideWindow()
        fixture.window.hideWindowForIslandSwitch()

        fixture.window.showAtMouseScreen()

        XCTAssertFalse(fixture.window.isHiddenByUser)
        XCTAssertFalse(fixture.window.isHiddenByIslandSwitch)
        XCTAssertTrue(fixture.window.isVisible)
        XCTAssertEqual(visibleMarks, 1)
    }

    func testExplicitShowsDiscardEarlierFullscreenResult() async throws {
        for showAtMouse in [false, true] {
            let started = expectation(description: "全屏检查开始")
            let probe = FullscreenProbe(started: [started])
            let fixture = try makeFixture(probe: { await probe.result() })
            defer { fixture.close() }
            fixture.window.showWindow()
            let check = try XCTUnwrap(fixture.window.refreshFullscreenVisibility())
            await fulfillment(of: [started], timeout: 1)

            if showAtMouse {
                fixture.window.showAtMouseScreen()
            } else {
                fixture.window.showWindow()
            }
            await probe.complete(0, fullscreen: true)
            await check.value

            XCTAssertTrue(fixture.window.isVisible, "显式显示应淘汰之前的全屏结果")
        }
    }

    func testCompletedSwitchProtectionDiscardsEarlierFullscreenResult() async throws {
        let started = expectation(description: "全屏检查开始")
        let probe = FullscreenProbe(started: [started])
        let fixture = try makeFixture(probe: { await probe.result() })
        defer { fixture.close() }
        fixture.window.showWindow()
        let check = try XCTUnwrap(fixture.window.refreshFullscreenVisibility())
        await fulfillment(of: [started], timeout: 1)

        fixture.window.isSwitchingApps = true
        fixture.window.isSwitchingApps = false
        await probe.complete(0, fullscreen: true)
        await check.value

        XCTAssertTrue(fixture.window.isVisible)
    }

    func testIslandHiddenFlagChangesDiscardEarlierFullscreenResult() async throws {
        let started = expectation(description: "全屏检查开始")
        let probe = FullscreenProbe(started: [started])
        let fixture = try makeFixture(probe: { await probe.result() })
        defer { fixture.close() }
        fixture.window.showWindow()
        let check = try XCTUnwrap(fixture.window.refreshFullscreenVisibility())
        await fulfillment(of: [started], timeout: 1)

        fixture.window.isHiddenByIslandSwitch = true
        fixture.window.isHiddenByIslandSwitch = false
        await probe.complete(0, fullscreen: true)
        await check.value

        XCTAssertTrue(fixture.window.isVisible)
    }

    func testNewerFullscreenCheckDiscardsOlderResult() async throws {
        let firstStarted = expectation(description: "第一次检查开始")
        let secondStarted = expectation(description: "第二次检查开始")
        let probe = FullscreenProbe(started: [firstStarted, secondStarted])
        let fixture = try makeFixture(probe: { await probe.result() })
        defer { fixture.close() }
        fixture.window.showWindow()
        let first = try XCTUnwrap(fixture.window.refreshFullscreenVisibility())
        await fulfillment(of: [firstStarted], timeout: 1)
        let second = try XCTUnwrap(fixture.window.refreshFullscreenVisibility())
        await fulfillment(of: [secondStarted], timeout: 1)

        await probe.complete(1, fullscreen: false)
        await second.value
        await probe.complete(0, fullscreen: true)
        await first.value

        XCTAssertTrue(fixture.window.isVisible)
    }

    func testDisablingFullscreenHidingDiscardsPendingResult() async throws {
        let started = expectation(description: "全屏检查开始")
        let probe = FullscreenProbe(started: [started])
        let fixture = try makeFixture(probe: { await probe.result() })
        defer { fixture.close() }
        fixture.window.showWindow()
        let check = try XCTUnwrap(fixture.window.refreshFullscreenVisibility())
        await fulfillment(of: [started], timeout: 1)

        fixture.defaults.set(false, forKey: "hideInFullscreen")
        await probe.complete(0, fullscreen: true)
        await check.value

        XCTAssertTrue(fixture.window.isVisible)
    }

    func testExplicitHidesKeepWindowHiddenAfterPendingRestore() async throws {
        for hideForSwitch in [false, true] {
            let started = expectation(description: "全屏检查开始")
            let probe = FullscreenProbe(started: [started])
            let fixture = try makeFixture(probe: { await probe.result() })
            defer { fixture.close() }
            fixture.window.showWindow()
            let check = try XCTUnwrap(fixture.window.refreshFullscreenVisibility())
            await fulfillment(of: [started], timeout: 1)

            if hideForSwitch {
                fixture.window.hideWindowForIslandSwitch(animated: false)
                fixture.window.isSwitchingApps = false
            } else {
                fixture.window.hideWindow()
            }
            await probe.complete(0, fullscreen: false)
            await check.value

            XCTAssertFalse(fixture.window.isVisible)
        }
    }

    func testCurrentFullscreenResultsStillHideAndRestore() async throws {
        let firstStarted = expectation(description: "进入全屏检查开始")
        let secondStarted = expectation(description: "退出全屏检查开始")
        let probe = FullscreenProbe(started: [firstStarted, secondStarted])
        let fixture = try makeFixture(probe: { await probe.result() })
        defer { fixture.close() }
        fixture.window.showWindow()
        let first = try XCTUnwrap(fixture.window.refreshFullscreenVisibility())
        await fulfillment(of: [firstStarted], timeout: 1)
        await probe.complete(0, fullscreen: true)
        await first.value
        XCTAssertFalse(fixture.window.isVisible)

        let second = try XCTUnwrap(fixture.window.refreshFullscreenVisibility())
        await fulfillment(of: [secondStarted], timeout: 1)
        await probe.complete(1, fullscreen: false)
        await second.value
        XCTAssertTrue(fixture.window.isVisible)
    }

    private func makeFixture(
        markVisible: @escaping @MainActor () -> Void = {},
        onExplicitShow: @escaping @MainActor () -> Void = {},
        probe: (@Sendable () async -> Bool)? = nil
    ) throws -> Fixture {
        guard ProcessInfo.processInfo.environment["XNOOK_RENDER_UI"] == "1" else {
            throw XCTSkip("隔离窗口验证需要 XNOOK_RENDER_UI=1 和 WindowServer")
        }
        _ = NSApplication.shared
        guard !NSScreen.screens.isEmpty else {
            throw XCTSkip("当前环境没有可用屏幕")
        }
        let suite = "XNookTests.NotchWindowVisibility.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: "hideInFullscreen")
        defaults.set(true, forKey: "showOnAllSpaces")
        let window = NotchWindow(defaults: defaults, markVisible: markVisible,
                                 onExplicitShow: onExplicitShow, fullscreenProbe: probe)
        // 只控制本测试创建的窗口，不修改联动 suite，也不联系真实 App。
        NSWorkspace.shared.notificationCenter.removeObserver(window)
        return Fixture(window: window, defaults: defaults, suite: suite)
    }

    @MainActor
    private struct Fixture {
        let window: NotchWindow
        let defaults: UserDefaults
        let suite: String

        func close() {
            window.close()
            defaults.removePersistentDomain(forName: suite)
        }
    }
}

private actor FullscreenProbe {
    private let started: [XCTestExpectation]
    private var continuations: [CheckedContinuation<Bool, Never>] = []

    init(started: [XCTestExpectation]) {
        self.started = started
    }

    func result() async -> Bool {
        await withCheckedContinuation { continuation in
            let index = continuations.count
            continuations.append(continuation)
            started[index].fulfill()
        }
    }

    func complete(_ index: Int, fullscreen: Bool) {
        continuations[index].resume(returning: fullscreen)
    }
}
