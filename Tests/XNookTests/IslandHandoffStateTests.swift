import XCTest
@testable import XNook

final class IslandHandoffStateTests: XCTestCase {
    func testStationaryPointerStaysSuppressedUntilItActuallyLeaves() {
        var state = IslandHandoffState()
        let generation = state.beginInbound()
        XCTAssertTrue(state.consumePreparation(generation))

        for _ in 0..<1_000 {
            XCTAssertTrue(state.observePointer(isInside: true), "停留或在岛内上移不能解除交接抑制")
        }

        XCTAssertFalse(state.observePointer(isInside: false))
        XCTAssertFalse(state.observePointer(isInside: true), "真实离开后再次进入应允许正常悬停")
    }

    func testHandoffAndSwitchingBlockStationaryAndUpwardHoverActions() {
        var state = IslandHandoffState()
        let generation = state.beginInbound()
        XCTAssertTrue(state.consumePreparation(generation))
        for (wasInside, currentY) in [(false, CGFloat(500)), (true, CGFloat(540))] {
            XCTAssertFalse(NotchContentView.shouldTriggerHoverJelly(
                isPointerInside: true,
                wasPointerInside: wasInside,
                isExpanded: false,
                collapseAnimating: false,
                previousMouseY: 500,
                currentMouseY: currentY,
                isHandoffSuppressed: state.observePointer(isInside: true)
            ))
            XCTAssertFalse(NotchContentView.shouldTriggerHoverJelly(
                isPointerInside: true,
                wasPointerInside: wasInside,
                isExpanded: false,
                collapseAnimating: false,
                previousMouseY: 500,
                currentMouseY: currentY,
                isSwitchingApps: true
            ))
            XCTAssertFalse(NotchContentView.shouldExpandForHover(
                isPointerInside: true,
                isExpanded: false,
                hasPassedCollapseCooldown: true,
                hoverToExpandPanel: true,
                isSwitchingApps: false,
                isHandoffSuppressed: state.observePointer(isInside: true)
            ))
        }

        XCTAssertFalse(state.observePointer(isInside: false))
        let suppressedAfterReentry = state.observePointer(isInside: true)
        XCTAssertTrue(NotchContentView.shouldTriggerHoverJelly(
            isPointerInside: true,
            wasPointerInside: false,
            isExpanded: false,
            collapseAnimating: false,
            previousMouseY: 500,
            currentMouseY: 500,
            isHandoffSuppressed: suppressedAfterReentry
        ))
        XCTAssertTrue(NotchContentView.shouldExpandForHover(
            isPointerInside: true,
            isExpanded: false,
            hasPassedCollapseCooldown: true,
            hoverToExpandPanel: true,
            isSwitchingApps: false,
            isHandoffSuppressed: suppressedAfterReentry
        ))
    }

    func testOldFrameOutsideCannotUnlockHoverBeforePreparationCompletes() {
        var state = IslandHandoffState()
        let generation = state.beginInbound()

        XCTAssertTrue(state.observePointer(isInside: false), "准备期间的旧屏幕 frame 不能解锁悬停")
        XCTAssertTrue(state.consumePreparation(generation))
        XCTAssertTrue(state.observePointer(isInside: true))
        XCTAssertFalse(state.observePointer(isInside: false), "准备完成后真实离开才解锁")
        XCTAssertFalse(state.observePointer(isInside: true))
    }

    func testHorizontalPreviewBlocksHoverWhileVerticalGestureAndIdleAllowIt() {
        for (deltaX, deltaY, hoverAllowed) in [(CGFloat(18), CGFloat(1), false), (CGFloat(1), CGFloat(18), true)] {
            let recognizer = SwipeGestureRecognizer()
            let now = Date(timeIntervalSince1970: 100)
            _ = recognizer.handleScroll(deltaX: deltaX, deltaY: deltaY, isPrecise: true,
                                        phase: .began, momentumPhase: [], now: now)
            XCTAssertTrue(recognizer.isActive)
            let switching = recognizer.consumesHorizontalScroll
            XCTAssertEqual(NotchContentView.shouldTriggerHoverJelly(
                isPointerInside: true, wasPointerInside: false, isExpanded: false,
                collapseAnimating: false, previousMouseY: 500, currentMouseY: 510,
                isSwitchingApps: switching
            ), hoverAllowed)
            XCTAssertEqual(NotchContentView.shouldExpandForHover(
                isPointerInside: true, isExpanded: false, hasPassedCollapseCooldown: true,
                hoverToExpandPanel: true, isSwitchingApps: switching
            ), hoverAllowed, "纵向锁轴不能被当作横滑预览而屏蔽悬停")

            _ = recognizer.handleScroll(deltaX: 0, deltaY: 0, isPrecise: true,
                                        phase: .ended, momentumPhase: [], now: now.addingTimeInterval(0.1))
            XCTAssertFalse(recognizer.consumesHorizontalScroll)
            XCTAssertTrue(NotchContentView.shouldExpandForHover(
                isPointerInside: true, isExpanded: false, hasPassedCollapseCooldown: true,
                hoverToExpandPanel: true, isSwitchingApps: recognizer.consumesHorizontalScroll
            ), "手势结束后恢复正常悬停，不留下额外锁定")
        }
    }

    func testOnlyLatestInboundPreparationCanCompleteOnce() {
        var state = IslandHandoffState()
        let first = state.beginInbound()
        let second = state.beginInbound()

        XCTAssertGreaterThan(second, first)
        XCTAssertEqual(state.pendingPreparation, second)
        XCTAssertFalse(state.consumePreparation(first))
        XCTAssertEqual(state.pendingPreparation, second)
        XCTAssertTrue(state.consumePreparation(second))
        XCTAssertNil(state.pendingPreparation)
        XCTAssertFalse(state.consumePreparation(second))
        XCTAssertTrue(state.isHoverSuppressed)
    }

    func testCancellationInvalidatesPreparationWithoutUnlockingHover() {
        var state = IslandHandoffState()
        let pending = state.beginInbound()

        state.cancelPresentation()

        XCTAssertGreaterThan(state.generation, pending)
        XCTAssertNil(state.pendingPreparation)
        XCTAssertFalse(state.consumePreparation(pending))
        XCTAssertTrue(state.observePointer(isInside: true))
        XCTAssertFalse(state.observePointer(isInside: false))
    }

    func testRepeatedFadeDoesNotRestartAndCompletionIsSingleUse() throws {
        var state = IslandHandoffState()
        let pending = state.beginInbound()
        let fade = try XCTUnwrap(state.beginFadeOut())

        XCTAssertGreaterThan(fade, pending)
        XCTAssertNil(state.pendingPreparation)
        XCTAssertFalse(state.consumePreparation(pending))
        XCTAssertNil(state.beginFadeOut())
        XCTAssertEqual(state.generation, fade)
        XCTAssertFalse(state.finishFadeOut(pending))
        XCTAssertTrue(state.isFadingOut)
        XCTAssertTrue(state.finishFadeOut(fade))
        XCTAssertFalse(state.isFadingOut)
        XCTAssertFalse(state.finishFadeOut(fade))
    }

    func testNewInboundInvalidatesPreviousFade() throws {
        var state = IslandHandoffState()
        let fade = try XCTUnwrap(state.beginFadeOut())

        let inbound = state.beginInbound()

        XCTAssertGreaterThan(inbound, fade)
        XCTAssertFalse(state.isFadingOut)
        XCTAssertFalse(state.finishFadeOut(fade))
        XCTAssertEqual(state.pendingPreparation, inbound)
        XCTAssertTrue(state.isHoverSuppressed)
    }

    func testCancellationInvalidatesFade() throws {
        var state = IslandHandoffState()
        let fade = try XCTUnwrap(state.beginFadeOut())

        state.cancelPresentation()

        XCTAssertFalse(state.isFadingOut)
        XCTAssertFalse(state.finishFadeOut(fade))
        XCTAssertGreaterThan(state.generation, fade)
    }

    func testPresentationRequiresPreparationAndStartsOnlyOnce() {
        var state = IslandHandoffState()
        let generation = state.beginInbound()

        XCTAssertFalse(state.beginPresentation(generation))
        XCTAssertFalse(state.finishPresentation(generation))
        XCTAssertTrue(state.consumePreparation(generation))
        XCTAssertEqual(state.pendingPresentation, generation)
        XCTAssertTrue(state.beginPresentation(generation))
        XCTAssertNil(state.pendingPresentation)
        XCTAssertTrue(state.isPresentingInbound)
        XCTAssertFalse(state.beginPresentation(generation))
        XCTAssertTrue(state.finishPresentation(generation))
        XCTAssertFalse(state.isPresentingInbound)
        XCTAssertFalse(state.finishPresentation(generation))
        XCTAssertFalse(state.beginPresentation(generation))
    }

    func testNewInboundRejectsOldPresentationCompletion() {
        var state = IslandHandoffState()
        let first = state.beginInbound()
        XCTAssertTrue(state.consumePreparation(first))
        XCTAssertTrue(state.beginPresentation(first))

        let latest = state.beginInbound()
        XCTAssertFalse(state.finishPresentation(first))
        XCTAssertFalse(state.isPresentingInbound)
        XCTAssertTrue(state.consumePreparation(latest))
        XCTAssertTrue(state.beginPresentation(latest))
        XCTAssertFalse(state.finishPresentation(first))
        XCTAssertTrue(state.isPresentingInbound)
        XCTAssertTrue(state.finishPresentation(latest))
    }

    func testCancellationAndOutgoingInvalidateInboundPresentation() {
        for fadeOut in [false, true] {
            var state = IslandHandoffState()
            let generation = state.beginInbound()
            XCTAssertTrue(state.consumePreparation(generation))
            XCTAssertTrue(state.beginPresentation(generation))

            if fadeOut { XCTAssertNotNil(state.beginFadeOut()) } else { state.cancelPresentation() }

            XCTAssertNil(state.pendingPresentation)
            XCTAssertFalse(state.isPresentingInbound)
            XCTAssertFalse(state.finishPresentation(generation))
        }
    }

    func testReducedMotionRemovesBothHandoffDurations() {
        XCTAssertEqual(IslandHandoffState.inboundContentDuration(reduceMotion: false), 0.15)
        XCTAssertEqual(IslandHandoffState.outboundDuration(reduceMotion: false), 0.12)
        XCTAssertEqual(IslandHandoffState.inboundContentDuration(reduceMotion: true), 0)
        XCTAssertEqual(IslandHandoffState.outboundDuration(reduceMotion: true), 0)
    }
}
