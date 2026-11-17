import AppKit
import EventKit
import ServiceManagement
import SwiftUI
import XCTest
@testable import XNook

@MainActor
final class PanelSizingSettingsTests: XCTestCase {
    func testRegistrationKeepsHeightModeUnwrittenAndPreservesLegacyValues() throws {
        let suite = "XNook.PanelSizingDefaults.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "panelAutoSize")
        defaults.set(365.5, forKey: "panelBaseHeight")
        let before = try XCTUnwrap(defaults.persistentDomain(forName: suite))
        SettingsDefaults.register(on: defaults)
        XCTAssertEqual(defaults.string(forKey: "panelHeightMode"), "")
        XCTAssertEqual(defaults.double(forKey: "panelBaseHeight"), 365.5)
        XCTAssertEqual(PanelHeightMode.resolved(storedValue: defaults.string(forKey: "panelHeightMode") ?? "",
            legacyAutomaticallyFit: defaults.bool(forKey: "panelAutoSize")), .limited)
        XCTAssertEqual(NSDictionary(dictionary: defaults.persistentDomain(forName: suite) ?? [:]), NSDictionary(dictionary: before))
        XCTAssertNil(defaults.persistentDomain(forName: suite)?["panelHeightMode"])
        XCTAssertNil(defaults.object(forKey: "panelMaxHeight"))
    }

    func testWidthToggleFixesLegacyHeightModeBeforeChangingWidthPreference() {
        for legacyWidth in [false, true] {
            var width = legacyWidth
            var rawMode = ""
            var writes: [String] = []
            let binding = SettingsView.widthAdaptationBinding(
                automaticallyFit: Binding(get: { width }, set: { width = $0; writes.append("width") }),
                heightMode: Binding(get: { rawMode }, set: { rawMode = $0; writes.append("height") })
            )
            XCTAssertEqual(binding.wrappedValue, legacyWidth)
            XCTAssertTrue(writes.isEmpty, "读取设置不得隐式迁移")
            binding.wrappedValue = !legacyWidth
            XCTAssertEqual(writes, ["height", "width"])
            XCTAssertEqual(rawMode, legacyWidth ? "automatic" : "limited")
            XCTAssertEqual(PanelHeightMode.resolved(storedValue: rawMode, legacyAutomaticallyFit: width),
                legacyWidth ? .automatic : .limited)
        }
    }

    func testWidthToggleDoesNotRewriteExplicitHeightOrPersistANoOp() {
        var width = true
        var rawMode = PanelHeightMode.limited.rawValue
        var heightWrites = 0
        var widthWrites = 0
        let binding = SettingsView.widthAdaptationBinding(
            automaticallyFit: Binding(get: { width }, set: { width = $0; widthWrites += 1 }),
            heightMode: Binding(get: { rawMode }, set: { rawMode = $0; heightWrites += 1 })
        )
        binding.wrappedValue = true
        XCTAssertEqual(widthWrites, 0)
        binding.wrappedValue = false
        XCTAssertEqual(widthWrites, 1)
        XCTAssertEqual(heightWrites, 0)
        XCTAssertEqual(rawMode, PanelHeightMode.limited.rawValue)
    }

    func testHeightSearchReachesUniqueDisplayTargetInBothLanguages() throws {
        let original = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
        for language in ["zh", "en"] {
            var arguments = original
            arguments["appLanguage"] = language
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            for query in ["高度", "自动 高度", "手动 高度", "最大高度", "panel height", "manual height", "maximum height"] {
                let entry = try XCTUnwrap(SettingsSearchEntry.matches(query).first { $0.id == "panelHeightMode" }, query)
                XCTAssertEqual(entry.pane, .display)
            }
            XCTAssertEqual(SettingsSearchEntry.matches("panelHeightMode").first?.id, "panelHeightMode")
            XCTAssertEqual(Set(SettingsSearchEntry.all.map(\.id)).count, SettingsSearchEntry.all.count)
        }
    }

    func testHeightModesRenderInActualSettingsWithIsolatedPreferences() throws {
        guard ProcessInfo.processInfo.environment["XNOOK_RENDER_UI"] == "1" else {
            throw XCTSkip("需要隔离面板尺寸设置界面渲染")
        }
        _ = NSApplication.shared
        let originalArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        let originalAppearance = NSApp.appearance
        defer {
            UserDefaults.standard.setVolatileDomain(originalArguments, forName: UserDefaults.argumentDomain)
            NSApp.appearance = originalAppearance
        }
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/panel-sizing-editor-20261025/ui")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for language in ["zh", "en"] {
            // 语言只覆盖测试进程的 argumentDomain，所有面板设置仍走独立 suite。
            var arguments = originalArguments
            arguments["appLanguage"] = language
            arguments["selectedGifName"] = ""
            arguments["customGifList"] = [String]()
            arguments["customGifBookmark"] = Data()
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            for scheme in [ColorScheme.dark, .light] {
                for mode in PanelHeightMode.allCases {
                    let suite = "XNook.PanelSizingPreview.\(UUID().uuidString)"
                    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
                    SettingsDefaults.register(on: defaults)
                    defaults.set(true, forKey: "reduceMotion")
                    defaults.set(mode.rawValue, forKey: "panelHeightMode")
                    defaults.set(320.0, forKey: "panelBaseHeight")
                    let search = SettingsSearchState()
                    let permissions = SettingsPermissions(readCalendar: { .notDetermined }, readLoginItems: { .notRegistered })
                    let receiver = ClaudeCompletionReceiver(deliver: { _ in XCTFail("设置预览不得接入事件") })
                    let shortcut = GlobalPanelShortcutController(defaults: defaults, backend: TestGlobalPanelShortcutBackend())
                    let theme = ThemeManager(defaults: defaults)
                    let updates = UpdateManager(fetchReleaseData: { XCTFail("设置预览不得联网"); throw URLError(.notConnectedToInternet) })
                    let geometry = PanelSizingGeometryRecord()
                    let host = NSHostingView(rootView: SettingsView(layoutDefaults: defaults, search: search,
                        permissions: permissions, claudeReceiver: receiver, globalPanelShortcut: shortcut)
                        .environment(theme).environment(updates).defaultAppStorage(defaults)
                        .environment(\.colorScheme, scheme).frame(width: 560, height: 620)
                        .coordinateSpace(name: "expandedPanelDebugGeometry")
                        .environment(\.reportsExpandedPanelDebugGeometry, true)
                        .onPreferenceChange(ExpandedPanelDebugGeometryKey.self) { geometry.frames = $0 })
                    let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 560, height: 620),
                        styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                    window.contentView = host
                    defer {
                        theme.stopObservingSystemAppearance()
                        receiver.shutdown()
                        shortcut.shutdown()
                        window.contentView = nil
                        window.close()
                        defaults.removePersistentDomain(forName: suite)
                    }
                    settle(host)
                    search.navigate(to: try XCTUnwrap(SettingsSearchEntry.all.first { $0.id == "panelHeightMode" }))
                    settle(host)
                    let viewport = try XCTUnwrap(geometry.frames["settingsViewport"])
                    for id in ["setting-panelHeightMode", "setting-panelBaseHeight", "settingsPanelHeightStatus"] {
                        let frame = try XCTUnwrap(geometry.frames[id], id)
                        XCTAssertGreaterThan(frame.height, 0)
                        XCTAssertGreaterThanOrEqual(frame.minY, viewport.minY - 1, id)
                        XCTAssertLessThanOrEqual(frame.maxY, viewport.maxY + 1, id)
                    }
                    XCTAssertEqual(defaults.string(forKey: "panelHeightMode"), mode.rawValue)
                    XCTAssertEqual(defaults.double(forKey: "panelBaseHeight"), 320)
                    XCTAssertFalse(window.isVisible)
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    let name = "panel-height-\(mode.rawValue)-\(language)-\(scheme == .dark ? "dark" : "light").png"
                    try png.write(to: output.appendingPathComponent(name), options: .atomic)
                }
            }
        }
    }

    private func settle(_ host: NSView) {
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.025))
        }
    }
}

private final class PanelSizingGeometryRecord {
    var frames: [String: CGRect] = [:]
}
