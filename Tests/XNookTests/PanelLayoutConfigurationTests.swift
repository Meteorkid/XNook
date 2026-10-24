import CoreGraphics
import XCTest
@testable import XNook

final class PanelLayoutConfigurationTests: XCTestCase {
    func testLegacyLayoutsCompactOneTwoAndThreePrimaryModules() throws {
        let modules: [PanelModuleID] = [.media, .calendar, .tray]
        for count in 1...3 {
            let enabled = Set(modules.prefix(count).map(\.rawValue))
            let configuration = PanelLayoutConfiguration.legacy(enabledWidgetIDs: enabled, showHistory: true)
            try configuration.validate()
            let primary = configuration.visibleItems.filter { enabled.contains($0.id.rawValue) }
            XCTAssertEqual(primary.count, count)
            XCTAssertEqual(primary.map(\.columns), Array(repeating: 12 / count, count: count))
            XCTAssertEqual(primary.map(\.row), Array(repeating: 0, count: count))
            XCTAssertEqual(primary.map(\.column), (0..<count).map { $0 * (12 / count) })
        }
    }

    func testFourPrimaryModulesKeepNotesBesideIndependentTaskCards() throws {
        let configuration = PanelLayoutConfiguration.factoryDefault
        try configuration.validate()
        for (index, id) in [PanelModuleID.media, .calendar, .tray].enumerated() {
            XCTAssertEqual(item(id, in: configuration), .init(id: id, column: index * 4, row: 0,
                                                              columns: 4, rows: 4, isVisible: true))
        }
        XCTAssertEqual(item(.notes, in: configuration), .init(id: .notes, column: 0, row: 4,
                                                              columns: 4, rows: 6, isVisible: true))
        XCTAssertEqual(item(.currentTask, in: configuration), .init(id: .currentTask, column: 4, row: 4,
                                                                    columns: 8, rows: 3, isVisible: true))
        XCTAssertEqual(item(.recentTasks, in: configuration), .init(id: .recentTasks, column: 4, row: 7,
                                                                    columns: 8, rows: 3, isVisible: true))
    }

    func testEveryVisibilityCombinationIsValidAndRetainsAllModules() throws {
        for mask in 0..<64 {
            var configuration = PanelLayoutConfiguration.factoryDefault
            for (index, id) in PanelModuleID.allCases.enumerated() {
                configuration.setVisible(id, visible: mask & (1 << index) != 0)
            }
            try configuration.validate()
            XCTAssertEqual(configuration.items.count, 6)
            XCTAssertEqual(configuration.visibleItems.count, mask.nonzeroBitCount)
            for width in [CGFloat(200), 504, 600, 751, 752, 800, 1600] {
                assertFramesValid(PanelGridGeometry.frames(for: configuration, width: width), width: width)
            }
        }
    }

    func testHiddenModulesRetainTheirSavedPlacement() {
        var configuration = PanelLayoutConfiguration.factoryDefault
        let original = item(.notes, in: configuration)
        configuration.setVisible(.notes, visible: false)
        var expected = original
        expected.isVisible = false
        XCTAssertEqual(item(.notes, in: configuration), expected)
        configuration.setVisible(.notes, visible: true)
        XCTAssertEqual(item(.notes, in: configuration), original)
    }

    func testHidingAllPrimaryModulesMovesTaskCardsToFirstRowWithoutResizing() throws {
        var configuration = PanelLayoutConfiguration.factoryDefault
        for id in [PanelModuleID.media, .calendar, .tray, .notes] {
            configuration.setVisible(id, visible: false)
        }

        try configuration.validate()
        XCTAssertEqual(item(.currentTask, in: configuration), .init(id: .currentTask, column: 0, row: 0,
                                                                    columns: 8, rows: 3, isVisible: true))
        XCTAssertEqual(item(.recentTasks, in: configuration), .init(id: .recentTasks, column: 0, row: 3,
                                                                    columns: 8, rows: 3, isVisible: true))
        let frames = PanelGridGeometry.frames(for: configuration, width: 800)
        XCTAssertEqual(frames[.currentTask]?.minY, 0)
        XCTAssertEqual(frames[.recentTasks]?.minY, 144)
        XCTAssertEqual(PanelGridGeometry.height(for: configuration, width: 800), 280)
    }

    func testHidingOtherModulesDoesNotChangeHiddenPlacementOrVisibleDimensions() throws {
        var configuration = PanelLayoutConfiguration.factoryDefault
        configuration.move(.notes, column: 6, row: 25)
        configuration.resize(.notes, columns: 6, rows: 8)
        configuration.setVisible(.notes, visible: false)
        let hidden = item(.notes, in: configuration)
        let sizes = Dictionary(uniqueKeysWithValues: configuration.items.map { ($0.id, [$0.columns, $0.rows]) })

        for id in [PanelModuleID.media, .calendar, .tray] {
            configuration.setVisible(id, visible: false)
            XCTAssertEqual(item(.notes, in: configuration), hidden)
            for placement in configuration.items {
                XCTAssertEqual([placement.columns, placement.rows], sizes[placement.id])
            }
            try configuration.validate()
        }
        configuration.setVisible(.notes, visible: true)
        var visible = hidden
        visible.isVisible = true
        XCTAssertEqual(item(.notes, in: configuration), visible)
        try configuration.validate()
    }

    func testMoveAndResizeGiveEditedModulePriority() throws {
        var configuration = PanelLayoutConfiguration.factoryDefault
        configuration.move(.calendar, column: 0, row: 0)
        XCTAssertEqual(item(.calendar, in: configuration).column, 0)
        XCTAssertEqual(item(.calendar, in: configuration).row, 0)
        XCTAssertNotEqual(item(.media, in: configuration).column, 0)
        try configuration.validate()
        configuration.resize(.calendar, columns: 8, rows: 8)
        XCTAssertEqual(item(.calendar, in: configuration).columns, 8)
        XCTAssertEqual(item(.calendar, in: configuration).rows, 8)
        XCTAssertEqual(item(.calendar, in: configuration).row, 0)
        try configuration.validate()
    }

    func testDeterministicRandomEditsNeverOverlapOrExceedGrid() throws {
        var first = PanelLayoutConfiguration.factoryDefault
        var second = first
        var random = SeededRandom()
        for _ in 0..<1_000 {
            let id = PanelModuleID.allCases[random.next(6)]
            switch random.next(3) {
            case 0:
                let column = random.next(40) - 15
                let row = random.next(100) - 20
                first.move(id, column: column, row: row)
                second.move(id, column: column, row: row)
            case 1:
                let columns = random.next(30) - 8
                let rows = random.next(20) - 5
                first.resize(id, columns: columns, rows: rows)
                second.resize(id, columns: columns, rows: rows)
            default:
                let visible = random.next(2) == 1
                first.setVisible(id, visible: visible)
                second.setVisible(id, visible: visible)
            }
            try first.validate()
            XCTAssertEqual(first, second)
            XCTAssertEqual(first.signature, second.signature)
        }
    }

    func testExtremeInputsNormalizeWithoutOverflow() throws {
        var configuration = PanelLayoutConfiguration.factoryDefault
        configuration.move(.media, column: .max, row: .max)
        configuration.resize(.media, columns: .max, rows: .max)
        XCTAssertEqual(item(.media, in: configuration).columns, 12)
        XCTAssertEqual(item(.media, in: configuration).rows, 8)
        XCTAssertEqual(item(.media, in: configuration).row, 56)
        configuration.move(.calendar, column: .min, row: .min)
        configuration.resize(.calendar, columns: .min, rows: .min)
        XCTAssertEqual(item(.calendar, in: configuration).columns, 4)
        XCTAssertEqual(item(.calendar, in: configuration).rows, 4)
        try configuration.validate()
        configuration.reorder(.recentTasks, offset: .min)
        XCTAssertEqual(configuration.visibleItems.first?.id, .recentTasks)
        configuration.reorder(.recentTasks, offset: .max)
        XCTAssertEqual(configuration.visibleItems.last?.id, .recentTasks)
        try configuration.validate()
    }

    func testFragmentedGridRepacksWithoutMovingNewlyVisiblePriorityModule() throws {
        let rows = [6, 20, 34, 48, 56, 56]
        var configuration = PanelLayoutConfiguration(items: PanelModuleID.allCases.enumerated().map { index, id in
            .init(id: id, column: 0, row: rows[index], columns: 12, rows: 8,
                  isVisible: id != .recentTasks)
        })
        try configuration.validate()
        configuration.setVisible(.recentTasks, visible: true)
        XCTAssertEqual(configuration.visibleItems.count, 6)
        XCTAssertEqual(item(.recentTasks, in: configuration).row, 56)
        try configuration.validate()
    }

    func testReorderChangesVisualOrderAndKeepsHiddenPlacement() throws {
        var configuration = PanelLayoutConfiguration.factoryDefault
        configuration.setVisible(.notes, visible: false)
        let hidden = item(.notes, in: configuration)
        let original = configuration.visibleItems.map(\.id)
        configuration.reorder(.recentTasks, offset: -1)
        var expected = original
        expected.swapAt(expected.count - 1, expected.count - 2)
        XCTAssertEqual(configuration.visibleItems.map(\.id), expected)
        XCTAssertEqual(item(.notes, in: configuration), hidden)
        try configuration.validate()
    }

    func testStrictValidationRejectsIncompleteDuplicateAndUnsafeLayouts() {
        let baseline = PanelLayoutConfiguration.factoryDefault
        var invalid: [PanelLayoutConfiguration] = []
        var missing = baseline
        missing.items.removeLast()
        invalid.append(missing)
        var duplicate = baseline
        duplicate.items[0].id = duplicate.items[1].id
        invalid.append(duplicate)
        let changes: [(inout PanelModulePlacement) -> Void] = [
            { (item: inout PanelModulePlacement) in item.column = -1 },
            { $0.row = Int.max },
            { $0.columns = 5 },
            { $0.rows = 3 },
            { $0.column = 11 },
        ]
        for change in changes {
            var configuration = baseline
            change(&configuration.items[0])
            invalid.append(configuration)
        }
        var overlap = baseline
        overlap.items[1].column = overlap.items[0].column
        invalid.append(overlap)
        var future = baseline
        future.version = 2
        invalid.append(future)
        for configuration in invalid { XCTAssertThrowsError(try configuration.validate()) }
    }

    func testNarrowProjectionPreservesDesktopConfigurationAndVisualOrder() {
        let configuration = PanelLayoutConfiguration.factoryDefault
        let original = configuration
        let narrow = PanelGridGeometry.frames(for: configuration, width: 504)
        XCTAssertEqual(narrow.values.map(\.minX), Array(repeating: 0, count: 6))
        XCTAssertTrue(narrow.values.allSatisfy { $0.width == 504 })
        XCTAssertEqual(narrow.sorted { $0.value.minY < $1.value.minY }.map(\.key), configuration.visibleItems.map(\.id))
        let medium = PanelGridGeometry.frames(for: configuration, width: 700)
        XCTAssertTrue(medium.values.allSatisfy { $0.width >= (700 - 8) / 2 })
        XCTAssertEqual(configuration, original)
        let wide = PanelGridGeometry.frames(for: configuration, width: 800)
        XCTAssertEqual(wide[.media]?.height, 184)
        XCTAssertEqual(wide[.currentTask]?.height, 136)
        XCTAssertEqual(PanelGridGeometry.height(for: configuration, width: 800), 472)
    }

    func testGeometryHandlesEmptyAndInvalidWidths() {
        var configuration = PanelLayoutConfiguration.factoryDefault
        for id in PanelModuleID.allCases { configuration.setVisible(id, visible: false) }
        XCTAssertEqual(PanelGridGeometry.height(for: configuration, width: 800), 0)
        for width in [CGFloat.nan, .infinity, -.infinity, 0, -1] {
            XCTAssertTrue(PanelGridGeometry.frames(for: .factoryDefault, width: width).isEmpty)
            XCTAssertEqual(PanelGridGeometry.height(for: .factoryDefault, width: width), 0)
        }
        assertFramesValid(PanelGridGeometry.frames(for: .factoryDefault, width: 1), width: 1)
    }

    func testRoundTripAndSignatureTrackVisibilityAndPlacement() throws {
        let original = PanelLayoutConfiguration.factoryDefault
        let decoded = try JSONDecoder().decode(PanelLayoutConfiguration.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.signature, original.signature)
        var edited = original
        edited.setVisible(.media, visible: false)
        XCTAssertNotEqual(edited.signature, original.signature)
        edited = original
        edited.move(.media, column: 0, row: 20)
        XCTAssertNotEqual(edited.signature, original.signature)
    }

    private func item(_ id: PanelModuleID, in configuration: PanelLayoutConfiguration) -> PanelModulePlacement {
        configuration.items.first { $0.id == id }!
    }

    private func assertFramesValid(_ frames: [PanelModuleID: CGRect], width: CGFloat,
                                   file: StaticString = #filePath, line: UInt = #line) {
        let rectangles = Array(frames.values)
        for (index, frame) in rectangles.enumerated() {
            XCTAssertGreaterThanOrEqual(frame.minX, 0, file: file, line: line)
            XCTAssertLessThanOrEqual(frame.maxX, width + 0.001, file: file, line: line)
            XCTAssertGreaterThanOrEqual(frame.minY, 0, file: file, line: line)
            for other in rectangles.dropFirst(index + 1) {
                XCTAssertFalse(frame.intersects(other), file: file, line: line)
            }
        }
    }

    private struct SeededRandom {
        var state: UInt64 = 0xC0FFEE

        mutating func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            return Int((state >> 32) % UInt64(bound))
        }
    }
}
