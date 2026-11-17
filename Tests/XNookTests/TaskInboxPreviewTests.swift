import AppKit
import SwiftUI
import XCTest
@testable import XNook

@MainActor
final class TaskInboxPreviewTests: XCTestCase {
    func testInboxAndGridEntryRenderInBothLanguagesAndAppearances() async throws {
        guard ProcessInfo.processInfo.environment["XNOOK_RENDER_UI"] == "1" else {
            throw XCTSkip("需要隔离待办收件箱界面渲染")
        }
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("XNookInboxPreview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "XNook.InboxPreview.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        SettingsDefaults.register(on: defaults)
        let originalArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer {
            UserDefaults.standard.setVolatileDomain(originalArguments, forName: UserDefaults.argumentDomain)
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let pending = PendingTaskManager(storageURL: directory.appendingPathComponent("pending.json"))
        let focus = FocusSessionManager(userDefaults: defaults)
        let inbox = PendingTaskCoordinator(pending: pending, focus: focus)
        await inbox.prepare()
        for index in 0..<8 {
            let title = index == 0 ? String(repeating: "完整的待办标题 Long task title ", count: 5) : "待办 Task \(index + 1)"
            let added = await inbox.add(title: title)
            XCTAssertTrue(added)
        }
        let notes = NotesManager(storageURL: directory.appendingPathComponent("notes.json"))
        let tray = TrayManager(storageURL: directory.appendingPathComponent("tray.json"),
            resolveBookmark: { _ in nil }, makeBookmark: { _ in Data() })
        let resources = FocusResourceCoordinator(manager: focus, notes: notes, tray: tray)
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/feature-reintegration-20261024/ui/inbox")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for language in ["zh", "en"] {
            var arguments = originalArguments
            arguments["appLanguage"] = language
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            for scheme in [ColorScheme.dark, .light] {
                let suffix = "\(language)-\(scheme == .dark ? "dark" : "light")"
                try render(TaskInboxView(coordinator: inbox, onClose: {}), size: NSSize(width: 400, height: 420),
                    scheme: scheme, defaults: defaults, path: output.appendingPathComponent("inbox-\(suffix).png"))
                for section in [FocusSessionView.Section.currentTask, .recentTasks] {
                    let view = FocusSessionView(manager: focus, historyDisplayLimit: 3, trayFileCount: 0,
                        onCreateLinkedNote: { false }, onLinkTrayFiles: {}, onEndSession: {},
                        section: section, availableHeight: 116, resources: resources, pendingTasks: inbox)
                    try render(view, size: NSSize(width: 260, height: 136), scheme: scheme, defaults: defaults,
                        path: output.appendingPathComponent("grid-\(section == .currentTask ? "current" : "recent")-\(suffix).png"))
                }
            }
        }
        let first = try XCTUnwrap(pending.items.first)
        try await pending.markHandoff(id: first.id)
        defaults.set(Data("invalid history".utf8), forKey: "nookflow.sessions")
        await inbox.retryStorage()
        XCTAssertTrue(inbox.hasStorageIssue)
        XCTAssertEqual(inbox.visibleTasks.count, 8)
        try render(TaskInboxView(coordinator: inbox, onClose: {}), size: NSSize(width: 400, height: 420),
            scheme: .light, defaults: defaults, path: output.appendingPathComponent("inbox-blocked.png"))
        XCTAssertEqual(defaults.double(forKey: "panelBaseHeight"), 200)
    }

    private func render<Content: View>(_ content: Content, size: NSSize, scheme: ColorScheme,
                                      defaults: UserDefaults, path: URL) throws {
        let host = NSHostingView(rootView: content.frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme).defaultAppStorage(defaults))
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
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(host.bounds.size, size)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1000)
        try png.write(to: path, options: .atomic)
    }
}
