import AppKit
import EventKit
import ServiceManagement
import SwiftUI
import XCTest
@testable import XNook

@MainActor
final class SettingsDiscoveryPreviewTests: XCTestCase {
    func testSearchResultsAndNavigationReachRealControlsInBothLanguagesAndAppearances() throws {
        #if !DEBUG
        throw XCTSkip("设置行几何断言仅在 Debug 构建启用")
        #endif
        guard ProcessInfo.processInfo.environment["XNOOK_RENDER_UI"] == "1" else { throw XCTSkip("需要隔离设置界面渲染") }
        _ = NSApplication.shared
        let suite = "XNook.SettingsDiscoveryPreview.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        SettingsDefaults.register(on: defaults)
        defaults.set(true, forKey: "reduceMotion")
        let original = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer {
            UserDefaults.standard.setVolatileDomain(original, forName: UserDefaults.argumentDomain)
            defaults.removePersistentDomain(forName: suite)
        }
        let output = ProcessInfo.processInfo.environment["XNOOK_UI_EVIDENCE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/mac-settings-evidence/ui")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for language in ["zh", "en"] {
            var arguments = original
            arguments["appLanguage"] = language
            arguments["selectedGifName"] = ""
            arguments["customGifList"] = [String]()
            arguments["customGifBookmark"] = Data()
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            for scheme in [ColorScheme.dark, .light] {
                let search = SettingsSearchState()
                var loginStatus = SMAppService.Status.requiresApproval
                let permissions = SettingsPermissions(readCalendar: { .writeOnly }, readLoginItems: { loginStatus })
                let theme = ThemeManager(defaults: defaults)
                let updates = UpdateManager(fetchReleaseData: { XCTFail("设置测试不得联网检查更新"); throw URLError(.notConnectedToInternet) })
                let geometry = SettingsGeometryRecord()
                let receiver = ClaudeCompletionReceiver(deliver: { _ in XCTFail("设置预览不应接收事件") })
                let host = NSHostingView(rootView: SettingsView(layoutDefaults: defaults, search: search,
                    permissions: permissions, claudeReceiver: receiver)
                    .environment(theme).environment(updates).defaultAppStorage(defaults)
                    .environment(\.colorScheme, scheme).frame(width: 560, height: 550)
                    .coordinateSpace(name: "expandedPanelDebugGeometry")
                    .environment(\.reportsExpandedPanelDebugGeometry, true)
                    .onPreferenceChange(ExpandedPanelDebugGeometryKey.self) { geometry.frames = $0 })
                let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 560, height: 550),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                window.contentView = host
                defer { theme.stopObservingSystemAppearance(); window.contentView = nil; window.close() }
                let suffix = "\(language)-\(scheme == .dark ? "dark" : "light")"
                settle(host)
                XCTAssertEqual(permissions.loginItems, .requiresApproval)
                loginStatus = .enabled
                defaults.set(true, forKey: "launchAtLogin")
                settle(host)
                XCTAssertEqual(permissions.loginItems, .allowed, "本页切换登录项后应重新读取系统状态")
                loginStatus = .requiresApproval
                defaults.set(false, forKey: "launchAtLogin")
                settle(host)
                XCTAssertEqual(permissions.loginItems, .requiresApproval)
                search.query = language == "zh" ? "高度" : "height"
                settle(host)
                XCTAssertTrue(search.results.contains { $0.id == "panelBaseHeight" })
                try capture(host, at: output.appendingPathComponent("search-\(suffix).png"))

                let ids = ["panelBaseHeight", "lyricsOffset", "expandedInactivity", "permissionCalendar",
                    "islandBackgroundStyle", "islandGlassDepth", "panelLayoutEditor", "panelAutoSize",
                    "activityNotificationsEnabled", "calendarReminderActivityEnabled", "claudeCompletionEnabled", "globalPanelShortcut"]
                for id in ids {
                    // 在真实渲染树中切换页和目标，不能仅以索引中存在这个 ID 判定定位成功。
                    search.query = id
                    settle(host)
                    let entry = try XCTUnwrap(search.results.first { $0.id == id })
                    search.navigate(to: entry)
                    settle(host)
                    let viewport = try XCTUnwrap(geometry.frames["settingsViewport"])
                    let target = try XCTUnwrap(geometry.frames["setting-" + id], "目标必须来自真实设置行")
                    let highlight = try XCTUnwrap(geometry.frames["setting-highlight-" + id], "目标行必须高亮")
                    XCTAssertGreaterThan(target.width, 0)
                    XCTAssertGreaterThan(target.height, 0)
                    XCTAssertGreaterThanOrEqual(target.minY, viewport.minY - 1, id)
                    XCTAssertLessThanOrEqual(target.maxY, viewport.maxY + 1, id)
                    XCTAssertEqual(highlight.minY, target.minY, accuracy: 1, id)
                    XCTAssertEqual(highlight.height, target.height, accuracy: 1, id)
                    XCTAssertEqual(search.targetID, id)
                    if id == "islandGlassDepth" {
                        XCTAssertEqual(defaults.string(forKey: "islandBackgroundStyle"), IslandBackgroundStyle.solid.rawValue,
                            "搜索隐藏控件不得自动切换用户的背景预设")
                    }
                    try capture(host, at: output.appendingPathComponent("\(id)-\(suffix).png"))
                }
                search.query = "not-a-setting"
                settle(host)
                XCTAssertTrue(search.results.isEmpty)
                XCTAssertNil(search.targetID)
                XCTAssertFalse(window.isVisible)
            }
        }
        XCTAssertEqual(defaults.double(forKey: "panelBaseHeight"), 200)
        XCTAssertEqual(defaults.double(forKey: "panelWidth"), 800)
    }

    private func settle(_ host: NSView) {
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.025))
        }
    }

    private func capture(_ host: NSView, at url: URL) throws {
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: url, options: .atomic)
    }
}


private final class SettingsGeometryRecord {
    var frames: [String: CGRect] = [:]
}
