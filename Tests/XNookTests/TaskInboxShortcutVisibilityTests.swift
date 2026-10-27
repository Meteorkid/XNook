import AppKit
import Observation
import SwiftUI
import XCTest
@testable import XNook

/// 真实面板离屏渲染；偏好、待办和业务夹具均隔离，不展示窗口或访问个人资料。
@MainActor
final class TaskInboxShortcutVisibilityTests: XCTestCase {
    func testShortcutVisibilityResizesPanelAndPreservesTasksAndLayout() async throws {
        #if !DEBUG
        throw XCTSkip("真实面板几何探针需要 Debug 构建")
        #endif
        guard ProcessInfo.processInfo.environment["XNOOK_RENDER_UI"] == "1" else {
            throw XCTSkip("使用 XNOOK_RENDER_UI=1 渲染隔离的待办入口回归")
        }
        _ = NSApplication.shared
        for populated in [false, true] {
            let fixture = try WorkflowPreviewFixture(historyCount: populated ? 1 : 0,
                trayFileCount: 0, mediaHasContent: false, calendarEventTitles: [], calendarDayOffset: 0)
            defer { fixture.cleanUp() }
            fixture.defaults.set(false, forKey: "showLyrics")
            fixture.defaults.set(true, forKey: "panelAutoSize")
            fixture.defaults.set(PanelHeightMode.automatic.rawValue, forKey: "panelHeightMode")
            fixture.defaults.set(IslandBackgroundStyle.solid.rawValue, forKey: "islandBackgroundStyle")
            if !populated {
                try Data("[]".utf8).write(to: fixture.directory.appendingPathComponent("notes.json"))
                fixture.notes.loadNotes()
            }
            let pendingURL = fixture.directory.appendingPathComponent("pending.json")
            try Data(#"{"version":1,"items":[]}"#.utf8).write(to: pendingURL)
            let pending = PendingTaskCoordinator(pending: PendingTaskManager(storageURL: pendingURL), focus: fixture.focus)
            await pending.prepare()
            if populated {
                let added = await pending.add(title: "待办入口回归：保留任务内容")
                XCTAssertTrue(added)
            }
            XCTAssertFalse(pending.hasStorageIssue)
            XCTAssertEqual(pending.visibleTasks.count, populated ? 1 : 0)
            let originalPending = try Data(contentsOf: pendingURL)
            let originalSessions = fixture.defaults.data(forKey: "nookflow.sessions")
            let store = PanelLayoutStore(defaults: fixture.defaults)
            for taskModule in [nil, PanelModuleID.currentTask, .recentTasks] {
                var configuration = PanelLayoutConfiguration.legacy(enabledWidgetIDs: ["notes"], showHistory: false)
                configuration.setVisible(.currentTask, visible: false)
                if let taskModule { configuration.setVisible(taskModule, visible: true) }
                configuration.fitsContent = true
                try store.save(configuration)
                try renderToggleCycle(fixture: fixture, store: store, pending: pending,
                    taskModule: taskModule, populated: populated, pendingURL: pendingURL,
                    originalPending: originalPending, originalSessions: originalSessions)
            }
        }
    }

    private func renderToggleCycle(fixture: WorkflowPreviewFixture, store: PanelLayoutStore,
                                  pending: PendingTaskCoordinator, taskModule: PanelModuleID?, populated: Bool,
                                  pendingURL: URL, originalPending: Data, originalSessions: Data?) throws {
        fixture.defaults.set(true, forKey: "showTaskInboxShortcut")
        let originalLayout = try XCTUnwrap(fixture.defaults.data(forKey: PanelLayoutStore.storageKey))
        let model = InboxShortcutPreviewModel()
        let record = InboxShortcutPreviewRecord()
        let resources = FocusResourceCoordinator(manager: fixture.focus, notes: fixture.notes, tray: fixture.tray)
        let host = NSHostingView(rootView: InboxShortcutPreviewSurface(fixture: fixture, store: store,
            pending: pending, resources: resources, model: model, record: record))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: model.width, height: model.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        var heights: [CGFloat] = []
        var measurements: [CGFloat] = []
        var firstShortcutFrame: CGRect?
        for (phase, enabled) in [true, false, true].enumerated() {
            fixture.defaults.set(enabled, forKey: "showTaskInboxShortcut")
            settle(host)
            let measured = try XCTUnwrap(record.measurement)
            model.height = ExpandedPanelLayout.height(measuredContentHeight: measured.height, maximumHeight: 1600)
            window.setContentSize(NSSize(width: model.width, height: model.height))
            settle(host)
            XCTAssertFalse(window.isVisible)
            XCTAssertEqual(host.bounds.height, model.height, accuracy: 0.5)
            XCTAssertEqual(record.measurement?.height ?? 0, measured.height, accuracy: 0.5)
            XCTAssertEqual(measured.layoutSignature,
                PanelGridGeometry.measurementSignature(for: store.configuration, fitsContent: true))
            let bounds = CGRect(x: 0, y: 0, width: model.width, height: model.height)
            let body = try XCTUnwrap(record.frames["expandedPanelBody"])
            assertVisible(body, inside: bounds)
            if enabled && taskModule == nil {
                let shortcut = try XCTUnwrap(record.frames["panelTaskInboxFallback"])
                assertVisible(shortcut, inside: body)
                let notes = try XCTUnwrap(record.frames["panelModule-notes"])
                XCTAssertGreaterThanOrEqual(shortcut.minY, notes.maxY)
                if phase == 0 { firstShortcutFrame = shortcut }
                if phase == 2 { XCTAssertEqual(shortcut, firstShortcutFrame) }
            } else {
                XCTAssertNil(record.frames["panelTaskInboxFallback"], "隐藏入口必须移出布局，不能仅改变透明度")
            }
            if let taskModule {
                let module = try XCTUnwrap(record.frames["panelModule-\(taskModule.rawValue)"])
                assertVisible(module, inside: body)
            }
            XCTAssertEqual(try Data(contentsOf: pendingURL), originalPending)
            XCTAssertEqual(fixture.defaults.data(forKey: "nookflow.sessions"), originalSessions)
            XCTAssertEqual(fixture.defaults.data(forKey: PanelLayoutStore.storageKey), originalLayout)
            XCTAssertEqual(pending.visibleTasks.count, populated ? 1 : 0)
            heights.append(host.bounds.height)
            measurements.append(measured.height)
            if taskModule == nil && phase < 2 {
                try writeEvidence(host, record: record,
                    name: "inbox-\(populated ? "content" : "empty")-\(enabled ? "on" : "off")")
            }
        }
        if taskModule == nil {
            XCTAssertGreaterThan(measurements[0] - measurements[1], 16, "关闭后内容高度应实际减少")
            XCTAssertGreaterThan(heights[0] - heights[1], 16, "关闭后面板应实际收拢")
        } else {
            XCTAssertEqual(heights[0], heights[1], accuracy: 0.5, "组件内已有入口时不应增加或移除兜底空间")
        }
        XCTAssertEqual(heights[2], heights[0], accuracy: 0.5, "重新开启应恢复原高度")
        XCTAssertEqual(measurements[2], measurements[0], accuracy: 0.5)
    }

    private func assertVisible(_ frame: CGRect, inside bounds: CGRect,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(frame.width, 0, file: file, line: line)
        XCTAssertGreaterThan(frame.height, 0, file: file, line: line)
        XCTAssertTrue(bounds.insetBy(dx: -0.75, dy: -0.75).contains(frame), "控件必须完整可见", file: file, line: line)
    }

    private func settle(_ host: NSView) {
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.025))
        }
    }

    private func writeEvidence(_ host: NSView, record: InboxShortcutPreviewRecord, name: String) throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/inbox-shortcut-20261027/ui", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1_000)
        try png.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
        let frames = record.frames.mapValues { ["x": $0.minX, "y": $0.minY, "width": $0.width, "height": $0.height] }
        let metrics: [String: Any] = ["fixtureOnly": true, "windowVisible": false, "scenario": name,
            "panelHeight": host.bounds.height, "measuredHeight": try XCTUnwrap(record.measurement).height, "frames": frames]
        try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent(name + ".json"), options: .atomic)
    }
}

@Observable @MainActor
private final class InboxShortcutPreviewModel {
    let width: CGFloat = 640
    var height: CGFloat = 1600
}

@MainActor
private final class InboxShortcutPreviewRecord {
    var frames: [String: CGRect] = [:]
    var measurement: ExpandedPanelMeasurement?
}

@MainActor
private struct InboxShortcutPreviewSurface: View {
    let fixture: WorkflowPreviewFixture
    let store: PanelLayoutStore
    let pending: PendingTaskCoordinator
    let resources: FocusResourceCoordinator
    let model: InboxShortcutPreviewModel
    let record: InboxShortcutPreviewRecord

    var body: some View {
        ExpandedPanelView(selectedWidget: .constant(nil), calendarRecenterTrigger: .constant(0),
            enabledWidgets: [.notes], panelWidth: model.width, mediaManager: fixture.media,
            calendarManager: fixture.calendar, notesManager: fixture.notes, trayManager: fixture.tray,
            focusSessionManager: fixture.focus, showHistory: true, historyDisplayLimit: 5,
            onCreateLinkedNote: { false }, onLinkTrayFiles: {}, onEndSession: {},
            onOpenNote: { _ in false }, onOpenFile: { _ in false }, onStartFocus: { _ in },
            onInteractionChanged: { _ in }, onLinksPresentationChanged: { _ in },
            onSettings: { XCTFail("回归不能打开设置") }, onClose: { XCTFail("回归不能关闭面板") },
            onMeasurement: { record.measurement = $0 }, layoutStore: store,
            focusResources: resources, pendingTasks: pending)
            .frame(width: model.width, height: model.height, alignment: .top)
            .background(IslandStyle.surface(for: .dark))
            .environment(\.colorScheme, .dark)
            .environment(\.reportsExpandedPanelDebugGeometry, true)
            .defaultAppStorage(fixture.defaults)
            .onPreferenceChange(ExpandedPanelDebugGeometryKey.self) { record.frames = $0 }
    }
}
