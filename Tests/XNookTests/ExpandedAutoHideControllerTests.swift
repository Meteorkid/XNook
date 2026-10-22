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
}
