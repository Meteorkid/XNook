import XCTest
@testable import XNook

final class NookFlowHistoryDisplayTests: XCTestCase {
    func testExpandedPanelHeightFitsContentWhenBelowCap() {
        // 内容不足上限时按实际内容高度展开，与 X Island 一致
        let height = IslandSizeCalculator.expandedPanelShapeHeight(
            visibleSessionCount: 0,
            focusSessionCardHeight: 0,
            panelBaseHeight: 400
        )

        // calculatedHeight = 48(头部) + 0 + 30(空列表) + 16(底部) = 94
        XCTAssertEqual(height, 94, accuracy: 0.001)
    }

    func testTargetSizeUsesConfiguredHeightWhenContentOverflows() {
        let target = IslandSizeCalculator.targetSize(
            for: .expanded,
            visibleSessionCount: 4,
            panelWidth: 600,
            focusSessionCardHeight: FocusSessionView.historyListHeight(for: 5),
            panelBaseHeight: 400
        )

        XCTAssertEqual(target.height, 400, accuracy: 0.001)
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

    func testExpandedPanelHeightCapsAtConfiguredMaximum() {
        // 内容超过上限时裁切到 panelBaseHeight
        let height = IslandSizeCalculator.expandedPanelShapeHeight(
            visibleSessionCount: 4,
            focusSessionCardHeight: FocusSessionView.historyListHeight(for: 5),
            panelBaseHeight: 200
        )

        XCTAssertEqual(height, 200, accuracy: 0.001)
    }

    @MainActor
    func testPanelHeightMaximumRespectsScreenHeightAndHardLimit() {
        // screenHeight(700) - expandedPadding(8) - windowTopExtension(4) = 688
        XCTAssertEqual(NotchWindow.maximumExpandedContentHeight(forScreenHeight: 700), 688, accuracy: 0.001)
        XCTAssertEqual(NotchWindow.maximumExpandedContentHeight(forScreenHeight: 2_000), 900, accuracy: 0.001)
    }

    @MainActor
    func testPanelWidthMaximumRespectsScreenWidthAndHardLimit() {
        XCTAssertEqual(NotchWindow.maximumExpandedContentWidth(forScreenWidth: 700), 684, accuracy: 0.001)
        XCTAssertEqual(NotchWindow.maximumExpandedContentWidth(forScreenWidth: 2_000), 1_600, accuracy: 0.001)
    }
}
