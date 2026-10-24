import XCTest
import EventKit
import ServiceManagement
@testable import XNook

@MainActor
final class SettingsDiscoveryTests: XCTestCase {
    func testRequiredSearchTermsReachStableRowsInEitherLanguage() throws {
        let original = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
        for language in ["zh", "en"] {
            var arguments = original
            arguments["appLanguage"] = language
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            for (query, target) in [("高度", "panelBaseHeight"), ("panel HEIGHT", "panelBaseHeight"),
                ("歌词延迟", "lyricsOffset"), ("lyric delay", "lyricsOffset"),
                ("自动隐藏", "expandedInactivity"), ("full screen", "hideInFullscreen"),
                ("日历权限", "permissionCalendar"), ("calendar access", "permissionCalendar"),
                ("背景", "islandBackgroundStyle"), ("background glass", "islandBackgroundStyle"),
                ("玻璃深浅", "islandGlassDepth"), ("glass depth", "islandGlassDepth"),
                ("网格", "panelLayoutEditor"), ("grid layout", "panelLayoutEditor"),
                ("auto size", "panelAutoSize"), ("全局快捷唤出", "globalPanelShortcut"),
                ("global hotkey", "globalPanelShortcut")] {
                XCTAssertTrue(SettingsSearchEntry.matches(query).contains { $0.id == target }, "\(language) \(query)")
            }
            XCTAssertEqual(SettingsSearchEntry.matches("lyricsOffset").first?.id, "lyricsOffset")
        }
    }

    func testEmptyUnknownAndOversizedQueriesHaveNoResults() {
        for query in ["", " \n\t", "does-not-exist", String(repeating: "高", count: 201)] {
            XCTAssertTrue(SettingsSearchEntry.matches(query).isEmpty)
        }
        XCTAssertEqual(SettingsSearchEntry.matches("  ＨＥＩＧＨＴ  ").map(\.id), SettingsSearchEntry.matches("height").map(\.id))
        XCTAssertEqual(Set(SettingsSearchEntry.all.map(\.id)).count, SettingsSearchEntry.all.count)
    }

    func testSearchTargetsCorrespondToActualSettingsRows() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let settings = try String(contentsOf: root.appendingPathComponent("Sources/XNook/Settings/SettingsView.swift"), encoding: .utf8)
        let permissions = try String(contentsOf: root.appendingPathComponent("Sources/XNook/Settings/SettingsPermissionsView.swift"), encoding: .utf8)
        let background = try String(contentsOf: root.appendingPathComponent("Sources/XNook/Settings/IslandBackgroundSettingsView.swift"), encoding: .utf8)
        for entry in SettingsSearchEntry.all {
            XCTAssertTrue((settings + permissions + background).contains("id: \"\(entry.id)\""), "悬空搜索目标 \(entry.id)")
        }
    }

    func testNavigationClearsSearchAndNewQueryInvalidatesOldTarget() throws {
        let search = SettingsSearchState()
        search.query = "height"
        let height = try XCTUnwrap(search.results.first { $0.id == "panelBaseHeight" })
        search.navigate(to: height)
        XCTAssertEqual(search.pane, .display)
        XCTAssertEqual(search.targetID, "panelBaseHeight")
        XCTAssertFalse(search.isSearching)
        search.query = "日历权限"
        XCTAssertNil(search.targetID)
        let calendar = try XCTUnwrap(search.results.first)
        search.navigate(to: calendar)
        XCTAssertEqual(search.pane, .general)
        XCTAssertEqual(search.targetID, "permissionCalendar")
        search.selectPane(.about)
        XCTAssertNil(search.targetID)
        XCTAssertEqual(search.pane, .about)
        search.navigate(to: .init(id: "missing", pane: .display, title: "无效", keywords: ""))
        XCTAssertEqual(search.pane, .about)
    }

    func testPermissionInitializationDoesNotProbeAndRefreshReadsCurrentState() {
        var reads = 0
        var calendar = EKAuthorizationStatus.notDetermined
        var login = SMAppService.Status.notRegistered
        let status = SettingsPermissions(readCalendar: { reads += 1; return calendar }, readLoginItems: { reads += 1; return login })
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(status.calendar, .unknown)
        XCTAssertEqual(status.loginItems, .unknown)
        status.refresh()
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(status.calendar, .notRequested)
        XCTAssertEqual(status.loginItems, .disabled)
        calendar = .fullAccess
        login = .requiresApproval
        status.refresh()
        XCTAssertEqual(reads, 4)
        XCTAssertEqual(status.calendar, .allowed)
        XCTAssertEqual(status.loginItems, .requiresApproval)
        XCTAssertEqual(status.automation, .unknown)
    }

    func testCalendarWriteOnlyDeniedRestrictedAndUnknownAreDistinct() {
        for (input, expected) in [(EKAuthorizationStatus.writeOnly, SettingsPermissionState.writeOnly),
            (.denied, .denied), (.restricted, .restricted), (.fullAccess, .allowed)] {
            let status = SettingsPermissions(readCalendar: { input }, readLoginItems: { .notRegistered })
            status.refresh()
            XCTAssertEqual(status.calendar, expected)
        }
    }

    func testLoginStatesDoNotTreatRegistrationAsApproval() {
        for (input, expected) in [(SMAppService.Status.enabled, SettingsPermissionState.allowed),
            (.requiresApproval, .requiresApproval), (.notFound, .unavailable), (.notRegistered, .disabled)] {
            let status = SettingsPermissions(readCalendar: { .notDetermined }, readLoginItems: { input })
            status.refresh()
            XCTAssertEqual(status.loginItems, expected)
        }
    }

    func testActivityDefaultsPreserveNoticesAndKeepOptionalSourcesOff() throws {
        let suite = "XNook.SettingsDefaults.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        SettingsDefaults.register(on: defaults)
        XCTAssertTrue(defaults.bool(forKey: "activityNotificationsEnabled"))
        XCTAssertTrue(SettingsDefaults.bool(for: "activityNotificationsEnabled"))
        for key in ["calendarReminderActivityEnabled", "claudeCompletionEnabled"] {
            XCTAssertFalse(defaults.bool(forKey: key), key)
            XCTAssertFalse(SettingsDefaults.bool(for: key), key)
        }
        XCTAssertEqual(defaults.double(forKey: "lyricsOffset"), 0)
        XCTAssertEqual(defaults.string(forKey: "islandBackgroundStyle"), IslandBackgroundStyle.solid.rawValue)
        XCTAssertEqual(defaults.double(forKey: "islandGlassDepth"), IslandBackgroundPolicy.defaultGlassDepth)
        XCTAssertTrue(defaults.bool(forKey: "panelAutoSize"))
    }

    func testSignedLyricsOffsetInputPreservesDirectionAndFormatSuffix() {
        XCTAssertEqual(AppStorageSlider.parsedInput(" -1.5s ", range: -5...5, format: "%+.1fs"), -1.5)
        XCTAssertEqual(AppStorageSlider.parsedInput("+0.3s", range: -5...5, format: "%+.1fs"), 0.3)
        XCTAssertEqual(AppStorageSlider.parsedInput("-9", range: -5...5, format: "%+.1fs"), -5)
        XCTAssertEqual(AppStorageSlider.parsedInput("200.00pt", range: 160...1000, format: "%.2fpt"), 200)
    }

    func testMalformedNumericInputCannotSilentlyBecomeADifferentNumber() {
        for value in ["1abc2", "--2s", "1.2.3", "nan", "inf", "", "-", "2minutes", "2s3"] {
            XCTAssertNil(AppStorageSlider.parsedInput(value, range: -5...5, format: "%+.1fs"), value)
        }
        XCTAssertEqual(AppStorageSlider.parsedInput("25.00pt/s", range: 1...200, format: "%.2fpt/s"), 25)
    }
}
