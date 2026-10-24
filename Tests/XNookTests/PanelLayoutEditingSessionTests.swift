import XCTest
@testable import XNook

@MainActor
final class PanelLayoutEditingSessionTests: XCTestCase {
    private func store() -> PanelLayoutStore {
        let name = "xnook.tests.grid-edit.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return PanelLayoutStore(defaults: defaults)
    }

    func testCancelAndDefaultDraftNeverWritePreferences() {
        let store = store(), editor = PanelLayoutEditingSession()
        editor.begin(from: store)
        editor.draft.move(.calendar, column: 0, row: 12)
        editor.draft.setVisible(.tray, visible: false)
        editor.restoreDefault()
        editor.cancel()
        XCTAssertFalse(editor.isEditing)
        XCTAssertNil(store.defaults.object(forKey: PanelLayoutStore.storageKey))
    }

    func testRepeatedBeginPreservesUncommittedDraft() {
        let store = store(), editor = PanelLayoutEditingSession()
        editor.begin(from: store)
        editor.draft.resize(.media, columns: 8, rows: 6)
        let draft = editor.draft
        editor.begin(from: store)
        XCTAssertEqual(editor.draft, draft)
        XCTAssertNil(store.defaults.object(forKey: PanelLayoutStore.storageKey))
    }

    func testSavePersistsWholeDraftAndRestartKeepsIt() {
        let store = store(), editor = PanelLayoutEditingSession()
        editor.begin(from: store)
        editor.draft.move(.notes, column: 6, row: 20)
        editor.draft.setVisible(.tray, visible: false)
        let expected = editor.draft
        XCTAssertTrue(editor.save(to: store))
        XCTAssertFalse(editor.isEditing)
        XCTAssertEqual(PanelLayoutStore(defaults: store.defaults).configuration, expected)
        XCTAssertNil(store.defaults.data(forKey: "enabledWidgets"))
    }

    func testExternalChangeCannotBeOverwrittenByOldDraft() throws {
        let store = store(), editor = PanelLayoutEditingSession()
        editor.begin(from: store)
        editor.draft.resize(.media, columns: 8, rows: 6)
        var elsewhere = store.configuration
        elsewhere.setVisible(.calendar, visible: false)
        try PanelLayoutStore(defaults: store.defaults).save(elsewhere)
        XCTAssertFalse(editor.save(to: store))
        XCTAssertTrue(editor.isEditing)
        XCTAssertNotNil(editor.errorMessage)
        XCTAssertEqual(PanelLayoutStore(defaults: store.defaults).configuration, elsewhere)
    }

    func testCorruptConfigurationBlocksEditingAndIsNotOverwritten() {
        let store = store(), editor = PanelLayoutEditingSession()
        let raw = Data("bad".utf8)
        store.defaults.set(raw, forKey: PanelLayoutStore.storageKey)
        editor.begin(from: store)
        XCTAssertFalse(editor.isEditing)
        XCTAssertEqual(store.defaults.data(forKey: PanelLayoutStore.storageKey), raw)
    }

    func testMediumWidthHorizontalDragCanSwapBothColumns() {
        let initial = PanelLayoutConfiguration.legacy(enabledWidgetIDs: ["media", "calendar"], showHistory: false)
        let frames = PanelGridGeometry.frames(for: initial, width: 600)
        let delta = frames[.calendar]!.midX - frames[.media]!.midX
        let right = PanelLayoutDragUpdate.configuration(from: initial, id: .media, translation: CGSize(width: delta, height: 0), resizing: false, width: 600)
        XCTAssertEqual(right.visibleItems.first?.id, .calendar)
        let left = PanelLayoutDragUpdate.configuration(from: initial, id: .calendar, translation: CGSize(width: -delta, height: 0), resizing: false, width: 600)
        XCTAssertEqual(left.visibleItems.first?.id, .calendar)
        XCTAssertEqual(left.items.first { $0.id == .calendar }?.columns, 6)
    }

    func testResizeIsSnappedAndInvalidGestureDoesNotMutate() throws {
        let initial = PanelLayoutConfiguration.factoryDefault
        let resized = PanelLayoutDragUpdate.configuration(from: initial, id: .media, translation: CGSize(width: 300, height: 200), resizing: true, width: 800)
        XCTAssertNotEqual(resized, initial)
        try resized.validate()
        XCTAssertEqual(PanelLayoutDragUpdate.configuration(from: initial, id: .media, translation: CGSize(width: CGFloat.nan, height: 0), resizing: false, width: 800), initial)
    }

    func testMeasurementRejectsOldLayoutEvenIfHeightMatches() {
        var initial = PanelLayoutConfiguration.factoryDefault
        let measurement = ExpandedPanelMeasurement(width: 800, height: 600, selectedWidget: nil, enabledWidgets: [.media], layoutSignature: initial.signature)
        initial.resize(.media, columns: 6, rows: 4)
        XCTAssertFalse(measurement.matches(width: 800, selectedWidget: nil, enabledWidgets: [.media], layoutSignature: initial.signature))
        XCTAssertTrue(ExpandedPanelMeasurement(width: 800, height: 600, selectedWidget: nil, enabledWidgets: [.media], layoutSignature: initial.signature).differs(from: measurement))
    }
    func testEditingMeasurementIsDistinctEvenWhenGeometryAndLayoutAreEqual() {
        let normal = ExpandedPanelMeasurement(width: 800, height: 600, selectedWidget: nil, enabledWidgets: [.media], layoutSignature: "same")
        var editing = normal
        editing.isEditingLayout = true
        XCTAssertTrue(editing.differs(from: normal))
        XCTAssertFalse(editing.matches(width: 800, selectedWidget: nil, enabledWidgets: [.media], layoutSignature: "same"))
        XCTAssertTrue(editing.matches(width: 800, selectedWidget: nil, enabledWidgets: [.media], layoutSignature: "same", isEditingLayout: true))
    }

}
