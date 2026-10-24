import AppKit
import SwiftUI
import XCTest
@testable import XNook

@MainActor
final class NotchWindowHandoffTests: XCTestCase {
    func testPanelRevealSurvivesMissingHostAndIsConsumedOnlyOnce() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        fixture.window.requestPanelReveal()
        XCTAssertTrue(fixture.window.hasPendingPanelReveal)
        XCTAssertTrue(fixture.window.consumePanelReveal())
        XCTAssertFalse(fixture.window.consumePanelReveal())
        XCTAssertEqual(fixture.harness.orderFrontCount, 0, "展开请求只记意图，不绕过显示所有权")
    }

    func testHideAndInboundHandoffCancelStalePanelReveal() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        fixture.window.requestPanelReveal()
        fixture.window.hideWindow()
        XCTAssertFalse(fixture.window.consumePanelReveal())
        fixture.window.showWindow()
        fixture.window.requestPanelReveal()
        fixture.window.hideWindowForIslandSwitch(animated: false)
        XCTAssertFalse(fixture.window.consumePanelReveal())
        fixture.window.showWindow()
        fixture.window.requestPanelReveal()
        _ = fixture.window.beginInboundHandoff { _ in }
        XCTAssertFalse(fixture.window.hasPendingPanelReveal)
        fixture.window.tearDown()
        fixture.window.requestPanelReveal()
        XCTAssertFalse(fixture.window.hasPendingPanelReveal)
    }

    func testTornDownWindowCannotCompleteOrRestartHandoff() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        var prepared = 0
        let generation = fixture.window.beginInboundHandoff { _ in prepared += 1 }

        fixture.window.tearDown()
        fixture.window.tearDown()
        XCTAssertFalse(fixture.window.completeInboundHandoffPreparation(generation: generation))
        fixture.window.showWindow()
        fixture.window.showAtMouseScreen()
        _ = fixture.window.beginInboundHandoff { _ in prepared += 1 }

        XCTAssertEqual(prepared, 0)
        XCTAssertEqual(fixture.harness.orderFrontCount, 0)
        XCTAssertNil(fixture.window.handoffState.pendingPreparation)
        XCTAssertFalse(fixture.window.activityState.isActive)
    }

    func testExplicitShowsPublishAfterPresentationWithoutAVisibilityEdge() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        var presentations: [Int] = []
        let observer = NotificationCenter.default.addObserver(forName: .xnookWindowDidPresent,
            object: fixture.window, queue: .main) { _ in
                MainActor.assumeIsolated { presentations.append(fixture.harness.orderFrontCount) }
            }
        defer { NotificationCenter.default.removeObserver(observer) }

        fixture.window.showWindow()
        fixture.window.showWindow()
        fixture.window.showAtMouseScreen()

        XCTAssertEqual(presentations, [1, 2, 3], "即使没有可见性边沿，也必须在明确显示后通知视图恢复内容")
        XCTAssertFalse(fixture.window.isVisible, "注入的orderFront不应真正显示测试窗口")
    }

    func testScreenPositionIsPreparedBeforeHoverUnlockAndNotResampledAtShow() throws {
        _ = NSApplication.shared
        let suite = "XNookTests.HandoffPosition.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let harness = Harness(reduceMotion: false)
        var window: NotchWindow?
        var pendingDuringPositionRead: [Bool] = []
        let panel = NotchWindow(pointerLocation: {
            if let window { pendingDuringPositionRead.append(window.handoffState.pendingPreparation != nil) }
            let frame = NSScreen.main?.frame ?? .zero
            return NSPoint(x: frame.midX, y: frame.midY)
        }, defaults: defaults, markVisible: {}, onExplicitShow: {}, handoffEnvironment: harness.environment())
        window = panel
        defer { panel.close(); defaults.removePersistentDomain(forName: suite) }
        let generation = panel.beginInboundHandoff { [weak panel] generation in
            panel?.showPreparedHandoff(generation: generation)
        }

        XCTAssertTrue(panel.completeInboundHandoffPreparation(generation: generation))
        XCTAssertEqual(pendingDuringPositionRead, [true], "最终屏幕定位必须仍在准备门控内，显示时不能二次采样位置")
        XCTAssertEqual(harness.orderFrontCount, 1)
        XCTAssertFalse(panel.isVisible)
    }

    func testHiddenHostingViewRegistersAndConsumesPreparationOnAppear() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let window = fixture.window
        let contentView = try XCTUnwrap(window.contentView)
        var didAppear = false
        var requested: [UInt64] = []
        var completed: [UInt64] = []
        let hostingView = NSHostingView(rootView: Text("handoff").onAppear { [weak window] in
            didAppear = true
            window?.installHandoffPreparationHandler { [weak window] generation in
                requested.append(generation)
                XCTAssertEqual(window?.completeInboundHandoffPreparation(generation: generation), true)
            }
        })
        hostingView.frame = contentView.bounds
        hostingView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostingView)

        let generation = window.beginInboundHandoff { completed.append($0) }

        XCTAssertTrue(didAppear, "隐藏窗口的准备流程也必须建立 SwiftUI 树")
        XCTAssertEqual(requested, [generation])
        XCTAssertEqual(completed, [generation])
        XCTAssertNil(window.handoffState.pendingPreparation)
        XCTAssertFalse(window.completeInboundHandoffPreparation(generation: generation))
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(fixture.harness.orderFrontCount, 0)
        XCTAssertEqual(fixture.harness.orderOutCount, 0)
    }

    func testColdInboundWaitsForHandlerAndCompletesOnlyOnce() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        var requested: [UInt64] = []
        var completed: [UInt64] = []
        let generation = fixture.window.beginInboundHandoff { completed.append($0) }

        XCTAssertEqual(fixture.window.handoffState.pendingPreparation, generation)
        XCTAssertEqual(fixture.harness.orderFrontCount, 0)
        XCTAssertTrue(completed.isEmpty)

        fixture.window.installHandoffPreparationHandler { requested.append($0) }

        XCTAssertEqual(requested, [generation])
        XCTAssertEqual(fixture.window.handoffState.pendingPreparation, generation)
        XCTAssertTrue(fixture.window.completeInboundHandoffPreparation(generation: generation))
        XCTAssertFalse(fixture.window.completeInboundHandoffPreparation(generation: generation))
        XCTAssertEqual(completed, [generation])
        XCTAssertNil(fixture.window.handoffState.pendingPreparation)
        XCTAssertEqual(fixture.harness.orderFrontCount, 0, "准备回调本身不应提前显示窗口")
    }

    func testHandlerInstalledAfterRepeatedInboundReceivesOnlyLatestRequest() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        var requested: [UInt64] = []
        var completed: [UInt64] = []
        let first = fixture.window.beginInboundHandoff { completed.append($0) }
        let second = fixture.window.beginInboundHandoff { completed.append($0) }

        fixture.window.installHandoffPreparationHandler { requested.append($0) }

        XCTAssertEqual(requested, [second])
        XCTAssertFalse(fixture.window.isCurrentHandoff(first))
        XCTAssertTrue(fixture.window.isCurrentHandoff(second))
        XCTAssertFalse(fixture.window.completeInboundHandoffPreparation(generation: first))
        XCTAssertTrue(completed.isEmpty)
        XCTAssertTrue(fixture.window.completeInboundHandoffPreparation(generation: second))
        XCTAssertEqual(completed, [second])
    }

    func testRepeatedInboundRejectsAlreadyDeliveredPreparation() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        var requested: [UInt64] = []
        var completed: [UInt64] = []
        fixture.window.installHandoffPreparationHandler { requested.append($0) }
        let first = fixture.window.beginInboundHandoff { completed.append($0) }
        let second = fixture.window.beginInboundHandoff { completed.append($0) }

        XCTAssertEqual(requested, [first, second])
        XCTAssertFalse(fixture.window.completeInboundHandoffPreparation(generation: first))
        XCTAssertTrue(fixture.window.completeInboundHandoffPreparation(generation: second))
        XCTAssertEqual(completed, [second])
    }

    func testExplicitHideInvalidatesPendingPreparation() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        var completed = false
        let generation = fixture.window.beginInboundHandoff { _ in completed = true }

        fixture.window.hideWindow()

        XCTAssertFalse(fixture.window.completeInboundHandoffPreparation(generation: generation))
        XCTAssertFalse(completed)
        XCTAssertNil(fixture.window.handoffState.pendingPreparation)
        XCTAssertEqual(fixture.harness.orderOutCount, 1)
        XCTAssertTrue(fixture.window.observeHandoffPointer(isInside: true))
    }

    func testWindowHoverGateRequiresRealExitAndReentry() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let generation = fixture.window.beginInboundHandoff { _ in }
        XCTAssertTrue(fixture.window.observeHandoffPointer(isInside: false), "旧 frame 的 outside 不能提前解锁")
        XCTAssertTrue(fixture.window.completeInboundHandoffPreparation(generation: generation))

        for _ in 0..<1_000 {
            XCTAssertTrue(fixture.window.observeHandoffPointer(isInside: true))
        }

        XCTAssertFalse(fixture.window.observeHandoffPointer(isInside: false))
        XCTAssertFalse(fixture.window.observeHandoffPointer(isInside: true))
    }

    func testCancelledPreparationCannotRelightOutgoingOrUserHiddenContent() throws {
        for hideReason in ["fading", "switched", "user"] {
            let fixture = try makeFixture()
            defer { fixture.close() }
            let window = fixture.window
            let generation = window.beginInboundHandoff { _ in }

            switch hideReason {
            case "fading": window.hideWindowForIslandSwitch()
            case "switched": window.hideWindowForIslandSwitch(animated: false)
            default: window.hideWindow()
            }

            XCTAssertFalse(window.completeInboundHandoffPreparation(generation: generation))
            XCTAssertFalse(window.canRestoreHandoffContent(after: generation), hideReason)
            fixture.harness.runAllScheduled()
            XCTAssertFalse(window.canRestoreHandoffContent(after: generation), "淡出完成仍然在让位")

            window.showWindow()

            XCTAssertTrue(window.canRestoreHandoffContent(after: generation), "后续普通显示必须能恢复内容")
            XCTAssertEqual(fixture.harness.orderFrontCount, 1)
            XCTAssertFalse(window.isVisible, "显示动作使用注入环境，不操作真实应用")
        }
    }

    func testExplicitShowCanRestoreCancelledPreparationWithoutWaitingForSwitchingTimer() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let window = fixture.window
        let generation = window.beginInboundHandoff { _ in }

        window.showAtMouseScreen()
        window.isSwitchingApps = true

        XCTAssertFalse(window.completeInboundHandoffPreparation(generation: generation))
        XCTAssertTrue(window.canRestoreHandoffContent(after: generation), "恢复由显示意图决定，不能依赖保护计时器")
    }

    func testOrdinaryShowCanRestoreContentBeforeOutgoingFadeHidesWindow() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let window = fixture.window
        window.showWindow()
        let generation = window.beginInboundHandoff { _ in }
        window.hideWindowForIslandSwitch()
        fixture.harness.runNextScheduled()

        XCTAssertFalse(window.completeInboundHandoffPreparation(generation: generation))
        XCTAssertFalse(window.canRestoreHandoffContent(after: generation))
        XCTAssertEqual(fixture.harness.orderOutCount, 0)

        window.showWindow()

        XCTAssertTrue(window.canRestoreHandoffContent(after: generation), "持续可见的轮询也应恢复，不能只等隐藏再显示的边沿")
        fixture.harness.runAllScheduled()
        XCTAssertEqual(fixture.harness.orderOutCount, 0)
        XCTAssertTrue(window.canRestoreHandoffContent(after: generation))
    }

    func testCurrentOrNewPendingHandoffDoesNotRestoreContentBeforeItsFadeIn() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        let window = fixture.window
        let first = window.beginInboundHandoff { _ in }
        let latest = window.beginInboundHandoff { _ in }

        XCTAssertFalse(window.canRestoreHandoffContent(after: first), "旧尾回调不能覆盖新的准备请求")
        XCTAssertFalse(window.canRestoreHandoffContent(after: latest))
        XCTAssertTrue(window.completeInboundHandoffPreparation(generation: latest))
        XCTAssertFalse(window.canRestoreHandoffContent(after: latest), "当前代数的淡入由原完成回调负责")
    }

    func testRepeatedFadeContinuesOriginalTransitionAndOrdersOutOnce() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        fixture.window.showWindow()
        fixture.window.hideWindowForIslandSwitch()
        let generation = fixture.window.handoffState.generation
        let scheduledCount = fixture.harness.scheduled.count
        XCTAssertGreaterThan(scheduledCount, 0)
        XCTAssertEqual(fixture.harness.scheduled.map(\.delay).max() ?? 0, 0.12, accuracy: 0.000_001)
        XCTAssertEqual(fixture.harness.orderOutCount, 0)

        fixture.harness.runNextScheduled()
        let alphaAfterFirstStep = fixture.window.alphaValue
        XCTAssertGreaterThan(alphaAfterFirstStep, 0)
        XCTAssertLessThan(alphaAfterFirstStep, 1)
        fixture.window.hideWindowForIslandSwitch()

        XCTAssertEqual(fixture.window.handoffState.generation, generation)
        XCTAssertEqual(fixture.harness.scheduled.count, scheduledCount - 1)
        XCTAssertEqual(fixture.window.alphaValue, alphaAfterFirstStep)
        fixture.harness.runAllScheduled()
        XCTAssertEqual(fixture.harness.orderOutCount, 1)
        XCTAssertFalse(fixture.window.handoffState.isFadingOut)
        XCTAssertEqual(fixture.window.alphaValue, 1)
    }

    func testExplicitShowsRejectLateCancelledFadeCallbacks() throws {
        for showAtMouse in [false, true] {
            let fixture = try makeFixture()
            defer { fixture.close() }
            fixture.window.showWindow()
            fixture.window.hideWindowForIslandSwitch()
            fixture.harness.runNextScheduled()
            XCTAssertLessThan(fixture.window.alphaValue, 1)

            if showAtMouse {
                fixture.window.showAtMouseScreen()
            } else {
                fixture.window.showWindow()
            }
            fixture.harness.runAllScheduled()

            XCTAssertEqual(fixture.harness.orderFrontCount, 2)
            XCTAssertEqual(fixture.harness.orderOutCount, 0)
            XCTAssertEqual(fixture.window.alphaValue, 1)
            XCTAssertFalse(fixture.window.handoffState.isFadingOut)
            XCTAssertFalse(fixture.window.isHiddenByIslandSwitch)
            XCTAssertFalse(fixture.window.isSwitchingApps)
        }
    }

    func testRepeatedInboundDuringFadeRestoresAlphaOnlyAfterPreparation() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        var requested: [UInt64] = []
        var completed: [UInt64] = []
        fixture.window.installHandoffPreparationHandler { requested.append($0) }
        fixture.window.showWindow()
        fixture.window.hideWindowForIslandSwitch()
        let fadeGeneration = fixture.window.handoffState.generation
        let scheduledCount = fixture.harness.scheduled.count
        fixture.window.hideWindowForIslandSwitch()
        XCTAssertEqual(fixture.harness.scheduled.count, scheduledCount)
        fixture.harness.runNextScheduled()
        let fadingAlpha = fixture.window.alphaValue
        XCTAssertLessThan(fadingAlpha, 1)

        let first = fixture.window.beginInboundHandoff { completed.append($0) }
        XCTAssertEqual(fixture.window.alphaValue, fadingAlpha, "准备前不能把旧展开内容重新提亮")
        let second = fixture.window.beginInboundHandoff { generation in
            completed.append(generation)
            fixture.window.showPreparedHandoff(generation: generation)
        }
        fixture.harness.runAllScheduled()

        XCTAssertEqual(requested, [first, second])
        XCTAssertFalse(fixture.window.isCurrentHandoff(fadeGeneration))
        XCTAssertEqual(fixture.window.handoffState.pendingPreparation, second)
        XCTAssertEqual(fixture.window.alphaValue, fadingAlpha, "旧淡出帧不能继续改写透明度")
        XCTAssertFalse(fixture.window.handoffState.isFadingOut)
        XCTAssertFalse(fixture.window.isHiddenByIslandSwitch)
        XCTAssertTrue(fixture.window.isSwitchingApps, "旧淡出不能解除新入站请求的切换保护")
        XCTAssertEqual(fixture.harness.orderFrontCount, 1)
        XCTAssertEqual(fixture.harness.orderOutCount, 0)
        XCTAssertFalse(fixture.window.completeInboundHandoffPreparation(generation: first))
        XCTAssertTrue(fixture.window.completeInboundHandoffPreparation(generation: second))
        XCTAssertEqual(completed, [second])
        XCTAssertEqual(fixture.window.alphaValue, 1, "准备好的底壳应完整显示")
        XCTAssertEqual(fixture.harness.orderFrontCount, 2)
    }

    func testExplicitHideRejectsLateFadeCallbacks() throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        fixture.window.showWindow()
        fixture.window.hideWindowForIslandSwitch()
        fixture.harness.runNextScheduled()

        fixture.window.hideWindow()
        fixture.harness.runAllScheduled()

        XCTAssertEqual(fixture.harness.orderOutCount, 1)
        XCTAssertTrue(fixture.window.isHiddenByUser)
        XCTAssertFalse(fixture.window.handoffState.isFadingOut)
        XCTAssertEqual(fixture.window.alphaValue, 1)
    }

    func testReducedMotionOrDisabledAnimationOrdersOutSynchronously() throws {
        for (reduceMotion, animated) in [(true, true), (false, false)] {
            let fixture = try makeFixture(reduceMotion: reduceMotion)
            defer { fixture.close() }
            fixture.window.showWindow()

            fixture.window.hideWindowForIslandSwitch(animated: animated)

            XCTAssertEqual(fixture.harness.orderOutCount, 1)
            XCTAssertTrue(fixture.harness.scheduled.isEmpty)
            XCTAssertEqual(fixture.window.alphaValue, 1)
            XCTAssertFalse(fixture.window.handoffState.isFadingOut)
            XCTAssertTrue(fixture.window.isHiddenByIslandSwitch)
        }
    }

    private func makeFixture(reduceMotion: Bool = false) throws -> Fixture {
        _ = NSApplication.shared
        let suite = "XNookTests.NotchWindowHandoff.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let harness = Harness(reduceMotion: reduceMotion)
        let window = NotchWindow(
            defaults: defaults,
            markVisible: {},
            onExplicitShow: {},
            handoffEnvironment: harness.environment()
        )
        NSWorkspace.shared.notificationCenter.removeObserver(window)
        return Fixture(window: window, harness: harness, defaults: defaults, suite: suite)
    }

    @MainActor
    private struct Fixture {
        let window: NotchWindow
        let harness: Harness
        let defaults: UserDefaults
        let suite: String

        func close() {
            window.close()
            defaults.removePersistentDomain(forName: suite)
        }
    }

    @MainActor
    private final class Harness {
        let reduceMotion: Bool
        var orderFrontCount = 0
        var orderOutCount = 0
        var scheduled: [(delay: TimeInterval, action: @MainActor () -> Void)] = []

        init(reduceMotion: Bool) {
            self.reduceMotion = reduceMotion
        }

        func environment() -> NotchWindow.HandoffEnvironment {
            .init(
                reduceMotion: { [unowned self] in reduceMotion },
                schedule: { [unowned self] delay, action in
                    scheduled.append((delay, action))
                    // 故意保留已取消任务，验证迟到回调不会影响新一轮显示。
                    return {}
                },
                orderFront: { [unowned self] _ in orderFrontCount += 1 },
                orderOut: { [unowned self] _ in orderOutCount += 1 }
            )
        }

        func runNextScheduled() {
            guard let index = scheduled.indices.min(by: { scheduled[$0].delay < scheduled[$1].delay }) else {
                XCTFail("预期有待执行的淡出步骤")
                return
            }
            scheduled.remove(at: index).action()
        }

        func runAllScheduled() {
            for _ in 0..<64 {
                guard !scheduled.isEmpty else { return }
                runNextScheduled()
            }
            XCTAssertTrue(scheduled.isEmpty, "淡出应在有限步骤内完成")
        }
    }
}
