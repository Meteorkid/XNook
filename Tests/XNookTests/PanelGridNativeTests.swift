import AppKit
import Observation
import SwiftUI
import XCTest
@testable import XNook

/// XNOOK_RENDER_UI=1 swift test --filter PanelGridNativeTests
/// XNOOK_GRID_LIVE=1 XNOOK_GRID_LIVE_SECONDS=600 swift test --filter PanelGridNativeTests/testRunIsolatedLiveGridEditor
@MainActor
final class PanelGridNativeTests: XCTestCase {
    func testDefaultDashboardModulesAndControlsFitAtSupportedWidths() throws {
        try requireRendering()
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let store = PanelLayoutStore(defaults: fixture.defaults)
        let originalTask = fixture.focus.activeSession
        let originalLayout = store.configuration
        for scheme in [ColorScheme.light, .dark] {
            try withHost(fixture: fixture, store: store, scheme: scheme) { host, window, model, record in
                for width: CGFloat in [320, 600, 800, 1000] {
                    resizeForEvidence(host, window: window, model: model, record: record, width: width)
                    XCTAssertFalse(record.isEditing)
                    try assertGeometry(record, configuration: store.configuration, size: model.size, editing: false)
                    try writeDashboardEvidence(host, record: record,
                        name: "default-\(Int(width))-\(scheme == .dark ? "dark" : "light")")
                }
            }
        }
        XCTAssertEqual(fixture.focus.activeSession, originalTask, "重排不得重启计时或替换任务")
        XCTAssertEqual(store.configuration, originalLayout)
        XCTAssertNil(fixture.defaults.data(forKey: PanelLayoutStore.storageKey), "只渲染不应写入布局")
    }

    func testEditingDashboardKeepsModulesAndEditorControlsInsideTheirBounds() throws {
        try requireRendering()
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let originalArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(originalArguments, forName: UserDefaults.argumentDomain) }
        let store = PanelLayoutStore(defaults: fixture.defaults)
        let originalLayout = store.configuration
        for language in ["zh", "en"] {
            var arguments = originalArguments
            arguments["appLanguage"] = language
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            for scheme in [ColorScheme.light, .dark] {
                try withHost(fixture: fixture, store: store, scheme: scheme) { host, window, model, record in
                    model.editRequest = 1
                    settle(host)
                    XCTAssertTrue(record.isEditing)
                    XCTAssertEqual(model.editRequest, 0, "编辑请求处理后应清零，避免重建时重复进入")
                    for width: CGFloat in [320, 600, 800, 1000] {
                        resizeForEvidence(host, window: window, model: model, record: record, width: width)
                        try assertGeometry(record, configuration: store.configuration, size: model.size, editing: true)
                        try writeDashboardEvidence(host, record: record,
                            name: "editing-\(language)-\(Int(width))-\(scheme == .dark ? "dark" : "light")")
                    }
                }
            }
        }
        XCTAssertEqual(store.configuration, originalLayout, "进入编辑与改变窗口宽度不应自动保存")
        XCTAssertNil(fixture.defaults.data(forKey: PanelLayoutStore.storageKey))
    }

    func testDashboardAdaptsZeroThroughFourWidgetsAndReportsEqualHeightReorder() throws {
        try requireRendering()
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let store = PanelLayoutStore(defaults: fixture.defaults)
        let task = fixture.focus.activeSession
        let primary: [PanelModuleID] = [.media, .calendar, .tray, .notes]
        try withHost(fixture: fixture, store: store, scheme: .dark) { host, window, model, record in
            for count in 0...4 {
                let configuration = PanelLayoutConfiguration.legacy(
                    enabledWidgetIDs: Set(primary.prefix(count).map(\.rawValue)), showHistory: true)
                try store.save(configuration)
                let saved = fixture.defaults.data(forKey: PanelLayoutStore.storageKey)
                let width = ExpandedPanelLayout.width(preferred: 800, available: 1600, automaticallyFit: true,
                    widgetCount: count, selectedWidget: nil)
                resizeForEvidence(host, window: window, model: model, record: record, width: width)
                try assertGeometry(record, configuration: configuration, size: model.size, editing: false)
                XCTAssertEqual(record.measurement?.layoutSignature, configuration.signature)
                XCTAssertEqual(fixture.defaults.data(forKey: PanelLayoutStore.storageKey), saved)
                try writeDashboardEvidence(host, record: record, name: "dynamic-primary-\(count)")
            }

            let previous = try XCTUnwrap(record.measurement)
            var reordered = store.configuration
            reordered.move(.media, column: 6, row: 0)
            try store.save(reordered)
            settle(host)
            let next = try XCTUnwrap(record.measurement)
            XCTAssertEqual(next.height, previous.height, accuracy: 0.5)
            XCTAssertNotEqual(next.layoutSignature, previous.layoutSignature)
            XCTAssertEqual(next.layoutSignature, reordered.signature)
            XCTAssertTrue(next.differs(from: previous))
            XCTAssertEqual(fixture.focus.activeSession, task)
        }
    }

    func testGridToolbarUsesActualButtonCountToAvoidNotch() throws {
        try requireRendering()
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let store = PanelLayoutStore(defaults: fixture.defaults)
        let originalLanguage = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(originalLanguage, forName: UserDefaults.argumentDomain) }
        for language in ["zh", "en"] {
            var arguments = originalLanguage
            arguments["appLanguage"] = language
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            try withHost(fixture: fixture, store: store, scheme: .dark) { host, window, model, record in
                model.deadZone = NotchDeadZone(width: 200, height: 32)
                for width: CGFloat in [320, 380, 400, 412, 460, 800] {
                    for selection: NotchContentView.WidgetType? in [nil, .media] {
                        model.selected = selection
                        resizeForEvidence(host, window: window, model: model, record: record, width: width)
                        let notch = CGRect(x: (width - 200) / 2, y: 0, width: 200, height: 32)
                        let actions = selection == nil
                            ? ["panelLayoutBegin", "expandedPanelSettings", "expandedPanelClose"]
                            : ["expandedPanelOverview", "panelLayoutBegin", "expandedPanelSettings", "expandedPanelClose"]
                        for id in actions {
                            let frame = try XCTUnwrap(record.frames[id], id)
                            XCTAssertFalse(frame.intersects(notch), "\(id) width=\(width) language=\(language)")
                            assertContained(frame, in: try XCTUnwrap(record.frames["expandedPanelHeader"]), name: id)
                            if width < (selection == nil ? 412 : 424) { XCTAssertGreaterThanOrEqual(frame.minY, 32) }
                            else { XCTAssertLessThan(frame.minY, 32) }
                        }
                        if selection != nil {
                            XCTAssertNotNil(record.frames["panelLayoutBegin"])
                            let overview = try XCTUnwrap(record.frames["expandedPanelOverview"])
                            let settings = try XCTUnwrap(record.frames["expandedPanelSettings"])
                            XCTAssertGreaterThan(overview.width, 40, "概览文字不能退化为单个图标")
                            XCTAssertGreaterThanOrEqual(overview.height, 28)
                            XCTAssertLessThanOrEqual(overview.maxX, settings.minX)
                            if width == 460 {
                                try writeDashboardEvidence(host, record: record, name: "media-overview-header-" + language)
                            }
                        }
                    }
                }
            }
        }
    }

    func testEditorToolbarStaysVisibleWhileItsCanvasScrolls() throws {
        try requireRendering()
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let store = PanelLayoutStore(defaults: fixture.defaults)
        let original = fixture.defaults.data(forKey: PanelLayoutStore.storageKey)
        try withHost(fixture: fixture, store: store, scheme: .dark) { host, window, model, record in
            model.editRequest = 1
            settle(host)
            model.deadZone = NotchDeadZone(width: 200, height: 32)
            for width: CGFloat in [160, 320, 800] {
                model.width = width
                model.height = 560
                window.setContentSize(model.size)
                settle(host)
                let toolbar = try XCTUnwrap(record.frames["panelLayoutEditor"])
                let body = try XCTUnwrap(record.frames["expandedPanelBody"])
                assertContained(toolbar, in: CGRect(origin: .zero, size: model.size), name: "pinned toolbar")
                XCTAssertLessThanOrEqual(toolbar.maxY, body.minY + 0.5)
                XCTAssertGreaterThan(body.height, 100, "工具栏不能挤走整个编辑画布")
                let scroll = try XCTUnwrap(allViews(in: host).compactMap { $0 as? NSScrollView }.first {
                    ($0.documentView?.bounds.height ?? 0) - $0.contentView.bounds.height > 100
                })
                scroll.contentView.scroll(to: NSPoint(x: 0, y: 120))
                scroll.reflectScrolledClipView(scroll.contentView)
                settle(host)
                XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, 50)
                XCTAssertEqual(try XCTUnwrap(record.frames["panelLayoutEditor"]).minY, toolbar.minY, accuracy: 0.5)
                XCTAssertEqual(try XCTUnwrap(record.frames["panelLayoutEditor"]).height, toolbar.height, accuracy: 0.5)
                XCTAssertEqual(fixture.defaults.data(forKey: PanelLayoutStore.storageKey), original)
                try writeDashboardEvidence(host, record: record, name: "pinned-editor-scrolled-\(Int(width))")
            }
        }
    }

    func testCompactDetailHeaderKeepsOverviewAndWindowActionsReachable() throws {
        try requireRendering()
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let originalArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(originalArguments, forName: UserDefaults.argumentDomain) }
        let store = PanelLayoutStore(defaults: fixture.defaults)
        for language in ["zh", "en"] {
            var arguments = originalArguments
            arguments["appLanguage"] = language
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            try withHost(fixture: fixture, store: store, scheme: .dark) { host, window, model, record in
                model.selected = .media
                model.deadZone = NotchDeadZone(width: 200, height: 32)
                for width: CGFloat in [160, 200] {
                    resizeForEvidence(host, window: window, model: model, record: record, width: width)
                    let header = try XCTUnwrap(record.frames["expandedPanelHeader"])
                    let overview = try XCTUnwrap(record.frames["expandedPanelOverview"])
                    let settings = try XCTUnwrap(record.frames["expandedPanelSettings"])
                    let close = try XCTUnwrap(record.frames["expandedPanelClose"])
                    for frame in [overview, settings, close] { assertContained(frame, in: header, name: "compact action") }
                    XCTAssertGreaterThan(overview.width, 40, "极窄页仍显示概览文字")
                    XCTAssertLessThanOrEqual(overview.maxX, settings.minX)
                    XCTAssertLessThanOrEqual(settings.maxX, close.minX)
                    XCTAssertNil(record.frames["panelLayoutBegin"], "极窄时保留核心操作，布局仍可从设置进入")
                    try writeDashboardEvidence(host, record: record, name: "compact-detail-\(language)-\(Int(width))")
                }
            }
        }
    }

    func testThreeWidgetEditorShowsHiddenRecoveryWithoutSavingLayout() throws {
        try requireRendering()
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let originalArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(originalArguments, forName: UserDefaults.argumentDomain) }
        var arguments = originalArguments
        arguments["appLanguage"] = "zh"
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        fixture.defaults.set(try JSONEncoder().encode(Set(["media", "calendar", "tray"])), forKey: "enabledWidgets")
        let store = PanelLayoutStore(defaults: fixture.defaults)
        try withHost(fixture: fixture, store: store, scheme: .dark) { host, window, model, record in
            model.editRequest = 1
            settle(host)
            resizeForEvidence(host, window: window, model: model, record: record, width: 800)
            XCTAssertNotNil(record.frames["panelLayoutHiddenModules"])
            assertContained(try XCTUnwrap(record.frames["panelLayoutShow-notes"]),
                in: try XCTUnwrap(record.frames["panelLayoutEditor"]), name: "show hidden notes")
            XCTAssertFalse(store.configuration.visibleItems.contains { $0.id == .notes })
            XCTAssertNil(fixture.defaults.object(forKey: PanelLayoutStore.storageKey))
            try writeDashboardEvidence(host, record: record, name: "editor-three-widgets-dark")
        }
    }

    private func allViews(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { allViews(in: $0) }
    }

    /// 真实窗口只用于人工/CUA 操作；程序创建截图不代表任何点击验收通过。
    func testRunIsolatedLiveGridEditor() throws {
        guard ProcessInfo.processInfo.environment["XNOOK_GRID_LIVE"] == "1" else {
            throw XCTSkip("使用 XNOOK_GRID_LIVE=1 启动隔离交互窗口")
        }
        #if !DEBUG
        throw XCTSkip("交互证据几何需要 Debug 构建")
        #endif
        let directory = evidenceRoot.appendingPathComponent("live", isDirectory: true)
        let stopURL = directory.appendingPathComponent("stop")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard !FileManager.default.fileExists(atPath: stopURL.path) else {
            throw XCTSkip("上次 stop 标记仍存在；删除该任务标记后可启动新窗口：\(stopURL.path)")
        }
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let store = PanelLayoutStore(defaults: fixture.defaults)
        let mediaDetail = ProcessInfo.processInfo.environment["XNOOK_GRID_LIVE_DETAIL"] == "media"
        let model = PanelGridNativeModel(width: mediaDetail ? 460 : 800, height: 720,
                                         editRequest: mediaDetail ? 0 : 1)
        if mediaDetail {
            model.selected = .media
            model.deadZone = NotchDeadZone(width: 200, height: 32)
        }
        let record = PanelGridNativeRecord()
        let app = NSApplication.shared
        let previousPolicy = app.activationPolicy()
        app.setActivationPolicy(.regular)
        app.finishLaunching()
        let host = NSHostingView(rootView: PanelGridNativeSurface(fixture: fixture, store: store,
            model: model, record: record, scheme: .dark))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: model.size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        let delegate = PanelGridNativeWindowDelegate(model: model, record: record)
        window.delegate = delegate
        window.isReleasedWhenClosed = false
        window.title = "XNook Grid Editor — Isolated"
        window.minSize = CGSize(width: 320, height: 360)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        defer {
            window.delegate = nil
            window.contentView = nil
            window.close()
            app.setActivationPolicy(previousPolicy)
        }
        settle(host)
        let requestedSeconds = Double(ProcessInfo.processInfo.environment["XNOOK_GRID_LIVE_SECONDS"] ?? "600") ?? 600
        let duration = requestedSeconds.isFinite ? min(max(requestedSeconds, 1), 600) : 600
        let startedAt = Date()
        let runID = "\(ProcessInfo.processInfo.processIdentifier)-\(Int(startedAt.timeIntervalSince1970))"
        var sequence = 0
        var lastSnapshotSignature = ""
        var timerError: Error?
        let captureState: () throws -> Void = {
            host.layoutSubtreeIfNeeded()
            try self.writeLiveState(fixture: fixture, store: store, model: model, record: record,
                window: window, directory: directory, startedAt: startedAt, status: "running")
            let signature = store.configuration.signature + "|\(record.isEditing)|\(model.width)|\(model.height)|"
                + self.geometrySignature(record.frames)
            if signature != lastSnapshotSignature {
                try self.writePNG(host, to: directory.appendingPathComponent("native-host-\(runID)-" + String(format: "%04d.png", sequence)))
                sequence += 1
                lastSnapshotSignature = signature
            }
        }
        try captureState()
        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated {
                do { try captureState() }
                catch { timerError = error }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }
        print("XNook isolated grid editor PID=\(ProcessInfo.processInfo.processIdentifier), window=\(window.windowNumber), state=\(directory.appendingPathComponent("state.json").path)")
        while !record.windowClosed, !FileManager.default.fileExists(atPath: stopURL.path),
              Date().timeIntervalSince(startedAt) < duration, timerError == nil {
            if let event = app.nextEvent(matching: .any, until: Date().addingTimeInterval(0.02),
                                         inMode: .default, dequeue: true) {
                app.sendEvent(event)
            }
            app.updateWindows()
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        timer.invalidate()
        if let timerError { throw timerError }
        let status = record.windowClosed ? (window.isVisible ? "close-requested" : "window-closed")
            : FileManager.default.fileExists(atPath: stopURL.path) ? "stop-requested" : "time-limit"
        try writeLiveState(fixture: fixture, store: store, model: model, record: record,
            window: window, directory: directory, startedAt: startedAt, status: status)
        if !record.windowClosed { try writePNG(host, to: directory.appendingPathComponent("native-host-\(runID)-final.png")) }
        try FileManager.default.copyItem(at: directory.appendingPathComponent("state.json"),
                                         to: directory.appendingPathComponent("state-\(runID).json"))
        try FileManager.default.copyItem(at: directory.appendingPathComponent("private-defaults.plist"),
                                         to: directory.appendingPathComponent("private-defaults-\(runID).plist"))
        try archiveFixture(fixture, to: directory.appendingPathComponent("fixture-\(runID)", isDirectory: true))
    }

    private var evidenceRoot: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/grid-editor-evidence", isDirectory: true)
    }

    private func requireRendering() throws {
        #if !DEBUG
        throw XCTSkip("原生几何探针仅在 Debug 构建中启用")
        #endif
        guard ProcessInfo.processInfo.environment["XNOOK_RENDER_UI"] == "1" else {
            throw XCTSkip("使用 XNOOK_RENDER_UI=1 执行隔离网格渲染")
        }
        _ = NSApplication.shared
    }

    private func makeFixture() throws -> WorkflowPreviewFixture {
        let fixture = try WorkflowPreviewFixture(historyCount: 5, trayFileCount: 6)
        fixture.defaults.set(true, forKey: "showNookFlowHistory")
        fixture.defaults.set(try JSONEncoder().encode(PanelLayoutConfiguration.defaultWidgetIDs), forKey: "enabledWidgets")
        _ = fixture.focus.start(title: "网格验收任务 · 保留计时、笔记和资料的隔离任务")
        fixture.focus.linkNote(id: fixture.sampleNotes[0].id, title: fixture.sampleNotes[0].title)
        return fixture
    }

    private func withHost(fixture: WorkflowPreviewFixture, store: PanelLayoutStore, scheme: ColorScheme,
                          verify: (NSHostingView<PanelGridNativeSurface>, NSWindow, PanelGridNativeModel, PanelGridNativeRecord) throws -> Void) throws {
        let model = PanelGridNativeModel(width: 800, height: 1800)
        let record = PanelGridNativeRecord()
        let host = NSHostingView(rootView: PanelGridNativeSurface(fixture: fixture, store: store,
            model: model, record: record, scheme: scheme))
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: model.width, height: model.height),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        settle(host)
        XCTAssertFalse(window.isVisible)
        try verify(host, window, model, record)
    }

    private func resizeForEvidence(_ host: NSView, window: NSWindow, model: PanelGridNativeModel,
                                   record: PanelGridNativeRecord, width: CGFloat) {
        model.width = width
        model.height = 1800
        window.setContentSize(model.size)
        settle(host)
        if let measurement = record.measurement {
            model.height = max(400, ceil(measurement.height) + 4)
            window.setContentSize(model.size)
            settle(host)
        }
    }

    private func settle(_ host: NSView) {
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.025))
        }
    }

    private func assertGeometry(_ record: PanelGridNativeRecord, configuration: PanelLayoutConfiguration,
                                size: CGSize, editing: Bool) throws {
        XCTAssertEqual(record.isEditing, editing)
        let body = try XCTUnwrap(record.frames["expandedPanelBody"])
        let modules = try configuration.visibleItems.map { item -> (PanelModuleID, CGRect) in
            let frame = try XCTUnwrap(record.frames["panelModule-\(item.id.rawValue)"], item.id.rawValue)
            assertContained(frame, in: body, name: item.id.rawValue)
            XCTAssertGreaterThan(frame.width, 0)
            XCTAssertGreaterThan(frame.height, 0)
            return (item.id, frame)
        }
        XCTAssertFalse(modules.isEmpty)
        for index in modules.indices {
            for other in modules.dropFirst(index + 1) {
                XCTAssertFalse(modules[index].1.insetBy(dx: 0.5, dy: 0.5).intersects(other.1),
                               "模块不能重叠：\(modules[index].0) / \(other.0)")
            }
        }
        let visibleIDs = Set(configuration.visibleItems.map(\.id))
        for (name, frame) in record.frames {
            if let module = owner(of: name), visibleIDs.contains(module),
               let parent = record.frames["panelModule-\(module.rawValue)"] {
                assertContained(frame, in: parent, name: name)
            }
        }
        for key in ["expandedPanelHeader", "expandedPanelNavigation", "expandedPanelBody"] {
            assertContained(try XCTUnwrap(record.frames[key]), in: CGRect(origin: .zero, size: size), name: key)
        }
        if editing {
            let toolbar = try XCTUnwrap(record.frames["panelLayoutEditor"])
            assertContained(toolbar, in: CGRect(origin: .zero, size: size), name: "panelLayoutEditor")
            XCTAssertLessThanOrEqual(toolbar.maxY, body.minY + 0.5, "编辑工具栏固定在正文视口上方")
            for id in ["Default", "Cancel", "Save", "Module", "Width", "Height", "Visible", "Earlier", "Later"] {
                let key = "panelLayout\(id)"
                assertContained(try XCTUnwrap(record.frames[key], key), in: toolbar, name: key)
            }
            for (id, parent) in modules {
                for prefix in ["panelLayoutMove-", "panelLayoutResize-"] {
                    let key = prefix + id.rawValue
                    assertContained(try XCTUnwrap(record.frames[key], key), in: parent, name: key)
                }
            }
        } else {
            for key in ["gridWidgetMediaControls", "gridWidgetCalendarShowAll", "gridWidgetNotesShowAll",
                        "expandedPanelTrayShowAll", "focusSessionEndTask", "focusSessionViewAllTasks"] {
                XCTAssertNotNil(record.frames[key], key)
            }
        }
    }

    private func owner(of name: String) -> PanelModuleID? {
        if name.hasPrefix("gridWidgetMedia") { return .media }
        if name.hasPrefix("gridWidgetCalendar") { return .calendar }
        if name.hasPrefix("gridWidgetNotes") { return .notes }
        if name.hasPrefix("expandedPanelTray") { return .tray }
        if name.hasPrefix("expandedPanelHistoryRow-") || name == "focusSessionRecentTasks" || name == "focusSessionViewAllTasks" { return .recentTasks }
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

    private func writeDashboardEvidence(_ host: NSView, record: PanelGridNativeRecord, name: String) throws {
        let directory = evidenceRoot.appendingPathComponent("dashboard", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writePNG(host, to: directory.appendingPathComponent(name + ".png"))
        try writeJSON(["frames": geometryJSON(record.frames), "isEditing": record.isEditing,
                       "evidenceKind": "isolated-native-render", "cuaInteractionVerified": false],
                      to: directory.appendingPathComponent(name + ".json"))
    }

    private func writeLiveState(fixture: WorkflowPreviewFixture, store: PanelLayoutStore, model: PanelGridNativeModel,
                                record: PanelGridNativeRecord, window: NSWindow, directory: URL,
                                startedAt: Date, status: String) throws {
        let defaultsSnapshot = directory.appendingPathComponent("private-defaults.plist")
        let domain = fixture.defaults.persistentDomain(forName: fixture.suiteName) ?? [:]
        try PropertyListSerialization.data(fromPropertyList: domain, format: .binary, options: 0)
            .write(to: defaultsSnapshot, options: .atomic)
        let configuration = try JSONSerialization.jsonObject(with: JSONEncoder().encode(store.configuration))
        let state: [String: Any] = [
            "timestamp": Date().ISO8601Format(), "startedAt": startedAt.ISO8601Format(), "status": status,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "bundleIdentifier": (Bundle.main.bundleIdentifier as Any?) ?? NSNull(),
            "executableURL": (Bundle.main.executableURL?.path as Any?) ?? NSNull(),
            "windowNumber": window.windowNumber, "windowTitle": window.title, "windowVisible": window.isVisible,
            "privateSuiteName": fixture.suiteName, "privateFixturePath": fixture.directory.path,
            "privateDefaultsSnapshotPath": defaultsSnapshot.path,
            "storeConfiguration": configuration, "storeLoadError": (store.loadError as Any?) ?? NSNull(),
            "isEditing": record.isEditing, "editRequest": model.editRequest,
            "selectedWidget": model.selected?.rawValue ?? "overview",
            "panelWidth": model.width, "panelHeight": model.height, "frames": geometryJSON(record.frames),
            "activeTaskCount": fixture.focus.activeSession == nil ? 0 : 1,
            "activeTaskID": (fixture.focus.activeSession?.id.uuidString as Any?) ?? NSNull(),
            "activeTaskStartedAt": (fixture.focus.activeSession?.startedAt.ISO8601Format() as Any?) ?? NSNull(),
            "historyCount": fixture.focus.history.count, "notesCount": fixture.notes.notes.count,
            "trayFileCount": fixture.tray.files.count, "fixtureOnly": true,
            "evidenceKind": "isolated-native-window", "cuaInteractionVerified": false
        ]
        try writeJSON(state, to: directory.appendingPathComponent("state.json"))
    }

    private func geometryJSON(_ frames: [String: CGRect]) -> [String: [String: CGFloat]] {
        frames.mapValues { ["x": $0.minX, "y": $0.minY, "width": $0.width, "height": $0.height] }
    }

    private func geometrySignature(_ frames: [String: CGRect]) -> String {
        frames.keys.sorted().map { key in
            let frame = frames[key]!
            return "\(key):\(frame.minX.rounded()),\(frame.minY.rounded()),\(frame.width.rounded()),\(frame.height.rounded())"
        }.joined(separator: ";")
    }

    private func writePNG(_ host: NSView, to output: URL) throws {
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 1000)
        try data.write(to: output, options: .atomic)
    }

    private func writeJSON(_ object: [String: Any], to output: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            .write(to: output, options: .atomic)
    }

    private func archiveFixture(_ fixture: WorkflowPreviewFixture, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for source in try FileManager.default.contentsOfDirectory(at: fixture.directory, includingPropertiesForKeys: nil) {
            let target = directory.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.copyItem(at: source, to: target)
        }
    }
}

@MainActor @Observable
private final class PanelGridNativeModel {
    var width: CGFloat
    var height: CGFloat
    var editRequest: Int
    var selected: NotchContentView.WidgetType?
    var deadZone = NotchDeadZone.none
    var recenterTrigger = 0
    var size: CGSize { CGSize(width: width, height: height) }
    init(width: CGFloat, height: CGFloat, editRequest: Int = 0) {
        self.width = width
        self.height = height
        self.editRequest = editRequest
    }
}

@MainActor
private final class PanelGridNativeRecord {
    var frames: [String: CGRect] = [:]
    var measurement: ExpandedPanelMeasurement?
    var isEditing = false
    var windowClosed = false
}

@MainActor
private struct PanelGridNativeSurface: View {
    let fixture: WorkflowPreviewFixture
    let store: PanelLayoutStore
    @Bindable var model: PanelGridNativeModel
    let record: PanelGridNativeRecord
    let scheme: ColorScheme

    var body: some View {
        ExpandedPanelView(selectedWidget: $model.selected, calendarRecenterTrigger: $model.recenterTrigger,
            enabledWidgets: store.configuration.visibleItems.compactMap { NotchContentView.WidgetType(rawValue: $0.id.rawValue) }, panelWidth: model.width,
            mediaManager: fixture.media, calendarManager: fixture.calendar, notesManager: fixture.notes,
            trayManager: fixture.tray, focusSessionManager: fixture.focus, showHistory: true, historyDisplayLimit: 5,
            onCreateLinkedNote: { false }, onLinkTrayFiles: {}, onEndSession: {},
            onOpenNote: { _ in false }, onOpenFile: { _ in false }, onStartFocus: { _ in },
            onInteractionChanged: { _ in }, onLinksPresentationChanged: { _ in },
            onSettings: {}, onClose: { record.windowClosed = true }, onMeasurement: { record.measurement = $0 },
            deadZone: model.deadZone, layoutStore: store, editRequest: model.editRequest,
            onEditRequestHandled: { model.editRequest = 0 }, onEditingChanged: { record.isEditing = $0 })
            .frame(width: model.width, height: model.height)
            .background(IslandStyle.surface(for: scheme))
            .environment(\.colorScheme, scheme)
            .environment(\.reportsExpandedPanelDebugGeometry, true)
            .defaultAppStorage(fixture.defaults)
            .onPreferenceChange(ExpandedPanelDebugGeometryKey.self) { record.frames = $0 }
    }
}

@MainActor
private final class PanelGridNativeWindowDelegate: NSObject, NSWindowDelegate {
    let model: PanelGridNativeModel
    let record: PanelGridNativeRecord
    init(model: PanelGridNativeModel, record: PanelGridNativeRecord) {
        self.model = model
        self.record = record
    }
    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let content = window.contentView else { return }
        model.width = content.bounds.width
        model.height = content.bounds.height
    }
    func windowWillClose(_ notification: Notification) { record.windowClosed = true }
}
