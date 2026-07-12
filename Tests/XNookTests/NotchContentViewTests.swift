import XCTest
@testable import XNook

final class NotchContentViewTests: XCTestCase {
    func testHoverJellyTriggersOnFirstEntryEvenWithoutUpwardMotion() {
        XCTAssertTrue(
            NotchContentView.shouldTriggerHoverJelly(
                isPointerInside: true,
                wasPointerInside: false,
                isExpanded: false,
                collapseAnimating: false,
                previousMouseY: 500,
                currentMouseY: 500
            )
        )
    }

    func testHoverJellyTriggersWhenPointerMovesUpwardInsidePill() {
        XCTAssertTrue(
            NotchContentView.shouldTriggerHoverJelly(
                isPointerInside: true,
                wasPointerInside: true,
                isExpanded: false,
                collapseAnimating: false,
                previousMouseY: 480,
                currentMouseY: 520
            )
        )
    }

    func testHoverJellyDoesNotTriggerWhileExpandedOrOutside() {
        XCTAssertFalse(
            NotchContentView.shouldTriggerHoverJelly(
                isPointerInside: false,
                wasPointerInside: false,
                isExpanded: false,
                collapseAnimating: false,
                previousMouseY: 480,
                currentMouseY: 520
            )
        )
        XCTAssertFalse(
            NotchContentView.shouldTriggerHoverJelly(
                isPointerInside: true,
                wasPointerInside: false,
                isExpanded: true,
                collapseAnimating: false,
                previousMouseY: 480,
                currentMouseY: 520
            )
        )
    }

    func testHoverExpansionRespectsSettingWithoutStoppingHoverDetection() {
        XCTAssertFalse(
            NotchContentView.shouldExpandForHover(
                isPointerInside: true,
                isExpanded: false,
                hasPassedCollapseCooldown: true,
                hoverToExpandPanel: false,
                isSwitchingApps: false
            )
        )
        XCTAssertTrue(
            NotchContentView.shouldExpandForHover(
                isPointerInside: true,
                isExpanded: false,
                hasPassedCollapseCooldown: true,
                hoverToExpandPanel: true,
                isSwitchingApps: false
            )
        )
    }

    func testExpandedHoverHitFrameCoversWindowWithPadding() {
        let windowFrame = CGRect(x: 100, y: 200, width: 520, height: 260)
        let screenFrame = CGRect(x: 0, y: 0, width: 1512, height: 949)

        let hitFrame = NotchContentView.hoverHitFrame(
            windowFrame: windowFrame,
            screenFrame: screenFrame,
            isExpanded: true
        )

        XCTAssertTrue(hitFrame.contains(CGPoint(x: windowFrame.minX, y: windowFrame.minY)))
        XCTAssertTrue(hitFrame.contains(CGPoint(x: windowFrame.maxX, y: windowFrame.maxY)))
        XCTAssertEqual(hitFrame.minY, windowFrame.minY - 20, accuracy: 0.001)
        XCTAssertEqual(hitFrame.maxY, windowFrame.maxY + 20, accuracy: 0.001)
    }

    func testExpandedAutoHideDefersWhilePointerRemainsInsidePanel() {
        let windowFrame = CGRect(x: 100, y: 200, width: 520, height: 260)
        let screenFrame = CGRect(x: 0, y: 0, width: 1512, height: 949)

        XCTAssertTrue(
            NotchContentView.shouldDeferExpandedAutoHide(
                mouseLocation: CGPoint(x: 360, y: 320),
                windowFrame: windowFrame,
                screenFrame: screenFrame
            )
        )
        XCTAssertFalse(
            NotchContentView.shouldDeferExpandedAutoHide(
                mouseLocation: CGPoint(x: 40, y: 80),
                windowFrame: windowFrame,
                screenFrame: screenFrame
            )
        )
    }
}
