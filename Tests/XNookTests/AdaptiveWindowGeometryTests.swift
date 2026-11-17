import AppKit
import XCTest
@testable import XNook

@MainActor
final class AdaptiveWindowGeometryTests: XCTestCase {
    func testExpandedWindowFitsVisibleWidthAndRetainsTopExtension() {
        let screen = CGRect(x: -1440, y: 300, width: 1440, height: 900)
        let visible = CGRect(x: -1380, y: 350, width: 1380, height: 826)
        let fitted = NotchWindow.fittingExpandedFrame(
            CGRect(x: -1500, y: 0, width: 1800, height: 1000),
            screenFrame: screen, visibleFrame: visible
        )

        XCTAssertEqual(fitted.width, visible.width)
        XCTAssertEqual(fitted.height, visible.height)
        XCTAssertEqual(fitted.minX, visible.minX)
        XCTAssertEqual(fitted.maxY, screen.maxY + 4)
        XCTAssertGreaterThanOrEqual(fitted.minY, visible.minY)
    }

    func testExpandedWindowPreservesUserHorizontalPositionWithinBounds() {
        let screen = CGRect(x: 1920, y: -200, width: 1280, height: 800)
        let visible = CGRect(x: 1920, y: -150, width: 1220, height: 726)
        let proposed = CGRect(x: 2050, y: 0, width: 700, height: 500)
        let fitted = NotchWindow.fittingExpandedFrame(proposed, screenFrame: screen, visibleFrame: visible)
        let rightEdge = NotchWindow.fittingExpandedFrame(
            CGRect(x: 3000, y: 0, width: 700, height: 500),
            screenFrame: screen, visibleFrame: visible
        )

        XCTAssertEqual(fitted.minX, proposed.minX)
        XCTAssertEqual(fitted.size, proposed.size)
        XCTAssertEqual(rightEdge.maxX, visible.maxX)
        XCTAssertEqual(fitted.maxY, screen.maxY + 4)
    }

    func testCrossScreenMappingUsesLocalCoordinatesAndRoundTrips() {
        let left = CGRect(x: -1440, y: 300, width: 1440, height: 900)
        let right = CGRect(x: 1920, y: -200, width: 1280, height: 800)
        let mapped = NotchWindow.mappedCenterX(-1080, from: left, to: right)

        XCTAssertEqual(mapped, 2240)
        XCTAssertEqual(NotchWindow.mappedCenterX(mapped, from: right, to: left), -1080)
        XCTAssertEqual(NotchWindow.mappedCenterX(-1080, from: left, to: left), -1080)
    }

    func testInvalidProposedDimensionsProduceFiniteVisibleFrame() {
        let screen = CGRect(x: 0, y: 0, width: 120, height: 80)
        let fitted = NotchWindow.fittingExpandedFrame(
            CGRect(x: CGFloat.nan, y: CGFloat.infinity, width: CGFloat.infinity, height: CGFloat.nan),
            screenFrame: screen, visibleFrame: screen
        )

        XCTAssertEqual(fitted.size, CGSize(width: 1, height: 1))
        XCTAssertTrue(fitted.minX.isFinite)
        XCTAssertEqual(fitted.maxY, 84)
    }

    func testScreenLimitsRemainBoundedBelowNormalSettingsMinimum() {
        XCTAssertEqual(NotchWindow.maximumExpandedContentHeight(forScreenHeight: 20), 8)
        XCTAssertEqual(NotchWindow.maximumExpandedContentWidth(forScreenWidth: 20), 4)
        XCTAssertEqual(NotchWindow.maximumExpandedContentHeight(forScreenHeight: 0), 1)
        XCTAssertEqual(NotchWindow.maximumExpandedContentWidth(forScreenWidth: -1), 1)
        XCTAssertEqual(NotchWindow.maximumExpandedContentHeight(forScreenHeight: .nan), 900)
        XCTAssertEqual(NotchWindow.maximumExpandedContentWidth(forScreenWidth: .infinity), 1600)
    }
}
