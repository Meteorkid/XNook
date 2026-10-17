import AppKit
import SwiftUI
import XCTest
@testable import XNook

@MainActor
final class ThemeManagerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var previousAppearance: NSAppearance?
    private var managers: [ThemeManager] = []

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        previousAppearance = NSApp.appearance
        NSApp.appearance = nil
        suite = "XNook.ThemeManagerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        managers.forEach {
            $0.stopObservingSystemAppearance()
            $0.onSchemeChange = nil
        }
        managers.removeAll()
        NSApp.appearance = previousAppearance
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    private func makeManager() -> ThemeManager {
        let manager = ThemeManager(defaults: defaults)
        managers.append(manager)
        return manager
    }

    func testDefaultModeIsSystem() {
        let manager = makeManager()
        XCTAssertEqual(manager.mode, .system)
    }

    func testResolvedSchemeDark() {
        let manager = makeManager()
        manager.mode = .dark
        XCTAssertEqual(manager.resolvedScheme, .dark)
    }

    func testResolvedSchemeLight() {
        let manager = makeManager()
        manager.mode = .light
        XCTAssertEqual(manager.resolvedScheme, .light)
    }

    func testResolvedSchemeSystemReturnsValidScheme() {
        let manager = makeManager()
        manager.mode = .system
        let scheme = manager.resolvedScheme
        XCTAssertTrue(scheme == .dark || scheme == .light)
    }

    func testModePersists() {
        let manager = makeManager()
        manager.mode = .light

        let reloaded = makeManager()
        XCTAssertEqual(reloaded.mode, .light)
    }

    func testUnchangedSystemAppearanceDoesNotRetriggerCallbacks() async {
        let manager = makeManager()
        let unexpected = expectation(description: "Unchanged system appearance must not notify")
        unexpected.isInverted = true
        var callbackCount = 0
        manager.onSchemeChange = {
            callbackCount += 1
            unexpected.fulfill()
            // 失败版本也必须及时结束观察，防止测试进程被自触发循环占满。
            if callbackCount >= 3 { manager.stopObservingSystemAppearance() }
        }
        NSApp.appearance = nil
        await fulfillment(of: [unexpected], timeout: 0.15)
        XCTAssertEqual(callbackCount, 0)
        XCTAssertNil(NSApp.appearance)
    }

    func testAppearanceObservationReadsChangeWithoutWritingOverride() async {
        let manager = makeManager()
        let target: NSAppearance.Name = manager.resolvedScheme == .dark ? .aqua : .darkAqua
        let targetScheme: ColorScheme = target == .darkAqua ? .dark : .light
        let changed = expectation(description: "Actual appearance change is observed once")
        var callbackCount = 0
        manager.onSchemeChange = {
            callbackCount += 1
            if callbackCount == 1 { changed.fulfill() }
            if callbackCount >= 3 { manager.stopObservingSystemAppearance() }
        }
        NSApp.appearance = NSAppearance(named: target)
        await fulfillment(of: [changed], timeout: 1)
        // 留出下一轮主队列时间，检查读到变化后没有回写外观并再次触发自己。
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(callbackCount, 1)
        XCTAssertEqual(manager.resolvedScheme, targetScheme)
        XCTAssertEqual(NSApp.appearance?.name, target)
    }

    func testManualModeDoesNotStartSystemObservation() {
        let manager = makeManager()
        manager.mode = .dark
        manager.startObservingSystemAppearance()
        XCTAssertNil(manager.effectiveAppearanceObservation)
        XCTAssertEqual(NSApp.appearance?.name, .darkAqua)
    }

    func testSwitchingToSystemResolvesAfterRemovingManualOverride() {
        let manager = makeManager()
        let systemScheme = manager.resolvedScheme
        manager.mode = systemScheme == .dark ? .light : .dark
        XCTAssertNotEqual(manager.resolvedScheme, systemScheme)
        manager.mode = .system
        XCTAssertNil(NSApp.appearance)
        XCTAssertEqual(manager.resolvedScheme, systemScheme)
    }

    func testQueuedSystemCallbackCannotOverrideNewManualMode() async {
        let manager = makeManager()
        let changed: NSAppearance.Name = manager.resolvedScheme == .dark ? .aqua : .darkAqua
        NSApp.appearance = NSAppearance(named: changed)
        // KVO 已排入 Task，但切换先于该 Task 获得主执行器。
        manager.mode = .light
        let unexpected = expectation(description: "Old observer must ignore the new manual mode")
        unexpected.isInverted = true
        manager.onSchemeChange = { unexpected.fulfill() }
        await fulfillment(of: [unexpected], timeout: 0.15)
        XCTAssertEqual(manager.resolvedScheme, .light)
        XCTAssertEqual(NSApp.appearance?.name, .aqua)
        XCTAssertNil(manager.effectiveAppearanceObservation)
    }

}
