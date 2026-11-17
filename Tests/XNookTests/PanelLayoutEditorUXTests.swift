import AppKit
import SwiftUI
import XCTest
@testable import XNook

@MainActor
final class PanelLayoutEditorUXTests: XCTestCase {
    func testToolbarHintsControlsAndHiddenModulesFitWithoutDirtyStateJump() throws {
        guard ProcessInfo.processInfo.environment["XNOOK_RENDER_UI"] == "1" else {
            throw XCTSkip("需要隔离布局编辑工具栏渲染")
        }
        _ = NSApplication.shared
        let originalArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(originalArguments, forName: UserDefaults.argumentDomain) }
        for language in ["zh", "en"] {
            var arguments = originalArguments
            arguments["appLanguage"] = language
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            for scheme in [ColorScheme.light, .dark] {
                for width: CGFloat in [160, 320, 800] {
                    try renderToolbar(width: width, scheme: scheme, language: language)
                }
            }
        }
    }

    private func renderToolbar(width: CGFloat, scheme: ColorScheme, language: String) throws {
        let suite = "XNookTests.LayoutEditorUX.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(try JSONEncoder().encode(Set(["media", "calendar", "tray"])), forKey: "enabledWidgets")
        defaults.set(false, forKey: "showNookFlowHistory")
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PanelLayoutStore(defaults: defaults)
        let editor = PanelLayoutEditingSession()
        editor.begin(from: store)
        let record = ToolbarGeometryRecord()
        let content = PanelLayoutEditorToolbar(editor: editor, selection: .constant(.media),
            onSave: { XCTFail("渲染不应保存") }, onCancel: { XCTFail("渲染不应取消") }, availableWidth: width,
            onShowLibrary: { XCTFail("渲染不应打开方案库") })
            .padding(8)
            .frame(width: width, alignment: .topLeading)
            .background(IslandStyle.surface(for: scheme))
            .environment(\.colorScheme, scheme)
            .environment(\.reportsExpandedPanelDebugGeometry, true)
            .coordinateSpace(name: "expandedPanelDebugGeometry")
            .onPreferenceChange(ExpandedPanelDebugGeometryKey.self) { record.frames = $0 }
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: 560),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        settle(host)
        let initialHeight = ceil(host.fittingSize.height)
        XCTAssertTrue(initialHeight.isFinite && initialHeight > 0)
        XCTAssertLessThanOrEqual(initialHeight, width < 260 ? 460 : 300,
            "工具栏应为编辑画布保留空间：\(language) / \(width) / \(initialHeight)")
        window.setContentSize(NSSize(width: width, height: initialHeight))
        host.frame = NSRect(x: 0, y: 0, width: width, height: initialHeight)
        settle(host)
        let toolbar = try XCTUnwrap(record.frames["panelLayoutEditor"])
        for key in ["panelLayoutHelp", "panelLayoutLibrary", "panelLayoutDefault", "panelLayoutCancel", "panelLayoutSave",
                    "panelLayoutModule", "panelLayoutWidth", "panelLayoutHeight", "panelLayoutVisible",
                    "panelLayoutEarlier", "panelLayoutLater", "panelLayoutHiddenModules"] {
            let frame = try XCTUnwrap(record.frames[key], key)
            XCTAssertTrue(toolbar.insetBy(dx: -1, dy: -1).contains(frame), "\(key) 超出工具栏：\(frame)")
        }
        XCTAssertLessThanOrEqual(toolbar.maxX, width + 1)
        try save(host, width: width, scheme: scheme, language: language, height: initialHeight, state: "ready")
        editor.draft.resize(.media, columns: 8, rows: 6)
        settle(host)
        XCTAssertTrue(editor.hasChanges)
        XCTAssertEqual(ceil(host.fittingSize.height), initialHeight, accuracy: 0.5,
            "首次拖动产生未保存状态时，固定工具栏不能改行导致画布跳动")
        XCTAssertNil(defaults.object(forKey: PanelLayoutStore.storageKey))
        XCTAssertFalse(window.isVisible)
        if width == 320 { try save(host, width: width, scheme: scheme, language: language, height: initialHeight, state: "changed") }
    }

    private func settle(_ host: NSView) {
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func save(_ host: NSView, width: CGFloat, scheme: ColorScheme,
                      language: String, height: CGFloat, state: String) throws {
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/panel-editor-overhaul-20261025/ui")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        let name = "toolbar-\(language)-\(scheme == .dark ? "dark" : "light")-\(Int(width))-\(state)"
        try XCTUnwrap(image.representation(using: .png, properties: [:]))
            .write(to: folder.appendingPathComponent(name + ".png"), options: .atomic)
        try JSONSerialization.data(withJSONObject: ["width": Double(width), "toolbarHeight": Double(height)],
            options: [.sortedKeys, .prettyPrinted])
            .write(to: folder.appendingPathComponent(name + ".json"), options: .atomic)
    }
}

@MainActor
private final class ToolbarGeometryRecord {
    var frames: [String: CGRect] = [:]
}
