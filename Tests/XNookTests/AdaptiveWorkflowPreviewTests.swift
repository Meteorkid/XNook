import AppKit
import SwiftUI
import XCTest
@testable import XNook

/// 渲染生产 ExpandedPanelView；所有业务数据、偏好和权限读取均来自隔离夹具。
/// XNOOK_RENDER_UI=1 swift test --filter AdaptiveWorkflowPreviewTests
@MainActor
final class AdaptiveWorkflowPreviewTests: XCTestCase {
    private typealias Widget = NotchContentView.WidgetType

    func testAllWidgetCombinationsFitWithoutVacantGridCells() throws {
        try requireRendering()
        let allWidgets: [Widget] = [.media, .calendar, .notes, .tray]
        for width in [CGFloat(800), CGFloat(320)] {
            for mask in 0..<16 {
                let widgets = allWidgets.enumerated().compactMap { index, widget in
                    mask & (1 << index) == 0 ? nil : widget
                }
                let fixture = try WorkflowPreviewFixture(historyCount: 3)
                defer { fixture.cleanUp() }
                try render(fixture, widgets: widgets, width: width, maximumHeight: 2000,
                    name: "widget-matrix-\(Int(width))-mask-\(mask)") { result in
                    try assertPackedWidgetGrid(result)
                    try assertFixedControls(result)
                    try assertTasksFollowWidgets(result)
                    try assertContentFits(result)
                }
            }
        }
    }

    func testWidgetCountChangesRemoveOldCardsAndRepackTheSameHost() throws {
        try requireRendering()
        let allWidgets: [Widget] = [.media, .calendar, .notes, .tray]
        for width in [CGFloat(800), CGFloat(320)] {
            let fixture = try WorkflowPreviewFixture(historyCount: 3)
            defer { fixture.cleanUp() }
            try render(fixture, widgets: [], width: width, maximumHeight: 2000,
                name: "widget-switch-\(Int(width))-initial") { result in
                for (step, count) in [1, 2, 3, 4, 3, 2, 1, 0].enumerated() {
                    result.model.widgets = Array(allWidgets.prefix(count))
                    try resizeToMeasurement(result)
                    try writeEvidence(result, name: "widget-switch-\(Int(width))-step-\(step)-count-\(count)")
                    try assertPackedWidgetGrid(result)
                    try assertFixedControls(result)
                    try assertTasksFollowWidgets(result)
                    try assertContentFits(result)
                }
            }
        }
    }

    func testEqualHeightWidgetConfigurationChangeRefreshesMeasurement() throws {
        try requireRendering()
        let fixture = try WorkflowPreviewFixture(historyCount: 3, trayFileCount: 0)
        fixture.media.currentTitle = ""
        fixture.media.currentArtist = ""
        defer { fixture.cleanUp() }
        try render(fixture, widgets: [.media, .calendar, .tray], name: "widget-measurement-initial") { result in
            // onAppear 会刷新夹具日历，待视图挂载后再固定空态输入。
            fixture.calendar.upcomingEvents = []
            try resizeToMeasurement(result)
            XCTAssertTrue(fixture.calendar.upcomingEvents.isEmpty)
            try writeEvidence(result, name: "widget-measurement-before")
            let previous = try XCTUnwrap(result.record.latest)
            let previousCount = result.record.measurements.count
            result.model.widgets = [.media, .calendar]
            settle(result.host)
            try writeEvidence(result, name: "widget-measurement-after")
            try writeJSON([
                "scenario": "remove empty tray while retaining the tallest calendar card",
                "callbacksBefore": previousCount,
                "callbacksAfter": result.record.measurements.count,
                "heightBefore": previous.height,
                "heightAfter": result.record.latest?.height ?? 0,
                "parentClearsCachedMeasurementOnWidgetChange": true
            ], name: "widget-measurement-callbacks")
            XCTAssertEqual(try XCTUnwrap(result.record.latest).height, previous.height, accuracy: 1)
            XCTAssertGreaterThan(result.record.measurements.count, previousCount,
                "组件配置变化后即使自然高度相同，也必须回报测量，供父窗口恢复已清空的高度缓存")
        }
    }

    func testThreeWidgetsAndThreeHistoryRowsFitInBothLanguagesAndAppearances() throws {
        try requireRendering()
        for language in ["zh", "en"] {
            for scheme in [ColorScheme.light, .dark] {
                let fixture = try WorkflowPreviewFixture(historyCount: 3)
                defer { fixture.cleanUp() }
                try withLanguage(language) {
                    try render(fixture, widgets: [.media, .calendar, .tray], scheme: scheme,
                        name: "adaptive-three-history-\(language)-\(scheme == .dark ? "dark" : "light")") { result in
                        let cards = try widgetFrames(result)
                        XCTAssertEqual(cards.count, 3)
                        XCTAssertEqual(try XCTUnwrap(cards[.media]).minY, try XCTUnwrap(cards[.tray]).minY, accuracy: 1)
                        XCTAssertLessThan(try XCTUnwrap(cards[.media]).maxX, try XCTUnwrap(cards[.calendar]).minX)
                        XCTAssertLessThan(try XCTUnwrap(cards[.calendar]).maxX, try XCTUnwrap(cards[.tray]).minX)
                        XCTAssertEqual(result.record.frames.keys.filter { $0.hasPrefix("expandedPanelHistoryRow-") }.count, 3)
                        try assertFixedControls(result)
                        try assertTasksFollowWidgets(result)
                        try assertContentFits(result)
                    }
                }
            }
        }
    }

    func testFourWidgetsFormTwoRowsAndFiveHistoryRowsFitNaturally() throws {
        try requireRendering()
        let fixture = try WorkflowPreviewFixture(historyCount: 5, trayFileCount: 6)
        defer { fixture.cleanUp() }
        try render(fixture, widgets: [.media, .calendar, .notes, .tray], historyLimit: 5,
            name: "adaptive-four-widgets-five-history") { result in
            let cards = try widgetFrames(result)
            let media = try XCTUnwrap(cards[.media])
            let calendar = try XCTUnwrap(cards[.calendar])
            let notes = try XCTUnwrap(cards[.notes])
            let tray = try XCTUnwrap(cards[.tray])
            XCTAssertEqual(media.minY, calendar.minY, accuracy: 1)
            XCTAssertEqual(notes.minY, tray.minY, accuracy: 1)
            XCTAssertGreaterThan(notes.minY, max(media.maxY, calendar.maxY))
            XCTAssertEqual(media.minX, notes.minX, accuracy: 1)
            XCTAssertEqual(calendar.minX, tray.minX, accuracy: 1)
            XCTAssertGreaterThan(result.model.height, 400)
            try assertTasksFollowWidgets(result)
            try assertContentFits(result)
            XCTAssertEqual(result.record.frames.keys.filter { $0.hasPrefix("expandedPanelHistoryRow-") }.count, 5)
            let tasks = try frame("expandedPanelRecentTasks", in: result)
            for session in fixture.focus.history {
                let row = try frame("expandedPanelHistoryRow-" + session.id.uuidString, in: result)
                XCTAssertGreaterThanOrEqual(row.height, 28)
                XCTAssertGreaterThanOrEqual(row.minY, tasks.minY)
                XCTAssertLessThanOrEqual(row.maxY, tasks.maxY)
            }
        }
    }

    func testEditingNotesUsesNaturalOverviewHeightAndFullDetailEditor() throws {
        try requireRendering()
        let fixture = try WorkflowPreviewFixture(historyCount: 3, trayFileCount: 6)
        defer { fixture.cleanUp() }
        XCTAssertTrue(fixture.notes.selectNote(id: fixture.sampleNotes[0].id))
        XCTAssertNotNil(fixture.focus.start(title: "正在验收：笔记、日程与任务网页资料 · Active workflow"))
        try render(fixture, widgets: [.calendar, .notes, .tray], scheme: .light,
            name: "adaptive-editing-notes-overview") { result in
            let notesCard = try XCTUnwrap(widgetFrames(result)[.notes])
            XCTAssertGreaterThan(notesCard.height, 244, "真实编辑控件的自然高度不能再被旧244pt卡片截断")
            try assertTasksFollowWidgets(result)
            try assertContentFits(result)

            result.model.selected = .notes
            try resizeToMeasurement(result)
            XCTAssertEqual(try XCTUnwrap(result.record.latest).selectedWidget, .notes)
            let editor = try XCTUnwrap(descendants(of: result.host).compactMap { $0 as? NSTextView }.first)
            let editorScroll = try XCTUnwrap(editor.enclosingScrollView)
            let editorFrame = viewFrame(editorScroll, in: result.host)
            // 生产 TextEditor 的240pt区域包含上下各4pt内边距。
            XCTAssertEqual(editorFrame.height + 8, 240, accuracy: 1)
            XCTAssertGreaterThan(editorFrame.width, 200)
            XCTAssertGreaterThanOrEqual(editorFrame.minY, ExpandedPanelLayout.headerHeight)
            XCTAssertLessThanOrEqual(editorFrame.maxY, result.model.height)
            XCTAssertGreaterThan(try XCTUnwrap(result.record.latest).height, ExpandedPanelLayout.headerHeight + 244)
            try assertFixedControls(result)
            try writeEvidence(result, name: "adaptive-notes-detail-editor")
        }
    }

    func testTrayOverviewAndDetailExposeTheCorrectFileCountsAndMeasurementModes() throws {
        try requireRendering()
        let fixture = try WorkflowPreviewFixture(historyCount: 3, trayFileCount: 6)
        defer { fixture.cleanUp() }
        try render(fixture, widgets: [.media, .calendar, .tray], name: "adaptive-tray-overview") { result in
            let overviewHeight = try XCTUnwrap(result.record.latest).height
            XCTAssertEqual(result.record.frames.keys.filter { $0.hasPrefix("expandedPanelTrayFile-") }.count, 4)
            XCTAssertGreaterThan(try frame("expandedPanelTrayFile-" + fixture.tray.files[3].id.uuidString, in: result).height, 0)
            XCTAssertNil(result.record.frames["expandedPanelTrayFile-" + fixture.tray.files[5].id.uuidString])
            XCTAssertGreaterThan(try frame("expandedPanelTrayShowAll", in: result).height, 0)

            result.model.selected = .tray
            try resizeToMeasurement(result)
            let detail = try XCTUnwrap(result.record.latest)
            XCTAssertEqual(detail.selectedWidget, .tray)
            XCTAssertEqual(detail.width, result.model.width, accuracy: 0.5)
            XCTAssertEqual(result.record.frames.keys.filter { $0.hasPrefix("expandedPanelTrayFile-") }.count, 6)
            XCTAssertGreaterThan(try frame("expandedPanelTrayFile-" + fixture.tray.files[5].id.uuidString, in: result).height, 0)
            XCTAssertNil(result.record.frames["expandedPanelTrayShowAll"])
            XCTAssertNotEqual(detail.height, overviewHeight)
            try assertContentFits(result)
            try writeEvidence(result, name: "adaptive-tray-detail-six-files")

            result.model.selected = nil
            try resizeToMeasurement(result)
            XCTAssertNil(try XCTUnwrap(result.record.latest).selectedWidget)
            XCTAssertEqual(try XCTUnwrap(result.record.latest).height, overviewHeight, accuracy: 1)
            try assertTasksFollowWidgets(result)
        }
    }

    func testNarrowAndDegradedWidthsKeepRealCardsInsideTheViewport() throws {
        try requireRendering()
        for width in [CGFloat(320), CGFloat(160)] {
            let fixture = try WorkflowPreviewFixture(historyCount: 3, trayFileCount: 6)
            defer { fixture.cleanUp() }
            fixture.media.currentTitle = String(repeating: "很长的媒体标题 · Long media title ", count: 4)
            try render(fixture, widgets: [.media, .calendar, .tray], width: width, maximumHeight: 2000,
                name: "adaptive-narrow-\(Int(width))") { result in
                let cards = try widgetFrames(result)
                let media = try XCTUnwrap(cards[.media])
                let calendar = try XCTUnwrap(cards[.calendar])
                let tray = try XCTUnwrap(cards[.tray])
                XCTAssertGreaterThan(calendar.minY, media.maxY)
                XCTAssertGreaterThan(tray.minY, calendar.maxY)
                for frame in cards.values {
                    XCTAssertGreaterThan(frame.width, 0)
                    XCTAssertGreaterThanOrEqual(frame.minX, 0)
                    XCTAssertLessThanOrEqual(frame.maxX, width + 1)
                }
                try assertFixedControls(result)
                try assertTasksFollowWidgets(result)
                try assertContentFits(result)
            }
        }
    }

    func testManualAndShortScreenLimitsKeepTitleAndNavigationFixedWhileScrollingToTasks() throws {
        try requireRendering()
        for limit in [CGFloat(200), CGFloat(190)] {
            let fixture = try WorkflowPreviewFixture(historyCount: 3)
            defer { fixture.cleanUp() }
            let name = limit == 200 ? "adaptive-manual-200" : "adaptive-short-screen-190"
            try render(fixture, widgets: [.media, .calendar, .notes], maximumHeight: limit, name: name) { result in
                XCTAssertEqual(result.model.height, limit, accuracy: 0.5)
                let headerBefore = try frame("expandedPanelHeader", in: result)
                let navigationBefore = try frame("expandedPanelNavigation", in: result)
                let scroll = try outerScrollView(result)
                let document = try XCTUnwrap(scroll.documentView)
                XCTAssertGreaterThan(document.bounds.height, scroll.contentView.bounds.height + 40)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
                scroll.reflectScrolledClipView(scroll.contentView)
                settle(result.host)
                XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0)
                XCTAssertEqual(try frame("expandedPanelHeader", in: result), headerBefore)
                XCTAssertEqual(try frame("expandedPanelNavigation", in: result), navigationBefore)
                try assertFixedControls(result)
                let tasks = try frame("expandedPanelRecentTasks", in: result)
                let viewport = viewFrame(scroll, in: result.host)
                XCTAssertLessThanOrEqual(tasks.maxY, viewport.maxY + 1)
                XCTAssertGreaterThan(tasks.intersection(viewport).height, 30, "滚到底后任务区必须进入正文可见范围")
                XCTAssertEqual(scroll.contentView.bounds.maxY, document.bounds.maxY, accuracy: 1)
                try writeEvidence(result, name: name + "-scrolled-bottom")
            }
        }
    }

    func testChangingRealGridColumnsPreservesWidgetStateIdentity() throws {
        try requireRendering()
        let model = GridIdentityModel()
        let record = GridIdentityRecord()
        let host = NSHostingView(rootView: GridIdentityPreview(model: model, record: record))
        let window = makeWindow(size: CGSize(width: 800, height: 300), scheme: .dark)
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 300)
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        settle(host)
        let before = record.values
        XCTAssertEqual(before.count, 3)
        model.columns = 1
        settle(host)
        XCTAssertEqual(record.values.count, 3)
        for index in 0..<3 {
            let original = try XCTUnwrap(before[index])
            let current = try XCTUnwrap(record.values[index])
            XCTAssertEqual(current.identity, original.identity)
            XCTAssertGreaterThan(current.width, original.width * 2)
        }
        XCTAssertFalse(window.isVisible)
        let data: [String: Any] = [
            "columnsBefore": 3, "columnsAfter": 1,
            "states": (0..<3).map { index in
                ["index": index, "beforeIdentity": before[index]?.identity.uuidString ?? "",
                 "afterIdentity": record.values[index]?.identity.uuidString ?? "",
                 "beforeWidth": before[index]?.width ?? 0,
                 "afterWidth": record.values[index]?.width ?? 0] as [String: Any]
            }
        ]
        try writeJSON(data, name: "adaptive-grid-state-retention")
    }

    private func requireRendering() throws {
        #if !DEBUG
        throw XCTSkip("真实视图几何探针仅在 Debug 构建启用；请以 Debug 运行隔离渲染测试")
        #endif
        guard ProcessInfo.processInfo.environment["XNOOK_RENDER_UI"] == "1" else {
            throw XCTSkip("使用 XNOOK_RENDER_UI=1 执行隔离离屏原生渲染")
        }
        _ = NSApplication.shared
    }

    private func withLanguage(_ language: String, action: () throws -> Void) rethrows {
        let original = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        var arguments = original
        arguments["appLanguage"] = language
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
        try action()
    }

    private func render(_ fixture: WorkflowPreviewFixture, widgets: [Widget], width: CGFloat = 800,
                        maximumHeight: CGFloat = 1200, historyLimit: Int = 3, scheme: ColorScheme = .dark,
                        name: String, verify: (WorkflowRenderResult) throws -> Void) throws {
        let model = WorkflowRenderModel(width: width, height: min(400, maximumHeight), widgets: widgets)
        let record = WorkflowMeasurementRecord()
        let host = NSHostingView(rootView: WorkflowPanelPreview(fixture: fixture,
            historyLimit: historyLimit, model: model, record: record, scheme: scheme))
        host.frame = NSRect(origin: .zero, size: model.size)
        let window = makeWindow(size: model.size, scheme: scheme)
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        let result = WorkflowRenderResult(model: model, record: record, host: host, window: window,
            maximumHeight: maximumHeight)
        try resizeToMeasurement(result)
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(host.bounds.size, model.size)
        try writeEvidence(result, name: name)
        try verify(result)
    }

    private func resizeToMeasurement(_ result: WorkflowRenderResult) throws {
        settle(result.host)
        let measurement = try XCTUnwrap(result.record.latest)
        XCTAssertEqual(measurement.width, result.model.width, accuracy: 0.5)
        XCTAssertEqual(measurement.selectedWidget, result.model.selected)
        XCTAssertEqual(measurement.enabledWidgets, result.model.widgets)
        XCTAssertTrue(measurement.height.isFinite && measurement.height > ExpandedPanelLayout.headerHeight)
        result.model.height = ExpandedPanelLayout.height(measuredContentHeight: measurement.height,
            maximumHeight: result.maximumHeight)
        result.window.setContentSize(result.model.size)
        settle(result.host)
        XCTAssertEqual(try XCTUnwrap(result.record.latest).height, measurement.height, accuracy: 1,
            "只改变视口高度不应改变正文自然高度")
    }

    private func makeWindow(size: CGSize, scheme: ColorScheme) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        return window
    }

    private func settle(_ host: NSView) {
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
    }

    private func assertFixedControls(_ result: WorkflowRenderResult) throws {
        let header = try frame("expandedPanelHeader", in: result)
        let navigation = try frame("expandedPanelNavigation", in: result)
        let body = viewFrame(try outerScrollView(result), in: result.host)
        let reportedBody = try frame("expandedPanelBody", in: result)
        XCTAssertEqual(header.minY, 0, accuracy: 1)
        XCTAssertEqual(header.height, IslandTokens.Layout.headerHeight, accuracy: 1)
        XCTAssertEqual(navigation.minY, header.maxY, accuracy: 1)
        XCTAssertEqual(navigation.height, IslandTokens.Layout.navigationHeight, accuracy: 1)
        XCTAssertEqual(body.minY, ExpandedPanelLayout.headerHeight, accuracy: 1)
        XCTAssertEqual(body.maxY, result.model.height, accuracy: 1)
        XCTAssertEqual(reportedBody.minY, body.minY, accuracy: 1)
        XCTAssertEqual(reportedBody.height, body.height, accuracy: 1)
    }

    private func assertTasksFollowWidgets(_ result: WorkflowRenderResult) throws {
        let tasks = try frame("expandedPanelRecentTasks", in: result)
        for card in try widgetFrames(result).values {
            XCTAssertGreaterThan(tasks.minY, card.maxY)
        }
        XCTAssertGreaterThan(tasks.height, 40)
    }

    private func assertPackedWidgetGrid(_ result: WorkflowRenderResult) throws {
        let identifiers = Set(result.record.frames.keys.filter { $0.hasPrefix("expandedPanelWidget-") })
        XCTAssertEqual(identifiers, Set(result.widgets.map { "expandedPanelWidget-" + $0.rawValue }),
            "关闭的组件不能留下旧卡片或占位格")
        let tasks = try frame("expandedPanelRecentTasks", in: result)
        guard !result.widgets.isEmpty else {
            XCTAssertNil(result.record.frames["expandedPanelWidgets"])
            let emptyStateMaximumHeight = ExpandedPanelLayout.outerPadding
                + IslandTokens.Spacing.group * 2 + IslandTokens.Spacing.section + 24
            XCTAssertLessThanOrEqual(tasks.minY - ExpandedPanelLayout.headerHeight, emptyStateMaximumHeight,
                "全部关闭时只保留原有间距和单行空状态提示，不能继续占用组件网格高度")
            return
        }
        let grid = try frame("expandedPanelWidgets", in: result)
        let cards = try result.widgets.map { try frame("expandedPanelWidget-" + $0.rawValue, in: result) }
        let columns = result.model.width == 800 ? [0, 1, 2, 3, 2][cards.count] : 1
        let spacing = ExpandedPanelLayout.columnSpacing
        let cellWidth = (grid.width - CGFloat(columns - 1) * spacing) / CGFloat(columns)
        var expectedY = grid.minY
        for rowStart in stride(from: 0, to: cards.count, by: columns) {
            let row = Array(cards[rowStart..<min(rowStart + columns, cards.count)])
            XCTAssertEqual(row.count, columns, "本轮0–4组件配置不应产生空白占位列")
            for (column, card) in row.enumerated() {
                XCTAssertEqual(card.minX, grid.minX + CGFloat(column) * (cellWidth + spacing), accuracy: 1)
                XCTAssertEqual(card.minY, expectedY, accuracy: 1)
                XCTAssertEqual(card.width, cellWidth, accuracy: 1)
                XCTAssertGreaterThan(card.height, 0)
            }
            expectedY = try XCTUnwrap(row.map(\.maxY).max()) + spacing
        }
        XCTAssertEqual(grid.maxY, expectedY - spacing, accuracy: 1,
            "网格高度应随最后一行收拢，不能保留旧行")
        XCTAssertLessThanOrEqual(tasks.minY - grid.maxY, 32,
            "最近任务应紧接组件网格，不能留下空白行")
        for left in cards.indices {
            for right in cards.indices where right > left {
                XCTAssertTrue(cards[left].intersection(cards[right]).isEmpty, "组件卡片不得重叠")
            }
        }
    }

    private func assertContentFits(_ result: WorkflowRenderResult) throws {
        let measurement = try XCTUnwrap(result.record.latest)
        XCTAssertEqual(result.model.height, ceil(measurement.height), accuracy: 1)
        let scroll = try outerScrollView(result)
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertLessThanOrEqual(document.bounds.height, scroll.contentView.bounds.height + 1)
        for (identifier, rectangle) in result.record.frames where identifier.hasPrefix("expandedPanel") {
            XCTAssertGreaterThanOrEqual(rectangle.minX, -1, identifier)
            XCTAssertLessThanOrEqual(rectangle.maxX, result.model.width + 1, identifier)
            XCTAssertGreaterThanOrEqual(rectangle.minY, -1, identifier)
            XCTAssertLessThanOrEqual(rectangle.maxY, result.model.height + 1, identifier)
        }
    }

    private func widgetFrames(_ result: WorkflowRenderResult) throws -> [Widget: CGRect] {
        try Dictionary(uniqueKeysWithValues: result.widgets.map { widget in
            (widget, try frame("expandedPanelWidget-" + widget.rawValue, in: result))
        })
    }

    private func frame(_ identifier: String, in result: WorkflowRenderResult) throws -> CGRect {
        try XCTUnwrap(result.record.frames[identifier], "未捕获生产面板实际元素的几何信息：\(identifier)")
    }

    private func outerScrollView(_ result: WorkflowRenderResult) throws -> NSScrollView {
        try XCTUnwrap(descendants(of: result.host).compactMap { $0 as? NSScrollView }.first {
            let rectangle = viewFrame($0, in: result.host)
            return abs(rectangle.width - result.model.width) < 2
                && abs(rectangle.minY - ExpandedPanelLayout.headerHeight) < 2
        }, "未找到标题和导航下方的真实正文滚动视口")
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func viewFrame(_ view: NSView, in host: NSView) -> CGRect {
        topLeftFrame(view.convert(view.bounds, to: host), in: host)
    }

    private func topLeftFrame(_ rectangle: CGRect, in host: NSView) -> CGRect {
        guard !host.isFlipped else { return rectangle }
        return CGRect(x: rectangle.minX, y: host.bounds.height - rectangle.maxY,
            width: rectangle.width, height: rectangle.height)
    }

    private var outputDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["XNOOK_UI_EVIDENCE_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".build/reliability-adaptive-evidence/ui", isDirectory: true)
    }

    private func writeJSON(_ object: [String: Any], name: String) throws {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            .write(to: outputDirectory.appendingPathComponent(name + ".json"), options: .atomic)
    }

    private func writeEvidence(_ result: WorkflowRenderResult, name: String) throws {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(result.host.bitmapImageRepForCachingDisplay(in: result.host.bounds))
        result.host.cacheDisplay(in: result.host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1000)
        try png.write(to: outputDirectory.appendingPathComponent(name + ".png"), options: .atomic)
        let scrolls: [[String: Any]] = descendants(of: result.host).compactMap { $0 as? NSScrollView }.map {
            ["frame": rectJSON(viewFrame($0, in: result.host)),
             "viewport": rectJSON($0.contentView.bounds),
             "document": rectJSON($0.documentView?.bounds ?? .zero)]
        }
        let geometry: [String: Any] = [
            "view": "ExpandedPanelView", "width": result.model.width, "height": result.model.height,
            "maximumHeight": result.maximumHeight, "windowVisible": result.window.isVisible,
            "acceptanceScope": "isolated-offscreen-production-view", "realWindowAcceptance": false,
            "selectedWidget": result.model.selected?.rawValue ?? "overview",
            "enabledWidgets": result.widgets.map(\.rawValue),
            "measurementHeight": result.record.latest?.height ?? 0,
            "measurementWidth": result.record.latest?.width ?? 0,
            "measurementMode": result.record.latest?.selectedWidget?.rawValue ?? "overview",
            "measurementWidgets": result.record.latest?.enabledWidgets.map(\.rawValue) ?? [],
            "framesSource": "ExpandedPanelDebugGeometryKey",
            "frames": result.record.frames.mapValues(rectJSON), "scrollViews": scrolls,
            "nativeTextEditors": descendants(of: result.host).compactMap { $0 as? NSTextView }
                .compactMap { $0.enclosingScrollView }.map { rectJSON(viewFrame($0, in: result.host)) }
        ]
        try writeJSON(geometry, name: name)
    }

    private func rectJSON(_ rectangle: CGRect) -> [String: CGFloat] {
        ["x": rectangle.minX, "y": rectangle.minY, "width": rectangle.width, "height": rectangle.height]
    }
}

@MainActor
private final class WorkflowRenderModel: ObservableObject {
    let width: CGFloat
    @Published var height: CGFloat
    @Published var selected: NotchContentView.WidgetType?
    @Published var widgets: [NotchContentView.WidgetType]
    var size: CGSize { CGSize(width: width, height: height) }
    init(width: CGFloat, height: CGFloat, widgets: [NotchContentView.WidgetType]) {
        self.width = width; self.height = height; self.widgets = widgets
    }
}

private final class WorkflowMeasurementRecord {
    var latest: ExpandedPanelMeasurement?
    var measurements: [ExpandedPanelMeasurement] = []
    var frames: [String: CGRect] = [:]
}

@MainActor
private struct WorkflowRenderResult {
    let model: WorkflowRenderModel
    let record: WorkflowMeasurementRecord
    let host: NSView
    let window: NSWindow
    var widgets: [NotchContentView.WidgetType] { model.widgets }
    let maximumHeight: CGFloat
}

@MainActor
private struct WorkflowPanelPreview: View {
    let fixture: WorkflowPreviewFixture
    let historyLimit: Int
    @ObservedObject var model: WorkflowRenderModel
    let record: WorkflowMeasurementRecord
    let scheme: ColorScheme

    var body: some View {
        ExpandedPanelView(selectedWidget: $model.selected, calendarRecenterTrigger: .constant(0),
            enabledWidgets: model.widgets, panelWidth: model.width, mediaManager: fixture.media,
            calendarManager: fixture.calendar, notesManager: fixture.notes, trayManager: fixture.tray,
            focusSessionManager: fixture.focus, showHistory: true, historyDisplayLimit: historyLimit,
            onCreateLinkedNote: { XCTFail("渲染不得创建笔记"); return false },
            onLinkTrayFiles: { XCTFail("渲染不得关联文件") }, onEndSession: { XCTFail("渲染不得结束任务") },
            onOpenNote: { _ in XCTFail("渲染不得打开笔记"); return false },
            onOpenFile: { _ in XCTFail("渲染不得打开文件"); return false },
            onStartFocus: { _ in XCTFail("渲染不得从日历启动任务") },
            onInteractionChanged: { _ in }, onLinksPresentationChanged: { _ in },
            onSettings: { XCTFail("渲染不得打开设置") }, onClose: {},
            onMeasurement: { record.latest = $0; record.measurements.append($0) })
            .frame(width: model.width, height: model.height)
            .background(IslandStyle.surface(for: scheme))
            .environment(\.colorScheme, scheme)
            .defaultAppStorage(fixture.defaults)
            .environment(\.reportsExpandedPanelDebugGeometry, true)
            .onPreferenceChange(ExpandedPanelDebugGeometryKey.self) { record.frames = $0 }
    }
}

@MainActor
private final class GridIdentityModel: ObservableObject {
    @Published var columns = 3
}

private struct GridIdentityValue: Equatable {
    let identity: UUID
    let width: CGFloat
}

private final class GridIdentityRecord {
    var values: [Int: GridIdentityValue] = [:]
}

private struct GridIdentityPreference: PreferenceKey {
    static var defaultValue: [Int: GridIdentityValue] = [:]
    static func reduce(value: inout [Int: GridIdentityValue], nextValue: () -> [Int: GridIdentityValue]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct GridIdentityWidget: View {
    let index: Int
    @State private var identity = UUID()
    var body: some View {
        Text("Widget \(index)")
            .frame(maxWidth: .infinity)
            .frame(height: CGFloat(60 + index * 10))
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: GridIdentityPreference.self,
                        value: [index: GridIdentityValue(identity: identity, width: geometry.size.width)])
                }
            }
    }
}

@MainActor
private struct GridIdentityPreview: View {
    @ObservedObject var model: GridIdentityModel
    let record: GridIdentityRecord
    var body: some View {
        PanelWidgetGrid(columns: model.columns) {
            ForEach(0..<3) { GridIdentityWidget(index: $0) }
        }
        .frame(width: 776)
        .frame(width: 800, height: 300, alignment: .top)
        .onPreferenceChange(GridIdentityPreference.self) { record.values = $0 }
    }
}
