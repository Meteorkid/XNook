import AppKit
import SwiftUI
import XCTest
@testable import XNook

@MainActor
final class TaskResourcesPreviewTests: XCTestCase {
    func testLinksBudgetAndOverdueCardRenderInBothLanguagesAndAppearances() throws {
        guard ProcessInfo.processInfo.environment["XNOOK_RENDER_UI"] == "1" else {
            throw XCTSkip("需要隔离任务链接与预算界面渲染")
        }
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("XNookTaskResources-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "XNook.TaskResourcesPreview.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let originalArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer {
            UserDefaults.standard.setVolatileDomain(originalArguments, forName: UserDefaults.argumentDomain)
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let notes = NotesManager(storageURL: directory.appendingPathComponent("notes.json"))
        let tray = TrayManager(storageURL: directory.appendingPathComponent("tray.json"),
            resolveBookmark: { _ in nil }, makeBookmark: { _ in Data() })
        let manager = FocusSessionManager(userDefaults: defaults)
        let session = try XCTUnwrap(manager.start(title: "验证任务链接与时间计划 · Review linked resources"))
        guard case .added = manager.addTaskURL(urlString: "https://example.com/guide?section=tasks",
            title: "任务说明 · Task guide", to: session.id) else { return XCTFail("链接未保存") }
        XCTAssertTrue(manager.setTimeBudget(minutes: 1, for: session.id, now: Date().addingTimeInterval(-120)))
        let resources = FocusResourceCoordinator(manager: manager, notes: notes, tray: tray,
            openURL: { _ in XCTFail("渲染不能打开浏览器"); return false })
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/feature-reintegration-20261024/ui/task-resources")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for language in ["zh", "en"] {
            var arguments = originalArguments
            arguments["appLanguage"] = language
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            for scheme in [ColorScheme.dark, .light] {
                let suffix = "\(language)-\(scheme == .dark ? "dark" : "light")"
                for bottom in [false, true] {
                    try render(FocusSessionResourcesView(sessionID: session.id, resources: resources, showsNoteEditor: .constant(false)),
                        size: NSSize(width: 420, height: 430), scheme: scheme, defaults: defaults,
                        path: output.appendingPathComponent("resources-\(bottom ? "bottom" : "top")-\(suffix).png"), scrollBottom: bottom)
                }
                try render(FocusSessionView(manager: manager, historyDisplayLimit: 3, trayFileCount: 0,
                    onCreateLinkedNote: { false }, onLinkTrayFiles: {}, onEndSession: {},
                    section: .currentTask, availableHeight: 116, resources: resources),
                    size: NSSize(width: 260, height: 136),
                    scheme: scheme, defaults: defaults, path: output.appendingPathComponent("overdue-card-\(suffix).png"))
            }
        }
        XCTAssertFalse(resources.addTaskURL(urlString: "javascript:alert(1)", title: "", to: session.id))
        try render(FocusSessionResourcesView(sessionID: session.id, resources: resources, showsNoteEditor: .constant(false)),
            size: NSSize(width: 420, height: 430), scheme: .light, defaults: defaults,
            path: output.appendingPathComponent("resources-invalid-link.png"), scrollBottom: true)
        XCTAssertTrue(manager.end())
        resources.clearError()
        try render(FocusSessionResourcesView(sessionID: session.id, resources: resources, showsNoteEditor: .constant(false)),
            size: NSSize(width: 420, height: 430), scheme: .light, defaults: defaults,
            path: output.appendingPathComponent("resources-history.png"), scrollBottom: true)
    }

    private func render<Content: View>(_ content: Content, size: NSSize, scheme: ColorScheme,
                                      defaults: UserDefaults, path: URL, scrollBottom: Bool = false) throws {
        let host = NSHostingView(rootView: content.frame(width: size.width, height: size.height)
            .background(IslandStyle.surface(for: scheme)).environment(\.colorScheme, scheme).defaultAppStorage(defaults))
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        if scrollBottom {
            let scroll = try XCTUnwrap(scrollViews(in: host).first)
            let document = try XCTUnwrap(scroll.documentView)
            XCTAssertGreaterThan(document.bounds.height, scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: document.bounds.height - scroll.contentView.bounds.height))
            scroll.reflectScrolledClipView(scroll.contentView)
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, 0)
        }
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(host.bounds.size, size)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1000)
        try png.write(to: path, options: .atomic)
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }
}
