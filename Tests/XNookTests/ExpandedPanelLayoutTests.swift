import XCTest
@testable import XNook

final class ExpandedPanelLayoutTests: XCTestCase {
    func testNarrowPanelsUseOneColumnAndDefaultWidthUsesTwo() {
        XCTAssertEqual(ExpandedPanelLayout.columnCount(width: 160, widgetCount: 4), 1)
        XCTAssertEqual(ExpandedPanelLayout.columnCount(width: 480, widgetCount: 4), 1)
        XCTAssertEqual(ExpandedPanelLayout.columnCount(width: 800, widgetCount: 4), 2)
        XCTAssertEqual(ExpandedPanelLayout.columnCount(width: 1600, widgetCount: 2), 2)
    }

    func testNaturalHeightFitsContentAndCapsOverflow() {
        XCTAssertEqual(ExpandedPanelLayout.height(measuredContentHeight: 270, maximumHeight: 400), 270)
        XCTAssertEqual(ExpandedPanelLayout.height(measuredContentHeight: 1250, maximumHeight: 400), 400)
        XCTAssertEqual(ExpandedPanelLayout.height(measuredContentHeight: 1250, maximumHeight: 160), 160)
    }

    func testInvalidMeasurementsUseBoundedInitialHeight() {
        XCTAssertEqual(ExpandedPanelLayout.height(measuredContentHeight: nil, maximumHeight: 160), 160)
        XCTAssertEqual(ExpandedPanelLayout.height(measuredContentHeight: .nan, maximumHeight: 600), 400)
        XCTAssertEqual(ExpandedPanelLayout.columnCount(width: .infinity, widgetCount: 4), 1)
    }
}
