import XCTest
@testable import XNook

final class ExpandedAutoHideControllerTests: XCTestCase {
    @MainActor
    func testRepeatedPollingStartsOnlyOneWaitAndEnteringCancelsIt() async {
        let started = expectation(description: "等待开始")
        let cancelled = expectation(description: "进入面板后取消等待")
        var waitCount = 0
        var hideCount = 0
        let controller = ExpandedAutoHideController { _ in
            waitCount += 1
            started.fulfill()
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                cancelled.fulfill()
                throw error
            }
        }

        for _ in 0..<10_000 {
            controller.update(isExpanded: true, shouldDefer: false, delay: 600) { hideCount += 1 }
        }
        await fulfillment(of: [started], timeout: 1)
        XCTAssertEqual(waitCount, 1)

        controller.update(isExpanded: true, shouldDefer: true, delay: 600) { hideCount += 1 }
        await fulfillment(of: [cancelled], timeout: 1)
        XCTAssertEqual(hideCount, 0)
    }

    @MainActor
    func testCompletionHidesOnceAndAllowsNextExpansion() async {
        let firstHidden = expectation(description: "第一次展开收起")
        let secondHidden = expectation(description: "第二次展开收起")
        let controller = ExpandedAutoHideController { _ in }
        controller.update(isExpanded: true, shouldDefer: false, delay: 1) { firstHidden.fulfill() }
        await fulfillment(of: [firstHidden], timeout: 1)
        controller.update(isExpanded: true, shouldDefer: false, delay: 1) { secondHidden.fulfill() }
        await fulfillment(of: [secondHidden], timeout: 1)
    }

    @MainActor
    func testDisablingOrCollapsingCancelsWait() async {
        for (isExpanded, delay) in [(true, 0.0), (false, 1.0), (true, Double.nan)] {
            let started = expectation(description: "等待开始")
            let cancelled = expectation(description: "失效状态取消等待")
            let controller = ExpandedAutoHideController { _ in
                started.fulfill()
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    cancelled.fulfill()
                    throw error
                }
            }
            controller.update(isExpanded: true, shouldDefer: false, delay: 1) {
                XCTFail("已失效的自动隐藏不能执行")
            }
            await fulfillment(of: [started], timeout: 1)
            controller.update(isExpanded: isExpanded, shouldDefer: false, delay: delay) {
                XCTFail("禁用或收起后不能调度")
            }
            await fulfillment(of: [cancelled], timeout: 1)
        }
    }

    @MainActor
    func testDelayChangeCancelsPreviousWaitAndUsesNewDelay() async {
        let started = expectation(description: "原等待开始")
        let cancelled = expectation(description: "原等待取消")
        let hidden = expectation(description: "新延时完成")
        var requestedDelays: [Duration] = []
        let controller = ExpandedAutoHideController { duration in
            requestedDelays.append(duration)
            if duration == .seconds(60) {
                started.fulfill()
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    cancelled.fulfill()
                    throw error
                }
            }
        }
        controller.update(isExpanded: true, shouldDefer: false, delay: 60) {
            XCTFail("旧等待不能收起面板")
        }
        await fulfillment(of: [started], timeout: 1)
        controller.update(isExpanded: true, shouldDefer: false, delay: 1) { hidden.fulfill() }
        await fulfillment(of: [cancelled, hidden], timeout: 1)
        XCTAssertEqual(requestedDelays, [.seconds(60), .seconds(1)])
    }

    @MainActor
    func testControllerCanDeallocateWhileWaitingAndCancelsWork() async {
        let started = expectation(description: "等待开始")
        let cancelled = expectation(description: "释放时取消等待")
        var controller: ExpandedAutoHideController? = ExpandedAutoHideController { _ in
            started.fulfill()
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                cancelled.fulfill()
                throw error
            }
        }
        weak var weakController = controller
        controller?.update(isExpanded: true, shouldDefer: false, delay: 60) {
            XCTFail("控制器释放后不能收起")
        }
        await fulfillment(of: [started], timeout: 1)
        controller = nil
        XCTAssertNil(weakController)
        await fulfillment(of: [cancelled], timeout: 1)
    }

    // MARK: - 悬停暂停与剩余时间记账

    /// Duration 的 seconds 是静态构造函数而非枚举 case，无法模式匹配；
    /// 统一换算成 Double 秒便于断言。
    private func seconds(of duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    /// 等待记录让出执行权：调度是同步建立 Task，但任务体要到当前同步段结束后才跑。
    private func drainTaskBody() async {
        for _ in 0..<5 { await Task.yield() }
    }

    /// 悬停（shouldDefer）应挂起倒计时而不是收起；未在等待时是 no-op。
    @MainActor
    func testDeferringPausesWithoutHiding() async {
        let started = expectation(description: "等待开始")
        var hideCount = 0
        let controller = ExpandedAutoHideController { _ in
            started.fulfill()
            try await Task.sleep(for: .seconds(60))
        }
        controller.update(isExpanded: true, shouldDefer: false, delay: 60) { hideCount += 1 }
        await fulfillment(of: [started], timeout: 1)

        controller.update(isExpanded: true, shouldDefer: true, delay: 60) { hideCount += 1 }
        XCTAssertEqual(hideCount, 0, "悬停期间不能收起")
    }

    /// 核心语义：悬停消耗掉的时间要从剩余时间里扣掉，而不是重排完整延迟。
    /// 用可控时钟推进 40s 后暂停，恢复时应只等剩余的 20s。
    @MainActor
    func testResumeAfterPauseUsesRemainingTime() async {
        var currentDate = Date(timeIntervalSince1970: 0)
        var requestedDurations: [Duration] = []
        let controller = ExpandedAutoHideController(
            now: { currentDate },
            sleep: { duration in
                requestedDurations.append(duration)
                // 不真正等待，交由测试推进时钟
                throw CancellationError()
            }
        )

        controller.update(isExpanded: true, shouldDefer: false, delay: 60) { }
        await drainTaskBody()
        XCTAssertEqual(requestedDurations.count, 1)
        XCTAssertEqual(seconds(of: requestedDurations[0]), 60, accuracy: 0.01)

        // 模拟已过去 40 秒
        currentDate = currentDate.addingTimeInterval(40)
        controller.update(isExpanded: true, shouldDefer: true, delay: 60) { }

        // 恢复：应只排剩余的 20 秒
        controller.update(isExpanded: true, shouldDefer: false, delay: 60) { }
        await drainTaskBody()
        XCTAssertEqual(requestedDurations.count, 2)
        XCTAssertEqual(
            seconds(of: requestedDurations[1]), 20, accuracy: 0.01,
            "应扣掉悬停前已消耗的 40 秒"
        )

        // 关键：恢复后轮询仍在继续传入设置值 60s。若实现拿设置值与实际等待时长
        // 比对，就会误判成"延迟变了"并把 20s 重置回 60s，记账等于白做。
        for _ in 0..<5 {
            controller.update(isExpanded: true, shouldDefer: false, delay: 60) { }
            await drainTaskBody()
        }
        XCTAssertEqual(requestedDurations.count, 2, "恢复后的重复轮询不得重新排等待")
    }

    /// 悬停期间用户改了延迟设置，应以新值为准而不是用旧的剩余时间。
    @MainActor
    func testDelayChangeDuringPauseOverridesRemaining() async {
        var currentDate = Date(timeIntervalSince1970: 0)
        var requestedDurations: [Duration] = []
        let controller = ExpandedAutoHideController(
            now: { currentDate },
            sleep: { duration in
                requestedDurations.append(duration)
                throw CancellationError()
            }
        )

        controller.update(isExpanded: true, shouldDefer: false, delay: 60) { }
        await drainTaskBody()
        currentDate = currentDate.addingTimeInterval(40)
        controller.update(isExpanded: true, shouldDefer: true, delay: 60) { }

        // 用户把延迟改成 5 秒后恢复
        controller.update(isExpanded: true, shouldDefer: false, delay: 5) { }
        await drainTaskBody()
        XCTAssertEqual(requestedDurations.count, 2)
        XCTAssertEqual(
            seconds(of: requestedDurations[1]), 5, accuracy: 0.01,
            "延迟变更后应使用新值"
        )
    }

    /// 暂停时已超出总延迟，剩余时间应被夹到 0 而不是负数。
    @MainActor
    func testRemainingTimeIsClampedToZero() async {
        var currentDate = Date(timeIntervalSince1970: 0)
        var requestedDurations: [Duration] = []
        let controller = ExpandedAutoHideController(
            now: { currentDate },
            sleep: { duration in
                requestedDurations.append(duration)
                throw CancellationError()
            }
        )

        controller.update(isExpanded: true, shouldDefer: false, delay: 1) { }
        await drainTaskBody()
        currentDate = currentDate.addingTimeInterval(100)
        controller.update(isExpanded: true, shouldDefer: true, delay: 1) { }
        controller.update(isExpanded: true, shouldDefer: false, delay: 1) { }
        await drainTaskBody()

        XCTAssertEqual(requestedDurations.count, 2)
        XCTAssertEqual(seconds(of: requestedDurations[1]), 0, accuracy: 0.01)
    }

    /// 取消（收起或禁用）必须清掉记账，否则下次展开会误用旧剩余时间。
    @MainActor
    func testCancelClearsRemainingTime() async {
        var currentDate = Date(timeIntervalSince1970: 0)
        var requestedDurations: [Duration] = []
        let controller = ExpandedAutoHideController(
            now: { currentDate },
            sleep: { duration in
                requestedDurations.append(duration)
                throw CancellationError()
            }
        )

        controller.update(isExpanded: true, shouldDefer: false, delay: 60) { }
        await drainTaskBody()
        currentDate = currentDate.addingTimeInterval(40)
        controller.update(isExpanded: true, shouldDefer: true, delay: 60) { }
        // 收起 -> 取消
        controller.update(isExpanded: false, shouldDefer: false, delay: 60) { }
        // 重新展开：应使用完整延迟
        controller.update(isExpanded: true, shouldDefer: false, delay: 60) { }
        await drainTaskBody()

        XCTAssertEqual(requestedDurations.count, 2)
        XCTAssertEqual(
            seconds(of: requestedDurations[1]), 60, accuracy: 0.01,
            "取消后应清掉剩余时间记账"
        )
    }
}
