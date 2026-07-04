import SwiftUI
import XCTest
@testable import XNook

@MainActor
final class ThemeManagerTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "appearanceMode")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "appearanceMode")
        super.tearDown()
    }

    func testDefaultModeIsSystem() {
        let manager = ThemeManager()
        XCTAssertEqual(manager.mode, .system)
    }

    func testResolvedSchemeDark() {
        let manager = ThemeManager()
        manager.mode = .dark
        XCTAssertEqual(manager.resolvedScheme, .dark)
    }

    func testResolvedSchemeLight() {
        let manager = ThemeManager()
        manager.mode = .light
        XCTAssertEqual(manager.resolvedScheme, .light)
    }

    func testResolvedSchemeSystemReturnsValidScheme() {
        let manager = ThemeManager()
        manager.mode = .system
        let scheme = manager.resolvedScheme
        XCTAssertTrue(scheme == .dark || scheme == .light)
    }

    func testModePersists() {
        let manager = ThemeManager()
        manager.mode = .light

        let reloaded = ThemeManager()
        XCTAssertEqual(reloaded.mode, .light)
    }
}
