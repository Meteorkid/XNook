import XCTest
@testable import XNook

@MainActor
final class PanelLayoutStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        suiteName = "XNookTests.PanelLayout.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
    }

    func testFirstLoadUsesExistingDefaultsWithoutPersistingMigration() throws {
        let store = PanelLayoutStore(defaults: defaults)
        XCTAssertEqual(store.configuration, .factoryDefault)
        XCTAssertTrue(store.canEdit)
        XCTAssertNil(store.loadError)
        XCTAssertNil(defaults.object(forKey: PanelLayoutStore.storageKey))
        XCTAssertTrue(defaults.persistentDomain(forName: suiteName)?.isEmpty ?? true)
        try store.configuration.validate()
    }

    func testLegacyFlagsAreReadWithoutRewritingOldOrNewKeys() throws {
        let widgets: Set<String> = ["media", "tray"]
        let encodedWidgets = try JSONEncoder().encode(widgets)
        defaults.set(encodedWidgets, forKey: "enabledWidgets")
        defaults.set(false, forKey: "showNookFlowHistory")
        let before = defaults.persistentDomain(forName: suiteName)! as NSDictionary
        let store = PanelLayoutStore(defaults: defaults)
        XCTAssertEqual(store.configuration, .legacy(enabledWidgetIDs: widgets, showHistory: false))
        XCTAssertEqual(store.configuration.visibleItems.map(\.id), [.media, .tray, .currentTask])
        XCTAssertEqual(defaults.persistentDomain(forName: suiteName)! as NSDictionary, before)
        XCTAssertNil(defaults.object(forKey: PanelLayoutStore.storageKey))
    }

    func testEmptyLegacyWidgetsRemainEmptyAndMalformedLegacyDataIsNotOverwritten() throws {
        defaults.set(try JSONEncoder().encode(Set<String>()), forKey: "enabledWidgets")
        let empty = PanelLayoutStore(defaults: defaults)
        XCTAssertEqual(empty.configuration.visibleItems.map(\.id), [.currentTask, .recentTasks])
        let malformed = Data("not JSON".utf8)
        defaults.set(malformed, forKey: "enabledWidgets")
        empty.reload()
        XCTAssertEqual(empty.configuration, .factoryDefault)
        XCTAssertEqual(defaults.data(forKey: "enabledWidgets"), malformed)
        XCTAssertNil(defaults.object(forKey: PanelLayoutStore.storageKey))
    }

    func testSaveAndReloadUseOneConfigurationWithoutMirroringLegacyKeys() throws {
        let old = try JSONEncoder().encode(Set(["media"]))
        defaults.set(old, forKey: "enabledWidgets")
        defaults.set(false, forKey: "showNookFlowHistory")
        let store = PanelLayoutStore(defaults: defaults)
        var edited = store.configuration
        edited.setVisible(.notes, visible: true)
        edited.setVisible(.recentTasks, visible: true)
        edited.move(.notes, column: 0, row: 14)
        try store.save(edited)
        let reloaded = PanelLayoutStore(defaults: defaults)
        XCTAssertEqual(reloaded.configuration, edited)
        XCTAssertEqual(store.configuration, edited)
        XCTAssertTrue(reloaded.canEdit)
        XCTAssertEqual(defaults.data(forKey: "enabledWidgets"), old)
        XCTAssertFalse(defaults.bool(forKey: "showNookFlowHistory"))
    }

    func testSavedVersionOneLayoutSurvivesNewDefaultsAndBackgroundChangesWithoutRewriting() throws {
        // 已发布版本的默认网格也是用户保存的数据，不能随新默认排列重建。
        let saved = PanelLayoutConfiguration(items: [
            .init(id: .media, column: 0, row: 0, columns: 4, rows: 4, isVisible: true),
            .init(id: .calendar, column: 4, row: 0, columns: 4, rows: 4, isVisible: true),
            .init(id: .tray, column: 8, row: 0, columns: 4, rows: 4, isVisible: true),
            .init(id: .notes, column: 0, row: 4, columns: 4, rows: 6, isVisible: true),
            .init(id: .currentTask, column: 4, row: 4, columns: 8, rows: 3, isVisible: true),
            .init(id: .recentTasks, column: 4, row: 7, columns: 8, rows: 3, isVisible: true),
        ])
        try saved.validate()
        let encoded = try JSONEncoder().encode(saved)
        defaults.set(encoded, forKey: PanelLayoutStore.storageKey)
        defaults.set(try JSONEncoder().encode(Set<String>()), forKey: "enabledWidgets")
        defaults.set(false, forKey: "showNookFlowHistory")
        let store = PanelLayoutStore(defaults: defaults)
        for background in ["black", "light", "glass", "solid"] {
            defaults.set(background, forKey: "islandBackgroundStyle")
            store.reload()
            XCTAssertEqual(store.configuration, saved)
            XCTAssertEqual(defaults.data(forKey: PanelLayoutStore.storageKey), encoded)
            XCTAssertNil(defaults.object(forKey: PanelLayoutStore.recoveryBackupKey))
        }
        XCTAssertEqual(PanelLayoutStore(defaults: defaults).configuration, saved)
    }

    func testCorruptAndNonDataStorageArePreservedUntilExplicitReset() throws {
        for original: Any in [Data("damaged layout".utf8), "unexpected string"] {
            defaults.set(original, forKey: PanelLayoutStore.storageKey)
            let store = PanelLayoutStore(defaults: defaults)
            XCTAssertFalse(store.canEdit)
            XCTAssertNotNil(store.loadError)
            XCTAssertThrowsError(try store.save(.factoryDefault))
            XCTAssertEqual(defaults.object(forKey: PanelLayoutStore.storageKey) as? NSObject, original as? NSObject)
            XCTAssertNil(defaults.object(forKey: PanelLayoutStore.recoveryBackupKey))
        }
    }

    func testFutureVersionWithUnknownModulesIsPreserved() throws {
        let original = Data(#"{"version":99,"items":[{"id":"future-module"}]}"#.utf8)
        defaults.set(original, forKey: PanelLayoutStore.storageKey)
        let store = PanelLayoutStore(defaults: defaults)
        XCTAssertFalse(store.canEdit)
        XCTAssertTrue(store.loadError?.contains("99") == true)
        XCTAssertThrowsError(try store.save(.factoryDefault))
        XCTAssertEqual(defaults.data(forKey: PanelLayoutStore.storageKey), original)
        try store.reset()
        XCTAssertEqual(defaults.data(forKey: PanelLayoutStore.recoveryBackupKey), original)
        XCTAssertTrue(store.canEdit)
    }

    func testInvalidDecodedConfigurationDoesNotBecomeEditable() throws {
        var invalid = PanelLayoutConfiguration.factoryDefault
        invalid.items[0].rows = 3
        let original = try JSONEncoder().encode(invalid)
        defaults.set(original, forKey: PanelLayoutStore.storageKey)
        let store = PanelLayoutStore(defaults: defaults)
        XCTAssertFalse(store.canEdit)
        XCTAssertEqual(defaults.data(forKey: PanelLayoutStore.storageKey), original)
        XCTAssertThrowsError(try store.save(.factoryDefault))
    }

    func testInvalidSavePreservesLastValidConfigurationAndStorage() throws {
        let store = PanelLayoutStore(defaults: defaults)
        try store.save(.factoryDefault)
        let originalData = defaults.data(forKey: PanelLayoutStore.storageKey)
        var invalid = store.configuration
        invalid.items.removeLast()
        XCTAssertThrowsError(try store.save(invalid))
        XCTAssertEqual(store.configuration, .factoryDefault)
        XCTAssertEqual(defaults.data(forKey: PanelLayoutStore.storageKey), originalData)
        XCTAssertTrue(store.canEdit)
    }

    func testReloadFailurePreservesLastLoadedLayoutAndRecoveryBacksUpOriginalOnce() throws {
        let store = PanelLayoutStore(defaults: defaults)
        var edited = store.configuration
        edited.move(.media, column: 0, row: 20)
        try store.save(edited)
        let damaged = Data("preserve damaged layout".utf8)
        defaults.set(damaged, forKey: PanelLayoutStore.storageKey)
        store.reload()
        XCTAssertFalse(store.canEdit)
        XCTAssertEqual(store.configuration, edited)
        try store.reset()
        XCTAssertTrue(store.canEdit)
        XCTAssertNil(store.loadError)
        XCTAssertEqual(store.configuration, .factoryDefault)
        XCTAssertEqual(defaults.data(forKey: PanelLayoutStore.recoveryBackupKey), damaged)
        XCTAssertEqual(PanelLayoutStore(defaults: defaults).configuration, .factoryDefault)

        let laterDamage = Data("second damaged layout".utf8)
        defaults.set(laterDamage, forKey: PanelLayoutStore.storageKey)
        store.reload()
        try store.reset()
        XCTAssertEqual(defaults.data(forKey: PanelLayoutStore.recoveryBackupKey), damaged)
    }

    func testReloadCanRecoverAfterExternalRepairWithoutWriting() throws {
        defaults.set(Data("damaged".utf8), forKey: PanelLayoutStore.storageKey)
        let store = PanelLayoutStore(defaults: defaults)
        let repaired = PanelLayoutConfiguration.legacy(enabledWidgetIDs: ["calendar"], showHistory: false)
        let encoded = try JSONEncoder().encode(repaired)
        defaults.set(encoded, forKey: PanelLayoutStore.storageKey)
        store.reload()
        XCTAssertTrue(store.canEdit)
        XCTAssertEqual(store.configuration, repaired)
        XCTAssertEqual(defaults.data(forKey: PanelLayoutStore.storageKey), encoded)
        XCTAssertNil(defaults.object(forKey: PanelLayoutStore.recoveryBackupKey))
    }
    func testContentFittingRequiresAutomaticUnsavedOverviewAndNeverWritesDefaults() throws {
        let store = PanelLayoutStore(defaults: defaults)
        let before = defaults.persistentDomain(forName: suiteName) ?? [:]
        XCTAssertFalse(store.hasSavedConfiguration)
        for automatic in [false, true] {
            for editing in [false, true] {
                for overview in [false, true] {
                    XCTAssertEqual(store.shouldFitDefaultContent(automaticallyFit: automatic,
                        isEditing: editing, isOverview: overview), automatic && !editing && overview)
                }
            }
        }
        XCTAssertEqual(defaults.persistentDomain(forName: suiteName) as NSDictionary? ?? [:], before as NSDictionary)
        XCTAssertNil(defaults.object(forKey: PanelLayoutStore.storageKey))
        try store.save(.factoryDefault)
        let saved = defaults.data(forKey: PanelLayoutStore.storageKey)
        XCTAssertTrue(store.hasSavedConfiguration)
        XCTAssertFalse(store.shouldFitDefaultContent(automaticallyFit: true))
        store.reload()
        XCTAssertFalse(store.shouldFitDefaultContent(automaticallyFit: true))
        XCTAssertEqual(defaults.data(forKey: PanelLayoutStore.storageKey), saved)
    }

    func testEditingCancelRetainsDefaultContentFitWhileSaveAndResetExplicitlyDisableIt() throws {
        let store = PanelLayoutStore(defaults: defaults)
        let editor = PanelLayoutEditingSession()
        editor.begin(from: store)
        XCTAssertFalse(store.shouldFitDefaultContent(automaticallyFit: true, isEditing: editor.isEditing))
        editor.draft.resize(.notes, columns: 12, rows: 8)
        editor.cancel()
        XCTAssertTrue(store.shouldFitDefaultContent(automaticallyFit: true))
        XCTAssertNil(defaults.object(forKey: PanelLayoutStore.storageKey))
        editor.begin(from: store)
        XCTAssertTrue(editor.save(to: store))
        XCTAssertFalse(store.shouldFitDefaultContent(automaticallyFit: true))
        defaults.removeObject(forKey: PanelLayoutStore.storageKey)
        store.reload()
        XCTAssertTrue(store.shouldFitDefaultContent(automaticallyFit: true))
        try store.reset()
        XCTAssertTrue(store.hasSavedConfiguration)
        XCTAssertFalse(store.shouldFitDefaultContent(automaticallyFit: true))
    }

    func testInvalidOrFutureSavedLayoutCannotEnableContentFit() {
        for original: Any in [Data("damaged".utf8), "unexpected", Data(#"{"version":99,"items":[]}"#.utf8)] {
            defaults.set(original, forKey: PanelLayoutStore.storageKey)
            let store = PanelLayoutStore(defaults: defaults)
            XCTAssertTrue(store.hasSavedConfiguration)
            XCTAssertNotNil(store.loadError)
            XCTAssertFalse(store.shouldFitDefaultContent(automaticallyFit: true))
            XCTAssertEqual(defaults.object(forKey: PanelLayoutStore.storageKey) as? NSObject, original as? NSObject)
            XCTAssertNil(defaults.object(forKey: PanelLayoutStore.recoveryBackupKey))
        }
    }
}
