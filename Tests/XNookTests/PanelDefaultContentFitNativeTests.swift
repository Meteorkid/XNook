import AppKit
import EventKit
import Observation
import SwiftUI
import XCTest
@testable import XNook

/// 全部窗口保持不可见；仅验证真实 SwiftUI 布局，不启动应用或写入个人偏好。
@MainActor
final class PanelDefaultContentFitNativeTests: XCTestCase {
    func testEmptyZeroThroughFourPrimaryModulesShrinkWithInboxAndRetainAllData() throws {
        try requireRendering()
        let fixture = try WorkflowPreviewFixture(historyCount: 0, trayFileCount: 0,
            mediaHasContent: false, calendarEventTitles: [])
        defer { fixture.cleanUp() }
        try Data("[]".utf8).write(to: fixture.directory.appendingPathComponent("notes.json"))
        fixture.notes.loadNotes()
        fixture.defaults.set(true, forKey: "panelAutoSize")
        let store = PanelLayoutStore(defaults: fixture.defaults)
        let primary = ["media", "calendar", "tray", "notes"]
        for scheme in [ColorScheme.dark, .light] {
            try withHost(fixture: fixture, store: store, scheme: scheme) { host, window, model, record in
                for count in 0...4 {
                    fixture.defaults.set(try JSONEncoder().encode(Set(primary.prefix(count))), forKey: "enabledWidgets")
                    store.reload()
                    let configuration = store.configuration
                    let data = fixture.defaults.data(forKey: "nookflow.sessions")
                    model.width = ExpandedPanelLayout.width(preferred: 800, available: 1600,
                        automaticallyFit: true, widgetCount: count, selectedWidget: nil)
                    window.setContentSize(CGSize(width: model.width, height: 1600))
                    settle(host)
                    try assertContainedModules(record, configuration: configuration)
                    let current = try XCTUnwrap(record.frames["panelModule-currentTask"])
                    let recent = try XCTUnwrap(record.frames["panelModule-recentTasks"])
                    XCTAssertLessThan(current.height, 136)
                    XCTAssertLessThan(recent.height, 136)
                    XCTAssertGreaterThanOrEqual(recent.minY, current.maxY + 7.5)
                    XCTAssertNotNil(record.frames["focusSessionInbox"])
                    let measurement = try XCTUnwrap(record.measurement)
                    let fixedHeight = PanelGridGeometry.height(for: configuration, width: model.width - 16)
                        + ExpandedPanelLayout.headerHeight + 16
                    XCTAssertLessThan(measurement.height, fixedHeight)
                    XCTAssertTrue(measurement.layoutSignature.hasSuffix("|contentFit=1"))
                    XCTAssertEqual(store.configuration, configuration)
                    XCTAssertNil(fixture.defaults.object(forKey: PanelLayoutStore.storageKey))
                    XCTAssertEqual(fixture.defaults.data(forKey: "nookflow.sessions"), data)
                    XCTAssertTrue(fixture.notes.notes.isEmpty)
                    try writeEvidence(host, window: window, model: model, record: record,
                        configuration: configuration, name: "empty-\(count)-\(scheme)")
                }
            }
        }
    }

    func testThreeWidgetCurrentOnlyPreferencePreviewUsesIsolatedUnsavedFixture() throws {
        try requireRendering()
        let fixture = try WorkflowPreviewFixture(historyCount: 0, trayFileCount: 0,
            mediaHasContent: false, calendarEventTitles: [])
        defer { fixture.cleanUp() }
        try Data("[]".utf8).write(to: fixture.directory.appendingPathComponent("notes.json"))
        fixture.notes.loadNotes()
        fixture.defaults.set(true, forKey: "panelAutoSize")
        fixture.defaults.set(false, forKey: "showNookFlowHistory")
        fixture.defaults.set(try JSONEncoder().encode(Set(["media", "calendar", "tray"])), forKey: "enabledWidgets")
        let store = PanelLayoutStore(defaults: fixture.defaults)
        XCTAssertEqual(store.configuration.visibleItems.map(\.id), [.media, .calendar, .tray, .currentTask])
        XCTAssertNil(fixture.defaults.object(forKey: PanelLayoutStore.storageKey))
        try withHost(fixture: fixture, store: store, scheme: .dark) { host, window, model, record in
            XCTAssertEqual(model.width, 800)
            try assertContainedModules(record, configuration: store.configuration)
            try writeEvidence(host, window: window, model: model, record: record,
                configuration: store.configuration, name: "preferred-three-widgets-current-only-empty-fixture")
            XCTAssertNil(fixture.defaults.object(forKey: PanelLayoutStore.storageKey))
        }
    }

    func testContentTransitionsAndAutomaticTogglePreserveTaskResourcesAndStableRowCounts() throws {
        try requireRendering()
        let fixture = try WorkflowPreviewFixture(historyCount: 5, trayFileCount: 6)
        defer { fixture.cleanUp() }
        fixture.defaults.set(true, forKey: "panelAutoSize")
        fixture.defaults.set(try JSONEncoder().encode(Set(["media", "calendar", "tray"])), forKey: "enabledWidgets")
        let task = try XCTUnwrap(fixture.focus.start(title: String(repeating: "需要完整操作的任务 Long task ", count: 8)))
        XCTAssertTrue(fixture.focus.linkNote(id: fixture.sampleNotes[0].id, title: fixture.sampleNotes[0].title))
        XCTAssertTrue(fixture.focus.linkFile(id: UUID(), name: "任务资料.pdf", icon: "doc", bookmarkData: Data([1, 2])))
        let original = fixture.focus.activeSession
        let data = fixture.defaults.data(forKey: "nookflow.sessions")
        let store = PanelLayoutStore(defaults: fixture.defaults)
        try withHost(fixture: fixture, store: store, scheme: .dark) { host, window, model, record in
            for width: CGFloat in [320, 600, 800, 320] {
                model.width = width
                window.setContentSize(CGSize(width: width, height: 1600))
                settle(host)
                try assertContainedModules(record, configuration: store.configuration)
                let fitted = try XCTUnwrap(record.measurement)
                let rowCount = record.frames.keys.filter { $0.hasPrefix("expandedPanelHistoryRow-") }.count
                XCTAssertGreaterThan(rowCount, 0)
                for _ in 0..<3 { settle(host) }
                XCTAssertEqual(record.measurement?.height ?? 0, fitted.height, accuracy: 0.5)
                XCTAssertEqual(record.frames.keys.filter { $0.hasPrefix("expandedPanelHistoryRow-") }.count, rowCount)
                let artwork = try XCTUnwrap(record.frames["gridWidgetMediaArtwork"])
                XCTAssertEqual(artwork.width, 100, accuracy: 0.5)
                XCTAssertEqual(artwork.height, 100, accuracy: 0.5)
                XCTAssertNotNil(record.frames["focusSessionTaskDetails"])
                XCTAssertNotNil(record.frames["focusSessionEndTask"])
                fixture.defaults.set(false, forKey: "panelAutoSize")
                settle(host)
                XCTAssertEqual(record.measurement?.layoutSignature, store.configuration.signature)
                fixture.defaults.set(true, forKey: "panelAutoSize")
                settle(host)
                XCTAssertEqual(record.measurement?.height ?? 0, fitted.height, accuracy: 0.5)
                XCTAssertEqual(fixture.focus.activeSession, original)
                XCTAssertEqual(fixture.defaults.data(forKey: "nookflow.sessions"), data)
            }
            fixture.media.currentTitle = ""
            fixture.media.currentArtist = ""
            fixture.media.currentAlbum = ""
            settle(host)
            try assertContainedModules(record, configuration: store.configuration)
            XCTAssertNotNil(record.frames["mediaWidgetOpenPlayer"])
            XCTAssertEqual(fixture.focus.activeSession?.id, task.id)
            let configuration = store.configuration
            try store.save(configuration)
            let saved = fixture.defaults.data(forKey: PanelLayoutStore.storageKey)
            settle(host)
            XCTAssertFalse(store.shouldFitDefaultContent(automaticallyFit: true))
            XCTAssertEqual(record.measurement?.layoutSignature, configuration.signature)
            for automatic in [false, true] {
                fixture.defaults.set(automatic, forKey: "panelAutoSize")
                settle(host)
                XCTAssertEqual(record.frames["panelModule-currentTask"]?.height, 136)
                XCTAssertEqual(fixture.defaults.data(forKey: PanelLayoutStore.storageKey), saved)
            }
            try writeEvidence(host, window: window, model: model, record: record,
                configuration: configuration, name: "saved-layout-keeps-grid")
        }
    }

    func testPermissionAndStorageErrorsKeepTheirControlsWithinFittedCards() async throws {
        try requireRendering()
        let fixture = try WorkflowPreviewFixture(historyCount: 0, trayFileCount: 0, mediaHasContent: false)
        defer { fixture.cleanUp() }
        fixture.defaults.set(true, forKey: "panelAutoSize")
        try Data("unreadable notes".utf8).write(to: fixture.directory.appendingPathComponent("notes.json"))
        fixture.notes.loadNotes()
        try Data("unreadable tray".utf8).write(to: fixture.directory.appendingPathComponent("tray.json"))
        fixture.tray.loadFiles()
        fixture.defaults.set(Data("unreadable tasks".utf8), forKey: "nookflow.sessions")
        XCTAssertFalse(fixture.focus.retryLoadingStorage())
        let permissions = CalendarManager(defaults: fixture.defaults, notificationCenter: NotificationCenter(),
            observeChanges: false, readAuthorization: { .writeOnly }, fetchCalendars: { [] }, fetchEvents: { _, _ in [] },
            requestFullAccess: { throw CocoaError(.fileReadNoPermission) }, didRefreshAuthorization: {})
        await permissions.requestAccess()
        XCTAssertNotNil(permissions.accessError)
        let store = PanelLayoutStore(defaults: fixture.defaults)
        try withHost(fixture: fixture, store: store, scheme: .light) { host, window, model, record in
            model.calendarOverride = permissions
            for width: CGFloat in [320, 600, 800] {
                model.width = width
                window.setContentSize(CGSize(width: width, height: 1600))
                settle(host)
                try assertContainedModules(record, configuration: store.configuration)
                XCTAssertNotNil(record.frames["focusSessionInbox"])
                XCTAssertNotNil(fixture.notes.storageErrorMessage)
                XCTAssertNotNil(fixture.tray.issue)
                XCTAssertNil(fixture.defaults.object(forKey: PanelLayoutStore.storageKey))
                try writeEvidence(host, window: window, model: model, record: record,
                    configuration: store.configuration, name: "errors-\(Int(width))")
            }
        }
    }

    func testSameGridNodesKeepStateAndContentBudgetAcrossFitResizeEditingAndCancel() throws {
        try requireRendering()
        let model = ContentFitProbeModel()
        let record = ContentFitProbeRecord()
        let host = NSHostingView(rootView: ContentFitProbeSurface(model: model, record: record))
        let window = makeWindow(content: host, width: model.width)
        defer { window.contentView = nil; window.close() }
        settle(host)
        let identities = record.identities
        XCTAssertEqual(identities.count, 6)
        let draft = try XCTUnwrap(record.drafts[.notes])
        draft.wrappedValue = "不能因自然高度变化丢失的输入"
        settle(host)
        let originalBudget = record.budgets
        for width: CGFloat in [600, 800, 320, 800] {
            model.width = width
            window.setContentSize(CGSize(width: width, height: 1600))
            for fitting in [false, true] {
                model.fitsContent = fitting
                settle(host)
                XCTAssertEqual(record.identities, identities)
                XCTAssertEqual(record.drafts[.notes]?.wrappedValue, "不能因自然高度变化丢失的输入")
                XCTAssertTrue(record.appearances.values.allSatisfy { $0 == 1 })
            }
        }
        model.isEditing = true
        settle(host)
        model.isEditing = false
        settle(host)
        XCTAssertEqual(record.identities, identities)
        XCTAssertEqual(record.drafts[.notes]?.wrappedValue, "不能因自然高度变化丢失的输入")
        XCTAssertEqual(record.budgets, originalBudget, "测后的外框高度不能反馈给正文预算")
        XCTAssertTrue(record.appearances.values.allSatisfy { $0 == 1 })
        XCTAssertFalse(window.isVisible)
    }

    private func requireRendering() throws {
        guard ProcessInfo.processInfo.environment["XNOOK_RENDER_UI"] == "1" else {
            throw XCTSkip("Set XNOOK_RENDER_UI=1 for invisible content-fit rendering.")
        }
        _ = NSApplication.shared
    }

    private func makeWindow(content: NSView, width: CGFloat) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: width, height: 1600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        XCTAssertFalse(window.isVisible)
        return window
    }

    private func withHost(fixture: WorkflowPreviewFixture, store: PanelLayoutStore, scheme: ColorScheme,
        verify: (NSHostingView<DefaultContentFitSurface>, NSWindow, DefaultContentFitModel, DefaultContentFitRecord) throws -> Void
    ) throws {
        let model = DefaultContentFitModel()
        let record = DefaultContentFitRecord()
        let pending = PendingTaskCoordinator(pending: PendingTaskManager(
            storageURL: fixture.directory.appendingPathComponent("pending.json")), focus: fixture.focus)
        let resources = FocusResourceCoordinator(manager: fixture.focus, notes: fixture.notes, tray: fixture.tray)
        let host = NSHostingView(rootView: DefaultContentFitSurface(fixture: fixture, store: store,
            resources: resources, pending: pending, model: model, record: record, scheme: scheme))
        let window = makeWindow(content: host, width: model.width)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        defer { XCTAssertFalse(window.isVisible); window.contentView = nil; window.close() }
        settle(host)
        try verify(host, window, model, record)
    }

    private func settle(_ host: NSView) {
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.025))
        }
    }

    private func assertContainedModules(_ record: DefaultContentFitRecord, configuration: PanelLayoutConfiguration) throws {
        let modules = try configuration.visibleItems.map { item in
            (item.id, try XCTUnwrap(record.frames["panelModule-\(item.id.rawValue)"]))
        }
        for (index, entry) in modules.enumerated() {
            let (id, parent) = entry
            XCTAssertGreaterThan(parent.height, 0)
            for other in modules.dropFirst(index + 1) {
                XCTAssertFalse(parent.insetBy(dx: 0.5, dy: 0.5).intersects(other.1))
            }
            for (name, frame) in record.frames where owner(of: name) == id {
                XCTAssertGreaterThanOrEqual(frame.minX, parent.minX - 0.5, name)
                XCTAssertGreaterThanOrEqual(frame.minY, parent.minY - 0.5, name)
                XCTAssertLessThanOrEqual(frame.maxX, parent.maxX + 0.5, name)
                XCTAssertLessThanOrEqual(frame.maxY, parent.maxY + 0.5, name)
            }
        }
    }

    private func owner(of name: String) -> PanelModuleID? {
        if name.hasPrefix("mediaWidget") || name.hasPrefix("gridWidgetMedia") { return .media }
        if name.hasPrefix("gridWidgetCalendar") || name.hasPrefix("expandedPanelCalendar") { return .calendar }
        if name.hasPrefix("gridWidgetNotes") || name.hasPrefix("expandedPanelNotes") { return .notes }
        if name.hasPrefix("expandedPanelTray") { return .tray }
        if ["focusSessionStartTask", "focusSessionTaskInput", "focusSessionTaskDetails", "focusSessionTaskActions", "focusSessionEndTask"].contains(name) { return .currentTask }
        if name.hasPrefix("expandedPanelHistoryRow-") || name == "focusSessionViewAllTasks" { return .recentTasks }
        return nil
    }

    private func writeEvidence(
        _ host: NSView, window: NSWindow, model: DefaultContentFitModel, record: DefaultContentFitRecord,
        configuration: PanelLayoutConfiguration, name: String
    ) throws {
        let originalHeight = model.height
        let originalMeasurement = try XCTUnwrap(record.measurement)
        let originalFrames = record.frames
        let fixedGridHeight = PanelGridGeometry.height(for: configuration, width: model.width - 16)
            + ExpandedPanelLayout.headerHeight + 16
        let fitsContent = originalMeasurement.layoutSignature.hasSuffix("|contentFit=1")
        // 先完成大画布几何验收，再按生产测量调整同一个宿主；不裁剪既有位图。
        let panelHeight = ExpandedPanelLayout.height(measuredContentHeight: originalMeasurement.height,
            maximumHeight: originalHeight)
        model.height = panelHeight
        window.setContentSize(CGSize(width: model.width, height: panelHeight))
        defer {
            model.height = originalHeight
            window.setContentSize(CGSize(width: model.width, height: originalHeight))
            settle(host)
        }
        settle(host)
        let resizedMeasurement = try XCTUnwrap(record.measurement)
        XCTAssertEqual(resizedMeasurement.height, originalMeasurement.height, accuracy: 0.5)
        XCTAssertEqual(resizedMeasurement.layoutSignature, originalMeasurement.layoutSignature)
        XCTAssertEqual(host.bounds.height, panelHeight, accuracy: 0.5)
        XCTAssertFalse(window.isVisible)
        try assertContainedModules(record, configuration: configuration)
        for item in configuration.visibleItems {
            let key = "panelModule-\(item.id.rawValue)"
            let before = try XCTUnwrap(originalFrames[key])
            let after = try XCTUnwrap(record.frames[key])
            XCTAssertEqual(after.height, before.height, accuracy: 0.5, key)
            XCTAssertLessThanOrEqual(after.maxY, panelHeight + 0.5, key)
        }
        settle(host)
        XCTAssertEqual(record.measurement?.height ?? 0, originalMeasurement.height, accuracy: 0.5,
            "缩紧宿主后测量高度必须稳定，不能触发新一轮内容压缩")
        if !fitsContent {
            XCTAssertEqual(originalMeasurement.height, fixedGridHeight, accuracy: 0.5,
                "已保存布局继续使用原固定网格高度")
        }
        let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        let data = try XCTUnwrap(image.representation(using: .png, properties: [:]))
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/feature-reintegration-20261024/ui/default-content-fit")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
        let moduleFrames = Dictionary(uniqueKeysWithValues: configuration.visibleItems.map { item in
            let frame = record.frames["panelModule-\(item.id.rawValue)"] ?? .zero
            return (item.id.rawValue, ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height])
        })
        let metrics: [String: Any] = [
            "scenario": name,
            "fixtureOnly": true,
            "dataSource": "isolated temporary data; no personal user library",
            "windowVisible": window.isVisible,
            "contentFitEnabled": fitsContent,
            "layoutSignature": originalMeasurement.layoutSignature,
            "panelWidth": model.width,
            "geometryHostHeight": originalHeight,
            "fixedGridPanelHeight": fixedGridHeight,
            "contentFitMeasurementHeight": originalMeasurement.height,
            "renderedPanelHeight": panelHeight,
            "heightReduction": fixedGridHeight - originalMeasurement.height,
            "heightReductionPercent": (fixedGridHeight - originalMeasurement.height) / fixedGridHeight * 100,
            "measurementAfterResize": resizedMeasurement.height,
            "moduleFrames": moduleFrames,
        ]
        try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent(name + ".json"), options: .atomic)
    }
}

@MainActor @Observable
private final class DefaultContentFitModel {
    var width: CGFloat = 800
    var height: CGFloat = 1600
    var selected: NotchContentView.WidgetType?
    var recenter = 0
    var calendarOverride: CalendarManager?
}

@MainActor
private final class DefaultContentFitRecord {
    var frames: [String: CGRect] = [:]
    var measurement: ExpandedPanelMeasurement?
}

@MainActor
private struct DefaultContentFitSurface: View {
    let fixture: WorkflowPreviewFixture
    let store: PanelLayoutStore
    let resources: FocusResourceCoordinator
    let pending: PendingTaskCoordinator
    @Bindable var model: DefaultContentFitModel
    let record: DefaultContentFitRecord
    let scheme: ColorScheme

    var body: some View {
        ExpandedPanelView(selectedWidget: $model.selected, calendarRecenterTrigger: $model.recenter,
            enabledWidgets: store.configuration.visibleItems.compactMap { NotchContentView.WidgetType(rawValue: $0.id.rawValue) },
            panelWidth: model.width, mediaManager: fixture.media, calendarManager: model.calendarOverride ?? fixture.calendar,
            notesManager: fixture.notes, trayManager: fixture.tray, focusSessionManager: fixture.focus,
            showHistory: true, historyDisplayLimit: 5, onCreateLinkedNote: { false }, onLinkTrayFiles: {},
            onEndSession: {}, onOpenNote: { _ in false }, onOpenFile: { _ in false }, onStartFocus: { _ in },
            onInteractionChanged: { _ in }, onLinksPresentationChanged: { _ in }, onSettings: {}, onClose: {},
            onMeasurement: { record.measurement = $0 }, layoutStore: store, focusResources: resources, pendingTasks: pending)
            .frame(width: model.width, height: model.height, alignment: .top)
            .background(IslandStyle.surface(for: scheme))
            .environment(\.colorScheme, scheme)
            .environment(\.reportsExpandedPanelDebugGeometry, true)
            .defaultAppStorage(fixture.defaults)
            .onPreferenceChange(ExpandedPanelDebugGeometryKey.self) { record.frames = $0 }
    }
}

@MainActor @Observable
private final class ContentFitProbeModel {
    var configuration = PanelLayoutConfiguration.factoryDefault
    var selection = PanelModuleID.media
    var width: CGFloat = 800
    var fitsContent = true
    var isEditing = false
}

@MainActor
private final class ContentFitProbeRecord {
    var identities: [PanelModuleID: UUID] = [:]
    var appearances: [PanelModuleID: Int] = [:]
    var drafts: [PanelModuleID: Binding<String>] = [:]
    var budgets: [PanelModuleID: CGSize] = [:]
}

@MainActor
private struct ContentFitProbeSurface: View {
    @Bindable var model: ContentFitProbeModel
    let record: ContentFitProbeRecord
    var body: some View {
        PanelDashboardGrid(configuration: $model.configuration, selection: $model.selection, width: model.width,
            isEditing: model.isEditing, summary: { $0.rawValue }, fitsContent: model.fitsContent) { item, budget in
                ContentFitProbe(id: item.id, budget: budget, record: record)
            }
            .frame(width: model.width, height: 1600, alignment: .top)
    }
}

@MainActor
private struct ContentFitProbe: View {
    let id: PanelModuleID
    let budget: CGSize
    let record: ContentFitProbeRecord
    @State private var identity = UUID()
    @State private var draft = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(id.rawValue, text: $draft).frame(height: 28)
            Text(draft.isEmpty ? "空态 Empty" : draft).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            record.identities[id] = identity
            record.appearances[id, default: 0] += 1
            record.drafts[id] = $draft
            record.budgets[id] = budget
        }
        .onChange(of: budget) { _, value in record.budgets[id] = value }
    }
}
