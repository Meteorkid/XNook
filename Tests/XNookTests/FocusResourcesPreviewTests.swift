import AppKit
import SwiftUI
import XCTest
@testable import XNook

@MainActor
final class FocusResourcesPreviewTests: XCTestCase {
    func testTaskResourcesAndFullHistoryRenderWithScrollableOverflow() throws {
        guard ProcessInfo.processInfo.environment["XNOOK_RENDER_UI"] == "1" else {
            throw XCTSkip("Set XNOOK_RENDER_UI=1 for isolated resource rendering.")
        }
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("XNookFlowPreview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suiteName = "XNook.FlowPreview.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let notesURL = directory.appendingPathComponent("notes.json")
        try Data("[]".utf8).write(to: notesURL)
        let notes = NotesManager(storageURL: notesURL)
        let tray = TrayManager(storageURL: directory.appendingPathComponent("tray.json"), resolveBookmark: { _ in nil }, makeBookmark: { _ in Data() })
        let manager = FocusSessionManager(userDefaults: defaults)
        for index in 0..<9 {
            XCTAssertNotNil(manager.start(title: "历史任务 \(index + 1)：完整名称与任务资料可在详情中查看"))
            XCTAssertTrue(manager.end())
        }
        let session = try XCTUnwrap(manager.start(title: "整理项目资料：确认笔记删除后可以重新关联，文件架清空后仍保留访问凭据"))
        manager.linkNote(id: UUID(), title: "这篇笔记已删除，需要在资料中选择重新关联")
        let files = (0..<8).map { index in
            LinkedFile(id: UUID(), name: "第\(index + 1)份关联资料：完整文件名称不会因经典面板高度限制而丢失.pdf", icon: "doc.richtext", bookmarkData: Data([UInt8(index)]))
        }
        XCTAssertTrue(manager.linkFiles(files, to: session.id))
        let resources = FocusResourceCoordinator(manager: manager, notes: notes, tray: tray)
        XCTAssertFalse(resources.openNote(in: session.id))

        for scheme in [ColorScheme.dark, .light] {
            let suffix = scheme == .dark ? "dark" : "light"
            let detail = FocusSessionResourcesView(sessionID: session.id, resources: resources, showsNoteEditor: .constant(false))
            try render(detail, scheme: scheme, name: "resources-top-\(suffix)")
            try render(detail, scheme: scheme, name: "resources-bottom-\(suffix)", scrollToBottom: true)
            try render(FocusSessionHistoryView(resources: resources, showsNoteEditor: .constant(false)), scheme: scheme,
                       name: "history-bottom-\(suffix)", scrollToBottom: true)
        }
    }

    private func render<V: View>(_ content: V, scheme: ColorScheme, name: String, scrollToBottom: Bool = false) throws {
        let size = NSSize(width: 420, height: 430)
        let host = NSHostingView(rootView: content.background(IslandStyle.surface(for: scheme)).environment(\.colorScheme, scheme))
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
        let scroll = try XCTUnwrap(scrollViews(in: host).first)
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThan(document.bounds.height, scroll.contentView.bounds.height)
        if scrollToBottom {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: document.bounds.height - scroll.contentView.bounds.height))
            scroll.reflectScrolledClipView(scroll.contentView)
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, 0)
        }
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/feature-reintegration-20261024/ui/focus-resources")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try png.write(to: output.appendingPathComponent(name + ".png"), options: .atomic)
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }
}
