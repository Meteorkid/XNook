import XCTest
@testable import XNook

final class ExpandedPanelLayoutTests: XCTestCase {
    private let enabledWidgets = NotchContentView.WidgetType.allCases
    func testHeaderAndNavigationShareCompactToolbar() {
        XCTAssertLessThanOrEqual(ExpandedPanelLayout.headerHeight, 45)
    }

    func testToolbarMovesBelowNotchOnlyWhenSideControlsCannotFit() {
        XCTAssertEqual(ExpandedPanelLayout.headerTopInset(width: 800, deadZoneWidth: 200, deadZoneHeight: 32), 0)
        XCTAssertEqual(ExpandedPanelLayout.headerTopInset(width: 344, deadZoneWidth: 200, deadZoneHeight: 32), 0)
        XCTAssertEqual(ExpandedPanelLayout.headerTopInset(width: 320, deadZoneWidth: 200, deadZoneHeight: 32), 32)
        XCTAssertEqual(ExpandedPanelLayout.headerTopInset(width: 160, deadZoneWidth: 200, deadZoneHeight: 32), 32)
        XCTAssertEqual(ExpandedPanelLayout.headerTopInset(width: 160, deadZoneWidth: 0, deadZoneHeight: 0), 0)
    }

    func testNarrowPanelsUseOneColumnAndFourWidgetsUseTwoBalancedColumns() {
        XCTAssertEqual(ExpandedPanelLayout.columnCount(width: 160, widgetCount: 4), 1)
        XCTAssertEqual(ExpandedPanelLayout.columnCount(width: 460, widgetCount: 4), 1)
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
        // 16pt 外边距 + 3 × (200pt 内容 + 24pt 组件内边距) + 2 × 8pt 列间距。
        XCTAssertEqual(ExpandedPanelLayout.columnCount(width: 704, widgetCount: 3), 3)
        XCTAssertEqual(ExpandedPanelLayout.columnCount(width: 703.5, widgetCount: 3), 2)
    }

    func testAutomaticWidthFitsWidgetCountsAndMediaDetailWithoutOverridingManualWidth() {
        for (count, expected) in [(0, 400.0), (1, 400.0), (2, 640.0), (3, 800.0), (4, 800.0)] {
            XCTAssertEqual(ExpandedPanelLayout.width(preferred: 800, available: 1200,
                automaticallyFit: true, widgetCount: count, selectedWidget: nil), expected)
            XCTAssertEqual(ExpandedPanelLayout.width(preferred: 800, available: 1200,
                automaticallyFit: false, widgetCount: count, selectedWidget: nil), 800)
        }
        XCTAssertEqual(ExpandedPanelLayout.width(preferred: 800, available: 1200,
            automaticallyFit: true, widgetCount: 3, selectedWidget: .media), 460)
        XCTAssertEqual(ExpandedPanelLayout.width(preferred: 800, available: 1200,
            automaticallyFit: false, widgetCount: 3, selectedWidget: .media), 800)
        XCTAssertEqual(ExpandedPanelLayout.width(preferred: 320, available: 1200,
            automaticallyFit: true, widgetCount: 3, selectedWidget: .media), 320)
        XCTAssertEqual(ExpandedPanelLayout.width(preferred: 800, available: 120,
            automaticallyFit: true, widgetCount: 3, selectedWidget: nil), 120)
        XCTAssertEqual(ExpandedPanelLayout.width(preferred: .nan, available: .infinity,
            automaticallyFit: true, widgetCount: 3, selectedWidget: nil), 800)
    }

    func testMediaReceivesExtraSpaceWithoutSqueezingOtherColumns() {
        for mediaColumn in 0..<3 {
            let widths = ExpandedPanelLayout.columnWidths(contentWidth: 784, columns: 3,
                emphasizedColumn: mediaColumn)
            XCTAssertEqual(widths.reduce(0, +) + 16, 784, accuracy: 0.01)
            XCTAssertGreaterThanOrEqual(widths[mediaColumn], 310)
            for column in 0..<3 where column != mediaColumn {
                XCTAssertGreaterThanOrEqual(widths[column], 224)
            }
        }
        XCTAssertEqual(ExpandedPanelLayout.columnWidths(contentWidth: 688, columns: 3,
            emphasizedColumn: 0), [224, 224, 224])
        XCTAssertEqual(ExpandedPanelLayout.columnWidths(contentWidth: 784, columns: 2,
            emphasizedColumn: nil), [388, 388])
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
        XCTAssertEqual(ExpandedPanelLayout.maximumHeight(availableHeight: 900, automaticallyFit: false, manualMaxHeight: 1), 42)
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
        let overview = ExpandedPanelMeasurement(width: 800, height: 520, selectedWidget: nil, enabledWidgets: enabledWidgets)
        let detail = ExpandedPanelMeasurement(width: 800, height: 720, selectedWidget: .notes, enabledWidgets: enabledWidgets)

        XCTAssertTrue(overview.matches(width: 800.1, selectedWidget: nil, enabledWidgets: enabledWidgets))
        XCTAssertFalse(overview.matches(width: 800.5, selectedWidget: nil, enabledWidgets: enabledWidgets))
        XCTAssertFalse(overview.matches(width: 600, selectedWidget: nil, enabledWidgets: enabledWidgets))
        XCTAssertFalse(overview.matches(width: 800, selectedWidget: .notes, enabledWidgets: enabledWidgets))
        XCTAssertTrue(detail.matches(width: 800, selectedWidget: .notes, enabledWidgets: enabledWidgets))
        XCTAssertFalse(detail.matches(width: 800, selectedWidget: .calendar, enabledWidgets: enabledWidgets))
    }

    func testMeasurementRejectsPreviousWidgetConfigurationEvenAtEqualHeight() {
        let originalWidgets: [NotchContentView.WidgetType] = [.media, .calendar, .tray]
        let previous = ExpandedPanelMeasurement(width: 800, height: 326, selectedWidget: nil,
            enabledWidgets: originalWidgets)
        let configurations: [[NotchContentView.WidgetType]] = [
            [.media, .calendar], [.media, .calendar, .notes], [.tray, .calendar, .media], []
        ]
        for nextWidgets in configurations {
            let next = ExpandedPanelMeasurement(width: 800, height: 326, selectedWidget: nil,
                enabledWidgets: nextWidgets)
            XCTAssertFalse(previous.matches(width: 800, selectedWidget: nil, enabledWidgets: nextWidgets))
            XCTAssertTrue(next.matches(width: 800, selectedWidget: nil, enabledWidgets: nextWidgets))
            XCTAssertTrue(next.differs(from: previous))
            XCTAssertNotEqual(next, previous, "组件变化必须触发 SwiftUI preference 的新回调")
        }
    }

    func testInvalidMeasurementsCannotReplaceValidDimensions() {
        let invalidValues: [CGFloat] = [.nan, .infinity, -.infinity, 0, -1]
        for value in invalidValues {
            XCTAssertFalse(ExpandedPanelMeasurement(width: value, height: 520, selectedWidget: nil, enabledWidgets: enabledWidgets).matches(width: 800, selectedWidget: nil, enabledWidgets: enabledWidgets))
            XCTAssertFalse(ExpandedPanelMeasurement(width: 800, height: value, selectedWidget: nil, enabledWidgets: enabledWidgets).matches(width: 800, selectedWidget: nil, enabledWidgets: enabledWidgets))
        }
    }

    func testMeasurementsIgnoreSubpixelNoiseButAcceptContentAndModeChanges() {
        let previous = ExpandedPanelMeasurement(width: 800, height: 520, selectedWidget: nil, enabledWidgets: enabledWidgets)
        XCTAssertFalse(ExpandedPanelMeasurement(width: 800, height: 520.4, selectedWidget: nil, enabledWidgets: enabledWidgets).differs(from: previous))
        XCTAssertTrue(ExpandedPanelMeasurement(width: 800, height: 521, selectedWidget: nil, enabledWidgets: enabledWidgets).differs(from: previous))
        XCTAssertTrue(ExpandedPanelMeasurement(width: 800, height: 520, selectedWidget: .notes, enabledWidgets: enabledWidgets).differs(from: previous))
        XCTAssertTrue(previous.differs(from: nil))
    }
}
