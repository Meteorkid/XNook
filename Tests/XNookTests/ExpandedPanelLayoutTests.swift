import XCTest
@testable import XNook

final class ExpandedPanelLayoutTests: XCTestCase {
    func testNarrowPanelsUseOneColumnAndFourWidgetsUseTwoBalancedColumns() {
        XCTAssertEqual(ExpandedPanelLayout.columnCount(width: 160, widgetCount: 4), 1)
        XCTAssertEqual(ExpandedPanelLayout.columnCount(width: 480, widgetCount: 4), 1)
        XCTAssertEqual(ExpandedPanelLayout.columnCount(width: 800, widgetCount: 4), 2)
        XCTAssertEqual(ExpandedPanelLayout.columnCount(width: 1600, widgetCount: 2), 2)
    }

    func testDefaultWidthFitsThreeWidgetsInOneRow() {
        XCTAssertEqual(ExpandedPanelLayout.columnCount(width: 800, widgetCount: 3), 3)
    }

    func testAddingFourthWidgetBalancesRowsAndRemovingItRestoresOneRow() {
        let columns = [3, 4, 3].map {
            ExpandedPanelLayout.columnCount(width: 800, widgetCount: $0)
        }

        XCTAssertEqual(columns, [3, 2, 3])
    }

    func testThreeColumnsIncludeOuterPaddingCardPaddingAndColumnSpacing() {
        // 24pt 外边距 + 3 × (224pt 内容 + 24pt 卡片内边距) + 2 × 12pt 列间距。
        XCTAssertEqual(ExpandedPanelLayout.columnCount(width: 792, widgetCount: 3), 3)
        XCTAssertEqual(ExpandedPanelLayout.columnCount(width: 791.5, widgetCount: 3), 2)
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

    func testMeasuredContentMayGrowBeyondLegacyManualHeight() {
        XCTAssertEqual(
            ExpandedPanelLayout.height(measuredContentHeight: 520, maximumHeight: 900),
            520
        )
        XCTAssertEqual(
            ExpandedPanelLayout.height(measuredContentHeight: 520, maximumHeight: 200),
            200
        )
    }

    func testScreenSmallerThanHeaderStillBoundsHeight() {
        XCTAssertEqual(ExpandedPanelLayout.height(measuredContentHeight: 520, maximumHeight: 20), 20)
        XCTAssertEqual(ExpandedPanelLayout.height(measuredContentHeight: nil, maximumHeight: 20), 20)
    }

    func testAutomaticHeightIgnoresManualLimitAndManualModeRetainsIt() {
        let automatic = ExpandedPanelLayout.maximumHeight(availableHeight: 900, automaticallyFit: true, manualMaxHeight: 200)
        let manual = ExpandedPanelLayout.maximumHeight(availableHeight: 900, automaticallyFit: false, manualMaxHeight: 200)

        XCTAssertEqual(ExpandedPanelLayout.height(measuredContentHeight: 520, maximumHeight: automatic), 520)
        XCTAssertEqual(ExpandedPanelLayout.height(measuredContentHeight: 520, maximumHeight: manual), 200)
        XCTAssertEqual(ExpandedPanelLayout.maximumHeight(availableHeight: 160, automaticallyFit: true, manualMaxHeight: 200), 160)
        XCTAssertEqual(ExpandedPanelLayout.maximumHeight(availableHeight: 160, automaticallyFit: false, manualMaxHeight: 200), 160)
    }

    func testTinyManualLimitRetainsViewportUnlessScreenIsSmaller() {
        XCTAssertEqual(ExpandedPanelLayout.maximumHeight(availableHeight: 900, automaticallyFit: false, manualMaxHeight: 1), 78)
        XCTAssertEqual(ExpandedPanelLayout.maximumHeight(availableHeight: 20, automaticallyFit: false, manualMaxHeight: 1), 20)
    }

    func testInvalidHeightInputsUseFiniteDefaults() {
        let invalidValues: [CGFloat] = [.nan, .infinity, -.infinity, 0, -1]
        for value in invalidValues {
            XCTAssertEqual(ExpandedPanelLayout.maximumHeight(availableHeight: value, automaticallyFit: true, manualMaxHeight: value), 900)
            XCTAssertEqual(ExpandedPanelLayout.maximumHeight(availableHeight: value, automaticallyFit: false, manualMaxHeight: value), 200)
            XCTAssertEqual(ExpandedPanelLayout.height(measuredContentHeight: value, maximumHeight: value), 400)
        }
    }

    func testEmptyAndExtremeWidgetCountsStayBounded() {
        XCTAssertEqual(ExpandedPanelLayout.columnCount(width: 800, widgetCount: 0), 0)
        XCTAssertEqual(ExpandedPanelLayout.columnCount(width: 800, widgetCount: -1), 0)
        XCTAssertEqual(ExpandedPanelLayout.columnCount(width: .greatestFiniteMagnitude, widgetCount: .max), .max)
        XCTAssertEqual(ExpandedPanelLayout.columnCount(width: 800, widgetCount: .max), 3)
    }

    func testMeasurementRejectsPreviousWidthAndPreviousNavigationMode() {
        let overview = ExpandedPanelMeasurement(width: 800, height: 520, selectedWidget: nil)
        let detail = ExpandedPanelMeasurement(width: 800, height: 720, selectedWidget: .notes)

        XCTAssertTrue(overview.matches(width: 800.1, selectedWidget: nil))
        XCTAssertFalse(overview.matches(width: 800.5, selectedWidget: nil))
        XCTAssertFalse(overview.matches(width: 600, selectedWidget: nil))
        XCTAssertFalse(overview.matches(width: 800, selectedWidget: .notes))
        XCTAssertTrue(detail.matches(width: 800, selectedWidget: .notes))
        XCTAssertFalse(detail.matches(width: 800, selectedWidget: .calendar))
    }

    func testInvalidMeasurementsCannotReplaceValidDimensions() {
        let invalidValues: [CGFloat] = [.nan, .infinity, -.infinity, 0, -1]
        for value in invalidValues {
            XCTAssertFalse(ExpandedPanelMeasurement(width: value, height: 520, selectedWidget: nil).matches(width: 800, selectedWidget: nil))
            XCTAssertFalse(ExpandedPanelMeasurement(width: 800, height: value, selectedWidget: nil).matches(width: 800, selectedWidget: nil))
        }
    }

    func testMeasurementsIgnoreSubpixelNoiseButAcceptContentAndModeChanges() {
        let previous = ExpandedPanelMeasurement(width: 800, height: 520, selectedWidget: nil)
        XCTAssertFalse(ExpandedPanelMeasurement(width: 800, height: 520.4, selectedWidget: nil).differs(from: previous))
        XCTAssertTrue(ExpandedPanelMeasurement(width: 800, height: 521, selectedWidget: nil).differs(from: previous))
        XCTAssertTrue(ExpandedPanelMeasurement(width: 800, height: 520, selectedWidget: .notes).differs(from: previous))
        XCTAssertTrue(previous.differs(from: nil))
    }
}
