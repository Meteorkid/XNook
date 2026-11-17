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

    func testCompletingUnchangedDefaultDoesNotPersistOrDisableContentFitting() {
        let store = store(), editor = PanelLayoutEditingSession()
        editor.begin(from: store)
        XCTAssertFalse(editor.hasChanges)
        XCTAssertTrue(editor.save(to: store))
        XCTAssertFalse(editor.isEditing)
        XCTAssertFalse(editor.hasChanges)
        XCTAssertNil(store.defaults.object(forKey: PanelLayoutStore.storageKey))
        XCTAssertFalse(store.hasSavedConfiguration)
        XCTAssertTrue(store.shouldFitDefaultContent(automaticallyFit: true))
    }

    func testChangingThenRestoringOriginalDraftFinishesWithoutWriting() {
        let store = store(), editor = PanelLayoutEditingSession()
        editor.begin(from: store)
        let initial = editor.draft
        editor.draft.resize(.media, columns: 8, rows: 6)
        XCTAssertTrue(editor.hasChanges)
        editor.draft = initial
        XCTAssertFalse(editor.hasChanges)
        XCTAssertTrue(editor.save(to: store))
        XCTAssertNil(store.defaults.object(forKey: PanelLayoutStore.storageKey))
    }

    func testCompletingUnchangedCustomLayoutPreservesStoredBytes() throws {
        let store = store(), editor = PanelLayoutEditingSession()
        var initial = store.configuration
        initial.resize(.media, columns: 8, rows: 6)
        try store.save(initial)
        let originalBytes = try XCTUnwrap(store.defaults.data(forKey: PanelLayoutStore.storageKey))
        editor.begin(from: store)
        XCTAssertFalse(editor.hasChanges)
        XCTAssertTrue(editor.save(to: store))
        XCTAssertEqual(store.defaults.data(forKey: PanelLayoutStore.storageKey), originalBytes)
        XCTAssertTrue(store.hasSavedConfiguration)
    }

    func testUnchangedCompletionRefreshesExternalChangesWithoutOverwritingThem() throws {
        let store = store(), editor = PanelLayoutEditingSession()
        editor.begin(from: store)
        var elsewhere = store.configuration
        elsewhere.setVisible(.calendar, visible: false)
        try PanelLayoutStore(defaults: store.defaults).save(elsewhere)
        let originalBytes = store.defaults.data(forKey: PanelLayoutStore.storageKey)
        XCTAssertTrue(editor.save(to: store))
        XCTAssertFalse(editor.isEditing)
        XCTAssertEqual(store.configuration, elsewhere)
        XCTAssertEqual(store.defaults.data(forKey: PanelLayoutStore.storageKey), originalBytes)
    }

    func testHideAndRestoreModuleRemainDraftOnlyUntilSaving() throws {
        let store = store(), editor = PanelLayoutEditingSession()
        editor.begin(from: store)
        editor.draft.setVisible(.tray, visible: false)
        XCTAssertTrue(editor.hasChanges)
        XCTAssertFalse(editor.draft.visibleItems.contains { $0.id == .tray })
        editor.draft.setVisible(.tray, visible: true)
        XCTAssertTrue(editor.draft.visibleItems.contains { $0.id == .tray })
        try editor.draft.validate()
        XCTAssertNil(store.defaults.object(forKey: PanelLayoutStore.storageKey))
        editor.cancel()
        XCTAssertFalse(editor.hasChanges)
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

    func testEditingKeepsSavedCoordinatesAtNarrowMediaProjectionBreakpoint() throws {
        var initial = PanelLayoutConfiguration.legacy(enabledWidgetIDs: ["media", "calendar", "tray"], showHistory: true)
        initial.move(.media, column: 8, row: 8)
        for width: CGFloat in [752, 756] {
            let editingFrames = PanelGridGeometry.frames(for: initial, width: width, isEditing: true)
            let frame = try XCTUnwrap(editingFrames[.media])
            let pitch = (width + PanelGridGeometry.spacing) / 12
            XCTAssertEqual(frame.minX, 8 * pitch, accuracy: 0.001)
            XCTAssertEqual(frame.minY, 8 * (PanelGridGeometry.rowHeight + PanelGridGeometry.spacing))
            XCTAssertEqual(frame.height, 184)
            XCTAssertEqual(PanelGridGeometry.height(for: initial, width: width, isEditing: true), editingFrames.values.map(\.maxY).max())

            let moved = PanelLayoutDragUpdate.configuration(from: initial, id: .media,
                translation: CGSize(width: -pitch, height: 0), resizing: false, width: width)
            let movedFrame = try XCTUnwrap(PanelGridGeometry.frames(for: moved, width: width, isEditing: true)[.media])
            XCTAssertEqual(movedFrame.minX, frame.minX - pitch, accuracy: 0.001)
            XCTAssertEqual(movedFrame.minY, frame.minY)
            XCTAssertEqual(moved.items.first { $0.id == .media }?.column, 7)
            try moved.validate()
        }
    }

    func testMeasurementRejectsOldLayoutEvenIfHeightMatches() {
        var initial = PanelLayoutConfiguration.factoryDefault
        let height = PanelGridGeometry.height(for: initial, width: 800)
        let measurement = ExpandedPanelMeasurement(width: 800, height: height, selectedWidget: nil, enabledWidgets: [.media], layoutSignature: initial.signature)
        initial.move(.media, column: 6, row: 0)
        XCTAssertNotEqual(initial.signature, measurement.layoutSignature)
        XCTAssertEqual(PanelGridGeometry.height(for: initial, width: 800), height)
        XCTAssertFalse(measurement.matches(width: 800, selectedWidget: nil, enabledWidgets: [.media], layoutSignature: initial.signature))
        XCTAssertTrue(ExpandedPanelMeasurement(width: 800, height: height, selectedWidget: nil, enabledWidgets: [.media], layoutSignature: initial.signature).differs(from: measurement))
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
