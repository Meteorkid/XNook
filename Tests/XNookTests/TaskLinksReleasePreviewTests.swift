import AppKit
import SwiftUI
import XCTest
@testable import XNook

@MainActor
final class TaskLinksReleasePreviewTests: XCTestCase {
    func testTaskLinksProtectAutomaticCollapseWithoutBlockingExplicitHandoff() {
        XCTAssertFalse(NotchContentView.allowsCollapse(isTaskLinksPresented: true, forced: false))
        XCTAssertTrue(NotchContentView.allowsCollapse(isTaskLinksPresented: true, forced: true))
        XCTAssertTrue(NotchContentView.allowsCollapse(isTaskLinksPresented: false, forced: false))
        XCTAssertTrue(NotchContentView.allowsCollapse(isTaskLinksPresented: false, forced: true))
    }

    func testFullLinksViewRendersActiveHistoryEditingAndWriteFailure() throws {
        guard ProcessInfo.processInfo.environment["XNOOK_RENDER_UI"] == "1" else { throw XCTSkip("需要隔离原生渲染") }
        _ = NSApplication.shared
        let suiteName = "XNookReleaseLinks.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let originalArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            UserDefaults.standard.setVolatileDomain(originalArguments, forName: UserDefaults.argumentDomain)
        }
        var failWrite = false
        let manager = FocusSessionManager(userDefaults: defaults, writeData: { data in
            if failWrite { throw CocoaError(.fileWriteNoPermission) }
            defaults.set(data, forKey: "nookflow.sessions")
        })
        let session = try XCTUnwrap(manager.start(title: "任务网页资料 · Task web resources"))
        guard case .added = manager.addTaskURL(urlString: "https://example.com/guide", title: "说明文档 · Guide", to: session.id) else {
            return XCTFail("创建链接失败")
        }
        let original = try XCTUnwrap(manager.activeSession?.taskURLs.first)
        var draft = TaskLinkEditDraft(link: original)
        draft.title = "已修改的标题 · Updated title"
        draft.address = "https://example.com/guide-updated"
        for state in ["active", "editing", "history", "write-failed"] {
            if state == "history" { XCTAssertTrue(manager.end()) }
            for language in ["zh", "en"] {
                var arguments = originalArguments
                arguments["appLanguage"] = language
                UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
                if state == "write-failed" {
                    XCTAssertTrue(manager.retryLoadingStorage())
                    failWrite = true
                    XCTAssertEqual(manager.editTaskURL(original, urlString: draft.address, title: draft.title, in: session.id), .saveFailed)
                }
                for scheme in [ColorScheme.light, .dark] {
                    let editing = state == "editing" || state == "write-failed"
                    let content = TaskLinksView(manager: manager, sessionID: session.id,
                        isEditing: .constant(editing), initialDraft: editing ? draft : nil)
                    try render(content, scheme: scheme, name: "links-\(state)-\(language)-\(scheme == .dark ? "dark" : "light")")
                }
            }
        }
        XCTAssertEqual(manager.session(id: session.id)?.taskURLs.first, original)
    }

    private func render<Content: View>(_ content: Content, scheme: ColorScheme, name: String) throws {
        let host = NSHostingView(rootView: content.background(IslandStyle.surface(for: scheme)).environment(\.colorScheme, scheme))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 420, height: 430),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(host.frame.size, NSSize(width: 420, height: 430))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/release-1.3.19-evidence/ui")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try png.write(to: output.appendingPathComponent(name + ".png"), options: .atomic)
    }
}
