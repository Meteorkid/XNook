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

    func testReducedMotionRemovesBothHandoffDurations() {
        XCTAssertEqual(IslandHandoffState.inboundContentDuration(reduceMotion: false), 0.15)
        XCTAssertEqual(IslandHandoffState.outboundDuration(reduceMotion: false), 0.12)
        XCTAssertEqual(IslandHandoffState.inboundContentDuration(reduceMotion: true), 0)
        XCTAssertEqual(IslandHandoffState.outboundDuration(reduceMotion: true), 0)
    }
}
