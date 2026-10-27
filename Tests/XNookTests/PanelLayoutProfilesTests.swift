import XCTest
@testable import XNook

@MainActor
final class PanelLayoutProfilesTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        suiteName = "XNookTests.PanelLayoutProfiles.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
    }

    func testAllTemplatesContainEveryModuleAndValidate() throws {
        for template in PanelLayoutTemplate.allCases {
            let configuration = template.configuration
            try configuration.validate()
            XCTAssertEqual(configuration.items.count, PanelModuleID.allCases.count)
            XCTAssertEqual(Set(configuration.items.map(\.id)), Set(PanelModuleID.allCases))
            XCTAssertEqual(configuration.fitsContent, true)
            XCTAssertFalse(template.localizedName.isEmpty)
            XCTAssertFalse(template.summary.isEmpty)
        }
        XCTAssertNil(defaults.object(forKey: PanelLayoutProfileStore.storageKey))
        XCTAssertNil(defaults.object(forKey: PanelLayoutStore.storageKey))
    }

    func testDefaultTemplateKeepsThreeWidgetsAcrossAndTasksBelow() {
        XCTAssertEqual(PanelLayoutTemplate.standard.configuration.visibleItems, [
            .init(id: .media, column: 0, row: 0, columns: 4, rows: 4, isVisible: true),
            .init(id: .calendar, column: 4, row: 0, columns: 4, rows: 4, isVisible: true),
            .init(id: .tray, column: 8, row: 0, columns: 4, rows: 4, isVisible: true),
            .init(id: .currentTask, column: 0, row: 4, columns: 12, rows: 3, isVisible: true),
            .init(id: .recentTasks, column: 0, row: 7, columns: 12, rows: 3, isVisible: true),
        ])
    }

    func testFocusAndMediaTemplatesUseExpectedSizes() {
        XCTAssertEqual(PanelLayoutTemplate.focus.configuration.visibleItems, [
            .init(id: .currentTask, column: 0, row: 0, columns: 6, rows: 4, isVisible: true),
            .init(id: .notes, column: 6, row: 0, columns: 6, rows: 4, isVisible: true),
            .init(id: .recentTasks, column: 0, row: 4, columns: 12, rows: 3, isVisible: true),
        ])
        XCTAssertEqual(PanelLayoutTemplate.media.configuration.visibleItems, [
            .init(id: .media, column: 0, row: 0, columns: 12, rows: 4, isVisible: true),
        ])
    }

    func testFirstLoadAndReloadDoNotCreateStorage() {
        let store = PanelLayoutProfileStore(defaults: defaults)
        store.reload()
        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertTrue(store.canEdit)
        XCTAssertNil(store.loadError)
        XCTAssertTrue(defaults.persistentDomain(forName: suiteName)?.isEmpty ?? true)
    }

    func testFocusTemplateKeepsTaskAndNotesSideBySideAtMediumWidth() throws {
        let configuration = PanelLayoutTemplate.focus.configuration
        let frames = PanelGridGeometry.frames(for: configuration, width: 700)
        let task = try XCTUnwrap(frames[.currentTask])
        let notes = try XCTUnwrap(frames[.notes])
        let recent = try XCTUnwrap(frames[.recentTasks])
        XCTAssertEqual(task.minY, notes.minY)
        XCTAssertEqual(task.width, 346, accuracy: 0.001)
        XCTAssertEqual(notes.width, task.width)
        XCTAssertEqual(notes.minX, task.maxX + PanelGridGeometry.spacing)
        XCTAssertFalse(task.intersects(notes))
        XCTAssertGreaterThan(recent.minY, max(task.maxY, notes.maxY))
        let fitted = PanelGridGeometry.contentFittedFrames(for: configuration, width: 700,
            measuredHeights: [.currentTask: 88, .notes: 136, .recentTasks: 44])
        XCTAssertEqual(fitted[.currentTask]?.minY, fitted[.notes]?.minY)
        XCTAssertEqual(fitted[.currentTask]?.height, 136)
        XCTAssertEqual(fitted[.recentTasks]?.minY, 144)
    }

    func testProfileRoundTripKeepsTemplateAndManualContentFitModes() throws {
        let store = PanelLayoutProfileStore(defaults: defaults)
        let fitting = try store.saveNew(configuration: PanelLayoutTemplate.focus.configuration, name: "Fit")
        var resized = fitting.configuration
        resized.resize(.notes, columns: 6, rows: 8)
        let fixed = try store.saveNew(configuration: resized, name: "Fixed")
        let reloaded = PanelLayoutProfileStore(defaults: defaults)
        XCTAssertEqual(reloaded.profiles, [fitting, fixed])
        XCTAssertEqual(reloaded.profiles[0].configuration.fitsContent, true)
        XCTAssertEqual(reloaded.profiles[1].configuration.fitsContent, false)
    }

    func testAutomaticNamesReuseSmallestAvailableNumberInBothLanguages() throws {
        let store = PanelLayoutProfileStore(defaults: defaults)
        var first: SavedPanelLayout!
        try withLanguage("zh") {
            first = try store.saveNew(configuration: PanelLayoutTemplate.standard.configuration)
            let second = try store.saveNew(configuration: PanelLayoutTemplate.focus.configuration)
            XCTAssertEqual(first.name, "自定义布局 1")
            XCTAssertEqual(second.name, "自定义布局 2")
            try store.saveNew(configuration: PanelLayoutTemplate.media.configuration, name: "自定义布局 4")
        }
        try withLanguage("en") {
            let third = try store.saveNew(configuration: PanelLayoutTemplate.media.configuration)
            XCTAssertEqual(third.name, "Custom Layout 3")
            try store.delete(id: first.id)
            let reused = try store.saveNew(configuration: PanelLayoutTemplate.standard.configuration)
            XCTAssertEqual(reused.name, "Custom Layout 1")
        }
    }

    func testSaveRenameUpdateAndDeleteSurviveReload() throws {
        let store = PanelLayoutProfileStore(defaults: defaults)
        let profile = try store.saveNew(configuration: PanelLayoutTemplate.standard.configuration, name: "  日常布局 \n")
        XCTAssertEqual(profile.name, "日常布局")
        XCTAssertEqual(PanelLayoutProfileStore(defaults: defaults).profiles, [profile])
        try store.rename(id: profile.id, name: "  阅读布局  ")
        try store.update(id: profile.id, configuration: PanelLayoutTemplate.focus.configuration)
        let updated = try XCTUnwrap(PanelLayoutProfileStore(defaults: defaults).profiles.first)
        XCTAssertEqual(updated.id, profile.id)
        XCTAssertEqual(updated.name, "阅读布局")
        XCTAssertEqual(updated.configuration, PanelLayoutTemplate.focus.configuration)
        try store.delete(id: profile.id)
        XCTAssertTrue(PanelLayoutProfileStore(defaults: defaults).profiles.isEmpty)
        XCTAssertTrue(store.canEdit)
    }

    func testInvalidNamesAndDuplicatesPreserveStoredBytes() throws {
        let store = PanelLayoutProfileStore(defaults: defaults)
        let first = try store.saveNew(configuration: PanelLayoutTemplate.standard.configuration, name: "Work")
        let second = try store.saveNew(configuration: PanelLayoutTemplate.focus.configuration, name: "Focus")
        let original = defaults.data(forKey: PanelLayoutProfileStore.storageKey)
        let cases: [(String, PanelLayoutProfileError)] = [
            (" \n\t ", .emptyName),
            (String(repeating: "字", count: PanelLayoutProfileStore.maximumNameLength + 1), .nameTooLong),
            ("a\nb", .invalidName),
            (" work ", .duplicateName),
        ]
        for (name, error) in cases {
            XCTAssertThrowsError(try store.saveNew(configuration: PanelLayoutTemplate.media.configuration, name: name)) {
                XCTAssertEqual($0 as? PanelLayoutProfileError, error)
            }
            XCTAssertThrowsError(try store.rename(id: second.id, name: name)) {
                XCTAssertEqual($0 as? PanelLayoutProfileError, error)
            }
            XCTAssertEqual(defaults.data(forKey: PanelLayoutProfileStore.storageKey), original)
            XCTAssertEqual(store.profiles, [first, second])
            XCTAssertTrue(store.canEdit)
        }
        try store.rename(id: first.id, name: " Work ")
        try store.update(id: first.id, configuration: first.configuration)
        XCTAssertEqual(defaults.data(forKey: PanelLayoutProfileStore.storageKey), original)
    }

    func testInvalidConfigurationCannotBeSavedOrReplaceExistingProfile() throws {
        let store = PanelLayoutProfileStore(defaults: defaults)
        let profile = try store.saveNew(configuration: PanelLayoutTemplate.standard.configuration)
        let original = defaults.data(forKey: PanelLayoutProfileStore.storageKey)
        var invalid = profile.configuration
        invalid.items.removeLast()
        XCTAssertThrowsError(try store.saveNew(configuration: invalid, name: "Invalid"))
        XCTAssertThrowsError(try store.update(id: profile.id, configuration: invalid))
        XCTAssertEqual(defaults.data(forKey: PanelLayoutProfileStore.storageKey), original)
        XCTAssertEqual(store.profiles, [profile])
        XCTAssertTrue(store.canEdit)
    }

    func testProfileOperationsNeverChangeActiveLayoutOrOtherPreferences() throws {
        let active = try JSONEncoder().encode(PanelLayoutTemplate.media.configuration)
        defaults.set(active, forKey: PanelLayoutStore.storageKey)
        defaults.set(Data("legacy flags".utf8), forKey: "enabledWidgets")
        defaults.set(false, forKey: "showNookFlowHistory")
        defaults.set("glass", forKey: "islandBackgroundStyle")
        defaults.set(640.0, forKey: "panelBaseHeight")
        defaults.set("keep my notes", forKey: "notes")
        let original = try XCTUnwrap(defaults.persistentDomain(forName: suiteName))
        let store = PanelLayoutProfileStore(defaults: defaults)
        let saved = try store.saveNew(configuration: PanelLayoutTemplate.standard.configuration)
        try store.rename(id: saved.id, name: "Renamed")
        try store.update(id: saved.id, configuration: PanelLayoutTemplate.focus.configuration)
        try store.delete(id: saved.id)
        var after = try XCTUnwrap(defaults.persistentDomain(forName: suiteName))
        after.removeValue(forKey: PanelLayoutProfileStore.storageKey)
        XCTAssertEqual(after as NSDictionary, original as NSDictionary)
        XCTAssertEqual(PanelLayoutStore(defaults: defaults).configuration, PanelLayoutTemplate.media.configuration)
    }

    func testEveryMutationReloadsAndPreservesOtherWindowAdditions() throws {
        let firstWindow = PanelLayoutProfileStore(defaults: defaults)
        let secondWindow = PanelLayoutProfileStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
        let first = try firstWindow.saveNew(configuration: PanelLayoutTemplate.standard.configuration, name: "First")
        let second = try secondWindow.saveNew(configuration: PanelLayoutTemplate.focus.configuration, name: "Second")
        XCTAssertEqual(secondWindow.profiles.map(\.id), [first.id, second.id])
        try firstWindow.rename(id: first.id, name: "Renamed")
        XCTAssertEqual(firstWindow.profiles.map(\.id), [first.id, second.id])
        let third = try secondWindow.saveNew(configuration: PanelLayoutTemplate.media.configuration, name: "Third")
        try firstWindow.update(id: first.id, configuration: PanelLayoutTemplate.focus.configuration)
        XCTAssertEqual(firstWindow.profiles.map(\.id), [first.id, second.id, third.id])
        let fourth = try secondWindow.saveNew(configuration: PanelLayoutTemplate.standard.configuration, name: "Fourth")
        try firstWindow.delete(id: first.id)
        let reloaded = PanelLayoutProfileStore(defaults: defaults)
        XCTAssertEqual(reloaded.profiles.map(\.id), [second.id, third.id, fourth.id])
    }

    func testDeletedProfileCannotBeRecreatedByStaleWindowMutation() throws {
        let firstWindow = PanelLayoutProfileStore(defaults: defaults)
        let profile = try firstWindow.saveNew(configuration: PanelLayoutTemplate.standard.configuration)
        let secondWindow = PanelLayoutProfileStore(defaults: defaults)
        try secondWindow.delete(id: profile.id)
        let original = defaults.data(forKey: PanelLayoutProfileStore.storageKey)
        for mutation in [
            { try firstWindow.rename(id: profile.id, name: "Missing") },
            { try firstWindow.update(id: profile.id, configuration: PanelLayoutTemplate.focus.configuration) },
            { try firstWindow.delete(id: profile.id) },
        ] {
            XCTAssertThrowsError(try mutation()) { XCTAssertEqual($0 as? PanelLayoutProfileError, .notFound) }
        }
        XCTAssertEqual(defaults.data(forKey: PanelLayoutProfileStore.storageKey), original)
        XCTAssertTrue(firstWindow.profiles.isEmpty)
    }

    func testStaleWindowUsesFreshDefaultNamesAndRejectsFreshDuplicates() throws {
        let firstWindow = PanelLayoutProfileStore(defaults: defaults)
        let secondWindow = PanelLayoutProfileStore(defaults: defaults)
        try withLanguage("zh") {
            let first = try firstWindow.saveNew(configuration: PanelLayoutTemplate.standard.configuration)
            let second = try secondWindow.saveNew(configuration: PanelLayoutTemplate.focus.configuration)
            XCTAssertEqual(first.name, "自定义布局 1")
            XCTAssertEqual(second.name, "自定义布局 2")
            let original = defaults.data(forKey: PanelLayoutProfileStore.storageKey)
            XCTAssertThrowsError(try firstWindow.saveNew(configuration: PanelLayoutTemplate.media.configuration, name: second.name)) {
                XCTAssertEqual($0 as? PanelLayoutProfileError, .duplicateName)
            }
            XCTAssertEqual(defaults.data(forKey: PanelLayoutProfileStore.storageKey), original)
        }
    }

    func testDamagedFutureAndOversizedStorageIsPreservedAndBlocksAllWrites() throws {
        let originals: [Any] = [
            Data("damaged".utf8), "unexpected type",
            Data(#"{"version":99,"profiles":[{"future":"data"}]}"#.utf8),
            Data(repeating: 0, count: PanelLayoutProfileStore.maximumStoredBytes + 1),
        ]
        for original in originals {
            defaults.set(original, forKey: PanelLayoutProfileStore.storageKey)
            let store = PanelLayoutProfileStore(defaults: defaults)
            XCTAssertFalse(store.canEdit)
            XCTAssertNotNil(store.loadError)
            let id = UUID()
            XCTAssertThrowsError(try store.saveNew(configuration: PanelLayoutTemplate.standard.configuration))
            XCTAssertThrowsError(try store.rename(id: id, name: "Renamed"))
            XCTAssertThrowsError(try store.update(id: id, configuration: PanelLayoutTemplate.focus.configuration))
            XCTAssertThrowsError(try store.delete(id: id))
            XCTAssertEqual(defaults.object(forKey: PanelLayoutProfileStore.storageKey) as? NSObject, original as? NSObject)
        }
    }

    func testInvalidDecodedLibrariesArePreserved() throws {
        let first = SavedPanelLayout(id: UUID(), name: "First", configuration: PanelLayoutTemplate.standard.configuration)
        var duplicateID = first
        duplicateID.name = "Other"
        let duplicateName = SavedPanelLayout(id: UUID(), name: "FIRST", configuration: first.configuration)
        var invalidLayout = first
        invalidLayout.configuration.items[0].rows = 3
        var futureLayout = first
        futureLayout.configuration.version = 99
        var untrimmedName = first
        untrimmedName.name = " First "
        for profiles in [[first, duplicateID], [first, duplicateName], [invalidLayout], [futureLayout], [untrimmedName]] {
            let original = try encodedLibrary(profiles)
            defaults.set(original, forKey: PanelLayoutProfileStore.storageKey)
            let store = PanelLayoutProfileStore(defaults: defaults)
            XCTAssertFalse(store.canEdit)
            XCTAssertThrowsError(try store.saveNew(configuration: first.configuration))
            XCTAssertEqual(defaults.data(forKey: PanelLayoutProfileStore.storageKey), original)
        }
    }

    func testExternalDamageIsDetectedBeforeWriteAndExternalRepairCanBeReloaded() throws {
        let store = PanelLayoutProfileStore(defaults: defaults)
        let profile = try store.saveNew(configuration: PanelLayoutTemplate.standard.configuration)
        let valid = try XCTUnwrap(defaults.data(forKey: PanelLayoutProfileStore.storageKey))
        let damaged = Data("external damage".utf8)
        defaults.set(damaged, forKey: PanelLayoutProfileStore.storageKey)
        XCTAssertThrowsError(try store.rename(id: profile.id, name: "Renamed"))
        XCTAssertEqual(store.profiles, [profile])
        XCTAssertFalse(store.canEdit)
        XCTAssertEqual(defaults.data(forKey: PanelLayoutProfileStore.storageKey), damaged)
        defaults.set(valid, forKey: PanelLayoutProfileStore.storageKey)
        store.reload()
        XCTAssertTrue(store.canEdit)
        XCTAssertNil(store.loadError)
        XCTAssertEqual(store.profiles, [profile])
        XCTAssertEqual(defaults.data(forKey: PanelLayoutProfileStore.storageKey), valid)
    }

    func testProfileCountLimitDoesNotPreventUpdatingOrDeletingExistingProfiles() throws {
        let profiles = (1...PanelLayoutProfileStore.maximumProfiles).map {
            SavedPanelLayout(id: UUID(), name: "Layout \($0)", configuration: PanelLayoutTemplate.standard.configuration)
        }
        let original = try encodedLibrary(profiles)
        defaults.set(original, forKey: PanelLayoutProfileStore.storageKey)
        let store = PanelLayoutProfileStore(defaults: defaults)
        XCTAssertTrue(store.canEdit)
        XCTAssertThrowsError(try store.saveNew(configuration: PanelLayoutTemplate.media.configuration)) {
            XCTAssertEqual($0 as? PanelLayoutProfileError, .tooManyProfiles)
        }
        XCTAssertEqual(defaults.data(forKey: PanelLayoutProfileStore.storageKey), original)
        try store.rename(id: profiles[0].id, name: "Renamed")
        try store.update(id: profiles[0].id, configuration: PanelLayoutTemplate.focus.configuration)
        try store.delete(id: profiles[0].id)
        try store.saveNew(configuration: PanelLayoutTemplate.media.configuration)
        XCTAssertEqual(store.profiles.count, PanelLayoutProfileStore.maximumProfiles)
        let excessive = profiles + [SavedPanelLayout(id: UUID(), name: "Extra", configuration: profiles[0].configuration)]
        let excessiveData = try encodedLibrary(excessive)
        defaults.set(excessiveData, forKey: PanelLayoutProfileStore.storageKey)
        store.reload()
        XCTAssertFalse(store.canEdit)
        XCTAssertEqual(defaults.data(forKey: PanelLayoutProfileStore.storageKey), excessiveData)
    }

    func testNamingErrorsAndTemplateLabelsAreLocalized() {
        let errors: [PanelLayoutProfileError] = [.emptyName, .nameTooLong, .invalidName, .duplicateName, .notFound]
        var chinese: [String] = []
        withLanguage("zh") {
            chinese = errors.map(\.localizedDescription) + PanelLayoutTemplate.allCases.map(\.localizedName)
        }
        withLanguage("en") {
            let english = errors.map(\.localizedDescription) + PanelLayoutTemplate.allCases.map(\.localizedName)
            XCTAssertEqual(english.count, chinese.count)
            for (zh, en) in zip(chinese, english) {
                XCTAssertFalse(zh.isEmpty)
                XCTAssertFalse(en.isEmpty)
                XCTAssertNotEqual(zh, en)
            }
        }
    }

    private func encodedLibrary(_ profiles: [SavedPanelLayout]) throws -> Data {
        struct Library: Encodable {
            let version: Int
            let profiles: [SavedPanelLayout]
        }
        return try JSONEncoder().encode(Library(version: PanelLayoutProfileStore.currentVersion, profiles: profiles))
    }

    private func withLanguage(_ language: String, operation: () throws -> Void) rethrows {
        let original = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
        var arguments = original
        arguments["appLanguage"] = language
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        try operation()
    }
}
