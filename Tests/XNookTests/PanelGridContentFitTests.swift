import CoreGraphics
import XCTest
@testable import XNook

final class PanelGridContentFitTests: XCTestCase {
    func testEveryDefaultCombinationFitsNaturalRowHeightsWithoutChangingColumnsOrInput() {
        let primary: [PanelModuleID] = [.media, .calendar, .tray, .notes]
        let heights: [PanelModuleID: CGFloat] = [.media: 156, .calendar: 132, .tray: 88,
            .notes: 120, .currentTask: 80, .recentTasks: 88]
        for mask in 0..<16 {
            for history in [false, true] {
                let enabled = Set(primary.enumerated().compactMap { index, id in
                    mask & (1 << index) == 0 ? nil : id.rawValue
                })
                let configuration = PanelLayoutConfiguration.legacy(enabledWidgetIDs: enabled, showHistory: history)
                let original = configuration
                for width: CGFloat in [144, 304, 504, 505, 600, 751, 752, 784, 984] {
                    let base = PanelGridGeometry.frames(for: configuration, width: width, isEditing: true)
                    let fitted = PanelGridGeometry.contentFittedFrames(for: configuration, width: width, measuredHeights: heights)
                    XCTAssertEqual(configuration, original)
                    XCTAssertEqual(Set(fitted.keys), Set(base.keys))
                    assertValid(fitted, width: width)
                    for (id, frame) in fitted {
                        XCTAssertEqual(frame.minX, base[id]?.minX)
                        XCTAssertEqual(frame.width, base[id]?.width)
                        XCTAssertGreaterThanOrEqual(frame.height, heights[id]!)
                        for (otherID, other) in base where other.minY == base[id]?.minY {
                            XCTAssertEqual(fitted[otherID]?.minY, frame.minY)
                            XCTAssertEqual(fitted[otherID]?.height, frame.height)
                        }
                    }
                    let lastPrimary = fitted.filter { primary.contains($0.key) }.values.map(\.maxY).max() ?? -8
                    XCTAssertEqual(fitted[.currentTask]?.minY, lastPrimary + 8)
                    if history {
                        XCTAssertEqual(fitted[.recentTasks]?.minY, fitted[.currentTask]!.maxY + 8)
                    }
                }
            }
        }
    }

    func testThreeEmptyPrimaryCardsStaySideBySideAndTasksRemainBelow() throws {
        let configuration = PanelLayoutConfiguration.legacy(enabledWidgetIDs: ["media", "calendar", "tray"], showHistory: true)
        let fitted = PanelGridGeometry.contentFittedFrames(for: configuration, width: 784,
            measuredHeights: [.media: 156, .calendar: 132, .tray: 88, .currentTask: 80, .recentTasks: 88])
        for id in [PanelModuleID.media, .calendar, .tray] {
            XCTAssertEqual(fitted[id]?.minY, 0)
            XCTAssertEqual(fitted[id]?.height, 156)
        }
        XCTAssertEqual(fitted[.currentTask]?.minY, 164)
        XCTAssertEqual(fitted[.recentTasks]?.minY, 252)
        XCTAssertEqual(fitted.values.map(\.maxY).max(), 340)
        XCTAssertEqual(PanelGridGeometry.height(for: configuration, width: 784), 472)
    }

    func testNarrowMediaAndLongErrorContentCanGrowBeyondOriginalGrid() {
        let configuration = PanelLayoutConfiguration.legacy(enabledWidgetIDs: ["media", "calendar"], showHistory: true)
        let heights: [PanelModuleID: CGFloat] = [.media: 390.2, .calendar: 512.4, .currentTask: 180.3, .recentTasks: 220.5]
        for width: CGFloat in [128, 144, 600] {
            let fitted = PanelGridGeometry.contentFittedFrames(for: configuration, width: width, measuredHeights: heights)
            assertValid(fitted, width: width)
            for (id, height) in heights { XCTAssertGreaterThanOrEqual(fitted[id]!.height, ceil(height)) }
            XCTAssertGreaterThan(fitted[.recentTasks]!.minY, fitted[.currentTask]!.minY)
        }
    }

    func testInvalidMeasurementsFallBackToExistingMediaSafetyAndDoNotProduceInvalidFrames() {
        let configuration = PanelLayoutConfiguration.legacy(enabledWidgetIDs: ["media"], showHistory: true)
        for width: CGFloat in [128, 144, 240, 784] {
            let fallback = PanelGridGeometry.frames(for: configuration, width: width)
            for invalid: CGFloat in [0, -1, .nan, .infinity, -.infinity] {
                let fitted = PanelGridGeometry.contentFittedFrames(for: configuration, width: width,
                    measuredHeights: [.media: invalid])
                XCTAssertEqual(fitted[.media]?.height, fallback[.media]?.height)
                assertValid(fitted, width: width)
            }
        }
        for invalidWidth: CGFloat in [0, -1, .nan, .infinity] {
            XCTAssertTrue(PanelGridGeometry.contentFittedFrames(for: configuration,
                width: invalidWidth, measuredHeights: [.media: 100]).isEmpty)
        }
        XCTAssertEqual(PanelGridGeometry.contentFittedFrames(for: configuration, width: 784,
            measuredHeights: [.media: .greatestFiniteMagnitude, .currentTask: .greatestFiniteMagnitude]),
            PanelGridGeometry.frames(for: configuration, width: 784))
    }

    func testCrossRowCustomShapesAreNeverCollapsedIntoOverlappingBands() {
        var custom = PanelLayoutConfiguration.factoryDefault
        custom.resize(.media, columns: 6, rows: 8)
        let fallback = PanelGridGeometry.frames(for: custom, width: 784)
        let fitted = PanelGridGeometry.contentFittedFrames(for: custom, width: 784,
            measuredHeights: Dictionary(uniqueKeysWithValues: PanelModuleID.allCases.map { ($0, CGFloat(44)) }))
        XCTAssertEqual(fitted, fallback)
    }

    func testMeasurementModeChangesIdentityWithoutChangingSavedSignature() {
        let configuration = PanelLayoutConfiguration.factoryDefault
        let fixed = PanelGridGeometry.measurementSignature(for: configuration, fitsContent: false)
        let fitted = PanelGridGeometry.measurementSignature(for: configuration, fitsContent: true)
        XCTAssertEqual(fixed, configuration.signature)
        XCTAssertEqual(fitted, configuration.signature + "|contentFit=1")
        XCTAssertNotEqual(fixed, fitted)
        let measured = ExpandedPanelMeasurement(width: 800, height: 500, selectedWidget: nil,
            enabledWidgets: [.media], layoutSignature: fitted)
        XCTAssertTrue(measured.matches(width: 800, selectedWidget: nil, enabledWidgets: [.media], layoutSignature: fitted))
        XCTAssertFalse(measured.matches(width: 800, selectedWidget: nil, enabledWidgets: [.media], layoutSignature: fixed))
    }

    private func assertValid(_ frames: [PanelModuleID: CGRect], width: CGFloat,
                             file: StaticString = #filePath, line: UInt = #line) {
        for (id, frame) in frames {
            XCTAssertTrue(frame.minY.isFinite && frame.height.isFinite, "\(id)", file: file, line: line)
            XCTAssertGreaterThanOrEqual(frame.minX, 0, file: file, line: line)
            XCTAssertGreaterThanOrEqual(frame.minY, 0, file: file, line: line)
            XCTAssertGreaterThan(frame.width, 0, file: file, line: line)
            XCTAssertGreaterThanOrEqual(frame.height, 44, file: file, line: line)
            XCTAssertLessThanOrEqual(frame.maxX, width + 0.01, file: file, line: line)
            for (otherID, other) in frames where id != otherID {
                XCTAssertFalse(frame.insetBy(dx: 0.1, dy: 0.1).intersects(other), "\(id)/\(otherID)", file: file, line: line)
            }
        }
    }
}
