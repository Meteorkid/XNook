import AppKit
import SwiftUI
import XCTest
@testable import XNook

@MainActor
final class PanelLayoutLibraryViewTests: XCTestCase {
    func testFailedApplyKeepsLibraryOpenAndReportsError() throws {
        try withStore { store, _ in
            let session = PanelLayoutLibrarySession(currentLayout: PanelLayoutTemplate.standard.configuration, store: store)
            session.selection = .template(.focus)
            var received: PanelLayoutConfiguration?
            var didClose = false
            session.requestApply(store: store, currentLayout: PanelLayoutTemplate.standard.configuration,
                                 hasUnsavedChanges: false, onApply: {
                received = $0
                throw ApplyFailure.rejected
            }, onClose: { didClose = true })
            XCTAssertEqual(received, PanelLayoutTemplate.focus.configuration)
            XCTAssertEqual(session.errorMessage, "Application failed")
            XCTAssertFalse(didClose)
        }
    }

    func testDirtyDraftRequiresConfirmationAndCancelDoesNotApply() throws {
        try withStore { store, _ in
            let current = PanelLayoutTemplate.standard.configuration
            let session = PanelLayoutLibrarySession(currentLayout: current, store: store)
            session.selection = .template(.focus)
            var applications: [PanelLayoutConfiguration] = []
            var closeCount = 0
            session.requestApply(store: store, currentLayout: current, hasUnsavedChanges: true,
                                 onApply: { applications.append($0) }, onClose: { closeCount += 1 })
            XCTAssertNotNil(session.pendingAction)
            XCTAssertTrue(applications.isEmpty)
            session.pendingAction = nil
            session.confirmPendingAction(store: store, currentLayout: current,
                                         onApply: { applications.append($0) }, onClose: { closeCount += 1 })
            XCTAssertTrue(applications.isEmpty)
            XCTAssertEqual(closeCount, 0)
            session.requestApply(store: store, currentLayout: current, hasUnsavedChanges: true,
                                 onApply: { applications.append($0) }, onClose: { closeCount += 1 })
            let confirmedAction = try XCTUnwrap(session.pendingAction)
            // SwiftUI 可能先清除 alert binding；按钮捕获的确认内容仍必须执行一次。
            session.pendingAction = nil
            session.confirmPendingAction(confirmedAction, store: store, currentLayout: current,
                                         onApply: { applications.append($0) }, onClose: { closeCount += 1 })
            XCTAssertEqual(applications, [PanelLayoutTemplate.focus.configuration])
            XCTAssertEqual(closeCount, 1)
        }
    }

    func testRenameFailurePreservesInputForCorrection() throws {
        try withStore { store, _ in
            let first = try store.saveNew(configuration: PanelLayoutTemplate.standard.configuration, name: "First")
            let second = try store.saveNew(configuration: PanelLayoutTemplate.focus.configuration, name: "Second")
            let session = PanelLayoutLibrarySession(currentLayout: first.configuration, store: store)
            session.beginRename(first)
            session.renameText = second.name
            session.saveRename(store: store)
            XCTAssertEqual(session.renamingID, first.id)
            XCTAssertEqual(session.renameText, "Second")
            XCTAssertNotNil(session.errorMessage)
            XCTAssertEqual(store.profiles.first?.name, "First")
            session.renameText = "Corrected"
            session.saveRename(store: store)
            XCTAssertNil(session.renamingID)
            XCTAssertNil(session.errorMessage)
            XCTAssertEqual(store.profiles.first?.name, "Corrected")
        }
    }

    func testUpdateAndDeleteOnlyMutateLibraryAfterConfirmation() throws {
        try withStore { store, _ in
            let original = try store.saveNew(configuration: PanelLayoutTemplate.standard.configuration)
            let session = PanelLayoutLibrarySession(currentLayout: original.configuration, store: store)
            session.pendingAction = .update(original.id)
            XCTAssertEqual(store.profiles.first?.configuration, original.configuration)
            session.confirmPendingAction(store: store, currentLayout: PanelLayoutTemplate.media.configuration,
                                         onApply: { _ in XCTFail("方案更新不能应用面板") }, onClose: { XCTFail("方案更新不能关闭库") })
            XCTAssertEqual(store.profiles.first?.configuration, PanelLayoutTemplate.media.configuration)
            session.pendingAction = .delete(original.id)
            XCTAssertEqual(store.profiles.count, 1)
            session.confirmPendingAction(store: store, currentLayout: original.configuration,
                                         onApply: { _ in XCTFail("方案删除不能应用面板") }, onClose: { XCTFail("方案删除不能关闭库") })
            XCTAssertTrue(store.profiles.isEmpty)
            XCTAssertEqual(session.selection, .template(.standard))
        }
    }

    func testUnreadableLibraryLeavesSavedBytesUntouchedAndAllowsTemplatePreview() throws {
        try withStore { store, defaults in
            let broken = Data("not a library".utf8)
            defaults.set(broken, forKey: PanelLayoutProfileStore.storageKey)
            store.reload()
            let session = PanelLayoutLibrarySession(currentLayout: PanelLayoutTemplate.standard.configuration, store: store)
            session.selection = .template(.focus)
            XCTAssertEqual(session.configuration(in: store), PanelLayoutTemplate.focus.configuration)
            session.saveCurrent(PanelLayoutTemplate.media.configuration, store: store)
            XCTAssertNotNil(session.errorMessage)
            XCTAssertFalse(store.canEdit)
            XCTAssertEqual(defaults.data(forKey: PanelLayoutProfileStore.storageKey), broken)
        }
    }

    func testSaveCurrentSelectsNewProfileAndReportsSuccessWithoutApplying() throws {
        try withStore { store, _ in
            let current = PanelLayoutTemplate.media.configuration
            let session = PanelLayoutLibrarySession(currentLayout: current, store: store)
            session.saveCurrent(current, store: store)
            let profile = try XCTUnwrap(store.profiles.first)
            XCTAssertEqual(profile.configuration, current)
            XCTAssertEqual(session.selection, .saved(profile.id))
            XCTAssertNotNil(session.statusMessage)
            XCTAssertNil(session.errorMessage)
        }
    }

    func testLightDarkLongNamesAndReadOnlyErrorRenderWithinFixedLibrary() throws {
        guard ProcessInfo.processInfo.environment["XNOOK_RENDER_UI"] == "1" else {
            throw XCTSkip("需要隔离布局方案库渲染")
        }
        _ = NSApplication.shared
        for scheme in [ColorScheme.light, .dark] {
            try withStore { store, defaults in
                _ = try store.saveNew(configuration: PanelLayoutTemplate.standard.configuration,
                                      name: String(repeating: "我的日常布局", count: 6))
                _ = try store.saveNew(configuration: PanelLayoutTemplate.focus.configuration,
                                      name: "Long layout name for concentrated work")
                try render(store: store, scheme: scheme, state: "layouts", scrollToEnd: false)
                try render(store: store, scheme: scheme, state: "long-names", scrollToEnd: true)
                defaults.set(Data("invalid".utf8), forKey: PanelLayoutProfileStore.storageKey)
                store.reload()
                try render(store: store, scheme: scheme, state: "read-only", scrollToEnd: false)
            }
        }
    }

    private func render(store: PanelLayoutProfileStore, scheme: ColorScheme,
                        state: String, scrollToEnd: Bool) throws {
        let record = LibraryGeometryRecord()
        let content = PanelLayoutLibraryView(store: store, currentLayout: PanelLayoutTemplate.standard.configuration,
                                            isEditing: true, hasUnsavedChanges: true,
                                            onApply: { _ in XCTFail("渲染不能应用布局") }, onClose: { XCTFail("渲染不能关闭") })
            .environment(\.colorScheme, scheme)
            .environment(\.reportsExpandedPanelDebugGeometry, true)
            .coordinateSpace(name: "expandedPanelDebugGeometry")
            .onPreferenceChange(ExpandedPanelDebugGeometryKey.self) { record.frames = $0 }
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 520, height: 440),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        settle(host)
        if scrollToEnd {
            let scroll = try XCTUnwrap(findScrollView(in: host))
            let document = try XCTUnwrap(scroll.documentView)
            document.scroll(NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
            settle(host)
        }
        XCTAssertEqual(host.fittingSize.width, 520, accuracy: 0.5)
        XCTAssertEqual(host.fittingSize.height, 440, accuracy: 0.5)
        let library = try XCTUnwrap(record.frames["panelLayoutLibrary"])
        let header = try XCTUnwrap(record.frames["panelLayoutLibraryHeader"])
        let footer = try XCTUnwrap(record.frames["panelLayoutLibraryFooter"])
        let scroll = try XCTUnwrap(record.frames["panelLayoutLibraryScroll"])
        XCTAssertTrue(library.contains(header))
        XCTAssertTrue(library.contains(footer))
        XCTAssertLessThanOrEqual(header.maxY, scroll.minY + 1)
        XCTAssertLessThanOrEqual(scroll.maxY, footer.minY + 1)
        for (key, frame) in record.frames where key.hasPrefix("panelLayoutLibraryRow-") {
            XCTAssertGreaterThanOrEqual(frame.minX, library.minX)
            XCTAssertLessThanOrEqual(frame.maxX, library.maxX, "长名称不能撑宽卡片：\(key)")
        }
        XCTAssertFalse(window.isVisible)
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/layout-profiles-20261026/ui")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let name = "library-\(scheme == .dark ? "dark" : "light")-\(state)"
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: folder.appendingPathComponent(name + ".png"), options: .atomic)
        try JSONSerialization.data(withJSONObject: ["width": 520, "height": 440,
            "headerHeight": Double(header.height), "footerHeight": Double(footer.height),
            "scrollHeight": Double(scroll.height), "readOnly": !store.canEdit], options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent(name + ".json"), options: .atomic)
    }

    private func settle(_ host: NSView) {
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func findScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.findScrollView(in: $0) }.first
    }

    private func withStore(_ body: (PanelLayoutProfileStore, UserDefaults) throws -> Void) throws {
        let suite = "XNookTests.LayoutLibrary.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(PanelLayoutProfileStore(defaults: defaults), defaults)
    }
}

private enum ApplyFailure: LocalizedError {
    case rejected
    var errorDescription: String? { "Application failed" }
}

@MainActor
private final class LibraryGeometryRecord {
    var frames: [String: CGRect] = [:]
}
