import AppKit
import EventKit
import Observation
import SwiftUI
import XCTest
@testable import XNook

/// 复用临时业务夹具和面板原生几何探针；不展示窗口，不连接个人数据。
@MainActor
final class PanelLayoutTemplatesPreviewTests: XCTestCase {
    func testRealTemplatesWithContentAndEmptyStateFitWithoutOverlappingNotchControls() throws {
        #if !DEBUG
        throw XCTSkip("真实面板几何探针需要 Debug 构建")
        #endif
        guard ProcessInfo.processInfo.environment["XNOOK_RENDER_UI"] == "1" else {
            throw XCTSkip("使用 XNOOK_RENDER_UI=1 渲染隔离的真实模板面板")
        }
        _ = NSApplication.shared
        for populated in [true, false] {
            let fixture = try WorkflowPreviewFixture(historyCount: populated ? 4 : 0,
                trayFileCount: populated ? 6 : 0, mediaHasContent: populated,
                calendarEventTitles: populated ? nil : [], calendarDayOffset: 0)
            defer { fixture.cleanUp() }
            if populated {
                _ = try XCTUnwrap(fixture.focus.start(title: "完成布局方案验收 · 核对组件与资料"))
                XCTAssertTrue(fixture.focus.linkNote(id: fixture.sampleNotes[0].id, title: fixture.sampleNotes[0].title))
                XCTAssertTrue(fixture.focus.linkFile(id: UUID(), name: "布局验收说明.pdf", icon: "doc.richtext"))
            } else {
                try Data("[]".utf8).write(to: fixture.directory.appendingPathComponent("notes.json"))
                fixture.notes.loadNotes()
                XCTAssertTrue(fixture.notes.notes.isEmpty)
            }
            fixture.defaults.set(IslandBackgroundStyle.solid.rawValue, forKey: "islandBackgroundStyle")
            fixture.defaults.set(true, forKey: "panelAutoSize")
            fixture.defaults.set(PanelHeightMode.automatic.rawValue, forKey: "panelHeightMode")
            let store = PanelLayoutStore(defaults: fixture.defaults)
            for template in PanelLayoutTemplate.allCases {
                try store.save(template.configuration)
                let primaryWidgetCount = template.configuration.visibleItems.compactMap {
                    NotchContentView.WidgetType(rawValue: $0.id.rawValue)
                }.count
                let count = ExpandedPanelLayout.overviewWidgetCount(
                    primaryWidgetCount: primaryWidgetCount, configuration: template.configuration)
                let width = ExpandedPanelLayout.width(preferred: 800, available: 1600,
                    automaticallyFit: true, widgetCount: count, selectedWidget: nil)
                try render(template: template, width: width, populated: populated, fixture: fixture, store: store)
            }
        }
    }

    private func render(template: PanelLayoutTemplate, width: CGFloat, populated: Bool,
                        fixture: WorkflowPreviewFixture, store: PanelLayoutStore) throws {
        let model = TemplatePreviewModel(width: width)
        let record = TemplatePreviewRecord()
        let pending = PendingTaskCoordinator(pending: PendingTaskManager(
            storageURL: fixture.directory.appendingPathComponent("pending.json")), focus: fixture.focus)
        let resources = FocusResourceCoordinator(manager: fixture.focus, notes: fixture.notes, tray: fixture.tray)
        let originalLayout = fixture.defaults.data(forKey: PanelLayoutStore.storageKey)
        let originalTasks = fixture.defaults.data(forKey: "nookflow.sessions")
        let originalNotes = fixture.notes.notes
        let originalFiles = fixture.tray.files.map(\.id)
        let host = NSHostingView(rootView: TemplatePreviewSurface(fixture: fixture, store: store,
            pending: pending, resources: resources, model: model, record: record))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: model.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        settle(host)
        if populated {
            let eventStore = EKEventStore()
            fixture.calendar.upcomingEvents = (0..<6).map { index in
                let event = EKEvent(eventStore: eventStore)
                event.title = "方案评审 \(index + 1) · 组件与交互验收"
                event.startDate = Date().addingTimeInterval(TimeInterval(index * 1800 + 60))
                event.endDate = event.startDate.addingTimeInterval(1200)
                return event
            }
            settle(host)
        }
        let measured = try XCTUnwrap(record.measurement)
        XCTAssertEqual(measured.layoutSignature,
                       PanelGridGeometry.measurementSignature(for: template.configuration, fitsContent: true))
        model.height = ExpandedPanelLayout.height(measuredContentHeight: measured.height, maximumHeight: 1600)
        window.setContentSize(NSSize(width: width, height: model.height))
        settle(host)
        XCTAssertEqual(record.measurement?.height ?? 0, measured.height, accuracy: 0.5)
        XCTAssertEqual(host.bounds.width, width, accuracy: 0.5)
        XCTAssertEqual(host.bounds.height, model.height, accuracy: 0.5)
        XCTAssertFalse(window.isVisible)
        try assertGeometry(record, configuration: template.configuration, model: model)
        if template == .focus {
            let task = try XCTUnwrap(record.frames["panelModule-currentTask"])
            let notes = try XCTUnwrap(record.frames["panelModule-notes"])
            XCTAssertEqual(task.minY, notes.minY, accuracy: 0.5, "自动宽度下专注布局的任务与笔记应保持同排")
            XCTAssertGreaterThanOrEqual(notes.minX, task.maxX + 7.5)
        }
        let visibleFrames = try template.configuration.visibleItems.map {
            try XCTUnwrap(record.frames["panelModule-\($0.id.rawValue)"])
        }
        let actualGridHeight = try XCTUnwrap(visibleFrames.map(\.maxY).max())
            - XCTUnwrap(visibleFrames.map(\.minY).min())
        let fixedGridHeight = PanelGridGeometry.height(for: template.configuration, width: width - 16)
        // 保留真实顶栏、外边距和待办入口的高度，仅替换网格部分得到固定行模型基线。
        let fixedPanelHeight = measured.height - actualGridHeight + fixedGridHeight
        if !populated {
            XCTAssertLessThan(actualGridHeight, fixedGridHeight, "空态组件应随内容收拢")
            XCTAssertLessThanOrEqual(model.height, fixedPanelHeight - 16,
                                    "空态面板应比固定行模型至少减少 16pt，并保留完整控件")
        }
        XCTAssertEqual(store.configuration, template.configuration)
        XCTAssertEqual(fixture.defaults.data(forKey: PanelLayoutStore.storageKey), originalLayout)
        XCTAssertEqual(fixture.defaults.data(forKey: "nookflow.sessions"), originalTasks)
        XCTAssertEqual(fixture.notes.notes.map(\.id), originalNotes.map(\.id))
        XCTAssertEqual(fixture.notes.notes.map(\.content), originalNotes.map(\.content))
        XCTAssertEqual(fixture.tray.files.map(\.id), originalFiles)

        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/layout-profiles-20261026/ui", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "template-\(template.rawValue)-\(Int(width))-dark-\(populated ? "content" : "empty")"
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1_000)
        try png.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
        let geometry = record.frames.mapValues {
            ["x": $0.minX, "y": $0.minY, "width": $0.width, "height": $0.height]
        }
        let metrics: [String: Any] = ["template": template.rawValue, "fixtureOnly": true,
            "windowVisible": window.isVisible, "populated": populated, "panelWidth": width,
            "panelHeight": model.height, "layoutSignature": template.configuration.signature,
            "measurementSignature": measured.layoutSignature, "contentFitEnabled": true,
            "actualGridHeight": actualGridHeight, "fixedGridHeight": fixedGridHeight,
            "fixedModelPanelHeight": fixedPanelHeight, "heightReduction": fixedPanelHeight - model.height,
            "deadZoneWidth": model.deadZone.width, "deadZoneHeight": model.deadZone.height,
            "frames": geometry]
        try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent(name + ".json"), options: .atomic)
    }

    private func assertGeometry(_ record: TemplatePreviewRecord, configuration: PanelLayoutConfiguration,
                                model: TemplatePreviewModel) throws {
        let bounds = CGRect(x: 0, y: 0, width: model.width, height: model.height)
        let body = try XCTUnwrap(record.frames["expandedPanelBody"])
        let modules = try configuration.visibleItems.map { item in
            (item.id, try XCTUnwrap(record.frames["panelModule-\(item.id.rawValue)"]))
        }
        for (index, entry) in modules.enumerated() {
            let (id, frame) = entry
            assertContained(frame, in: body, name: id.rawValue)
            XCTAssertGreaterThan(frame.width, 0)
            XCTAssertGreaterThan(frame.height, 0)
            for other in modules.dropFirst(index + 1) {
                XCTAssertFalse(frame.insetBy(dx: 0.5, dy: 0.5).intersects(other.1),
                               "模板组件不能重叠：\(id) / \(other.0)")
            }
            for (name, child) in record.frames where owner(of: name) == id {
                assertContained(child, in: frame, name: name)
            }
        }
        let header = try XCTUnwrap(record.frames["expandedPanelHeader"])
        assertContained(header, in: bounds, name: "header")
        assertContained(body, in: bounds, name: "body")
        let deadZone = CGRect(x: (model.width - model.deadZone.width) / 2, y: 0,
                              width: model.deadZone.width, height: model.deadZone.height)
        for key in ["expandedPanelSettings", "expandedPanelClose", "panelLayoutBegin"] {
            let control = try XCTUnwrap(record.frames[key], key)
            assertContained(control, in: header, name: key)
            XCTAssertGreaterThan(control.width, 0)
            XCTAssertGreaterThan(control.height, 0)
            XCTAssertFalse(control.intersects(deadZone), "顶部按钮不能侵入物理刘海：\(key)")
        }
    }

    private func owner(of name: String) -> PanelModuleID? {
        if name.hasPrefix("gridWidgetMedia") || name.hasPrefix("mediaWidget") { return .media }
        if name.hasPrefix("gridWidgetCalendar") || name.hasPrefix("expandedPanelCalendar") { return .calendar }
        if name.hasPrefix("gridWidgetNotes") || name.hasPrefix("expandedPanelNotes") { return .notes }
        if name.hasPrefix("expandedPanelTray") { return .tray }
        // 两个任务卡共用收件箱探针；模板后挂载最近任务，PreferenceKey 合并后保留该卡的按钮。
        if name.hasPrefix("expandedPanelHistoryRow-") || name == "focusSessionRecentTasks"
            || name == "focusSessionViewAllTasks" || name == "focusSessionInbox" { return .recentTasks }
        if name.hasPrefix("focusSession") { return .currentTask }
        return nil
    }

    private func assertContained(_ frame: CGRect, in parent: CGRect, name: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(frame.minX, parent.minX - 0.75, name + " left", file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minY, parent.minY - 0.75, name + " top", file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxX, parent.maxX + 0.75, name + " right", file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxY, parent.maxY + 0.75, name + " bottom", file: file, line: line)
    }

    private func settle(_ host: NSView) {
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.025))
        }
    }
}

@Observable @MainActor
private final class TemplatePreviewModel {
    let width: CGFloat
    var height: CGFloat = 1600
    let deadZone = NotchDeadZone(width: 200, height: 32)
    init(width: CGFloat) { self.width = width }
}

@MainActor
private final class TemplatePreviewRecord {
    var frames: [String: CGRect] = [:]
    var measurement: ExpandedPanelMeasurement?
}

@MainActor
private struct TemplatePreviewSurface: View {
    let fixture: WorkflowPreviewFixture
    let store: PanelLayoutStore
    let pending: PendingTaskCoordinator
    let resources: FocusResourceCoordinator
    let model: TemplatePreviewModel
    let record: TemplatePreviewRecord

    var body: some View {
        ExpandedPanelView(selectedWidget: .constant(nil), calendarRecenterTrigger: .constant(0),
            enabledWidgets: store.configuration.visibleItems.compactMap {
                NotchContentView.WidgetType(rawValue: $0.id.rawValue)
            }, panelWidth: model.width, mediaManager: fixture.media, calendarManager: fixture.calendar,
            notesManager: fixture.notes, trayManager: fixture.tray, focusSessionManager: fixture.focus,
            showHistory: true, historyDisplayLimit: 5, onCreateLinkedNote: { false }, onLinkTrayFiles: {},
            onEndSession: {}, onOpenNote: { _ in false }, onOpenFile: { _ in false }, onStartFocus: { _ in },
            onInteractionChanged: { _ in }, onLinksPresentationChanged: { _ in },
            onSettings: { XCTFail("预览不能打开设置") }, onClose: { XCTFail("预览不能关闭面板") },
            onMeasurement: { record.measurement = $0 }, deadZone: model.deadZone,
            layoutStore: store, focusResources: resources, pendingTasks: pending)
            .frame(width: model.width, height: model.height, alignment: .top)
            .background(IslandStyle.surface(for: .dark))
            .environment(\.colorScheme, .dark)
            .environment(\.reportsExpandedPanelDebugGeometry, true)
            .defaultAppStorage(fixture.defaults)
            .onPreferenceChange(ExpandedPanelDebugGeometryKey.self) { record.frames = $0 }
    }
}
