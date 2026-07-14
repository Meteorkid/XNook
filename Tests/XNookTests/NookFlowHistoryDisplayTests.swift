import XCTest
@testable import XNook

final class NookFlowHistoryDisplayTests: XCTestCase {
    func testExpandedPanelHeightHonorsConfiguredBaseHeight() {
        let height = IslandSizeCalculator.expandedPanelShapeHeight(
            visibleSessionCount: 0,
            focusSessionCardHeight: 0,
            panelBaseHeight: 400
        )

        XCTAssertEqual(height, 400, accuracy: 0.001)
    }

    func testTargetSizeAllowsContentToExceedPanelBaseHeight() {
        let contentHeight = IslandSizeCalculator.expandedPanelShapeHeight(
            visibleSessionCount: 4,
            focusSessionCardHeight: FocusSessionView.historyListHeight(for: 5)
        )
        let target = IslandSizeCalculator.targetSize(
            for: .expanded,
            visibleSessionCount: 4,
            panelWidth: 600,
            focusSessionCardHeight: FocusSessionView.historyListHeight(for: 5),
            panelBaseHeight: 400
        )

        XCTAssertEqual(target.height, contentHeight, accuracy: 0.001)
    }

    func testPanelBaseHeightUsesDefault() {
        XCTAssertEqual(SettingsDefaults.double(for: "panelBaseHeight"), 400, accuracy: 0.001)
    }

    func testHistoryDisplayLimitUsesDefaultAndClampsToSupportedRange() {
        XCTAssertEqual(FocusSessionView.sanitizedHistoryDisplayLimit(0), 1)
        XCTAssertEqual(FocusSessionView.sanitizedHistoryDisplayLimit(1), 1)
        XCTAssertEqual(FocusSessionView.sanitizedHistoryDisplayLimit(3), 3)
        XCTAssertEqual(FocusSessionView.sanitizedHistoryDisplayLimit(5), 5)
        XCTAssertEqual(FocusSessionView.sanitizedHistoryDisplayLimit(6), 5)
        XCTAssertEqual(SettingsDefaults.int(for: "nookFlowHistoryDisplayLimit"), 3)
    }

    func testRecentTaskHistoryIsShownByDefault() {
        XCTAssertTrue(SettingsDefaults.bool(for: "showNookFlowHistory"))
    }

    func testHistoryListHeightAddsExactlyOneRowForEachVisibleRecord() {
        let oneRecordHeight = FocusSessionView.historyListHeight(for: 1)
        let threeRecordHeight = FocusSessionView.historyListHeight(for: 3)
        let fiveRecordHeight = FocusSessionView.historyListHeight(for: 5)

        XCTAssertEqual(
            threeRecordHeight - oneRecordHeight,
            FocusSessionView.historyRowHeight * 2,
            accuracy: 0.001
        )
        XCTAssertEqual(
            fiveRecordHeight - threeRecordHeight,
            FocusSessionView.historyRowHeight * 2,
            accuracy: 0.001
        )
    }

    func testExpandedPanelHeightTracksVisibleHistoryRowsWithoutClippingWidgets() {
        let oneRecordPanelHeight = IslandSizeCalculator.expandedPanelShapeHeight(
            visibleSessionCount: 0,
            focusSessionCardHeight: FocusSessionView.historyListHeight(for: 1)
        )
        let fiveRecordPanelHeight = IslandSizeCalculator.expandedPanelShapeHeight(
            visibleSessionCount: 0,
            focusSessionCardHeight: FocusSessionView.historyListHeight(for: 5)
        )

        XCTAssertEqual(
            fiveRecordPanelHeight - oneRecordPanelHeight,
            FocusSessionView.historyRowHeight * 4,
            accuracy: 0.001
        )

        let requiredHeight = IslandSizeCalculator.expandedPanelShapeHeight(
            visibleSessionCount: 4,
            focusSessionCardHeight: FocusSessionView.historyListHeight(for: 5)
        )

        XCTAssertEqual(
            IslandSizeCalculator.expandedPanelShapeHeight(
                visibleSessionCount: 4,
                focusSessionCardHeight: FocusSessionView.historyListHeight(for: 5)
            ),
            requiredHeight,
            accuracy: 0.001
        )
    }
}
