import AppKit
import EventKit
import Observation
import SwiftUI
import XCTest
@testable import XNook

/// 仅使用临时业务夹具；XNOOK_RENDER_UI=1 时验证原生布局，不启动正式应用。
@MainActor
final class GridWidgetNativePreviewTests: XCTestCase {
    func testOverviewCardsFitMinimumHeightsAtEverySupportedWidth() throws {
        try requireRendering()
        let fixture = try WorkflowPreviewFixture(historyCount: 0, trayFileCount: 6)
        defer { fixture.cleanUp() }
        for language in ["zh", "en"] {
            try withLanguage(language) {
                for width: CGFloat in [136, 160, 220, 320, 480, 720] {
                    for kind in GridWidgetPreviewKind.allCases {
                        // 160pt 旧面板扣除外边距后，媒体卡片只有 136pt 可用宽度。
                        if width < 220 && kind != .media { continue }
                        let height: CGFloat = kind == .tray ? 136 : 184
                        let scheme: ColorScheme = language == "zh" ? .dark : .light
                        try withHost(width: width, height: height, scheme: scheme, content: { bodyHeight in
                            self.widget(kind, fixture: fixture, bodyHeight: bodyHeight)
                        }) { host, _, record in
                            makeCurrentEvents(fixture.calendar)
                            settle(host)
                            try assertContentFits(record, width: width, height: height)
                            switch kind {
                            case .media:
                                let artwork = try XCTUnwrap(record.frames["gridWidgetMediaArtwork"])
                                let controls = try XCTUnwrap(record.frames["gridWidgetMediaControls"])
                                if width < 220 {
                                    XCTAssertGreaterThan(controls.minY, artwork.maxY)
                                } else {
                                    XCTAssertGreaterThan(controls.minX, artwork.maxX)
                                }
                                XCTAssertGreaterThanOrEqual(controls.width, 96)
                            case .calendar:
                                XCTAssertEqual(record.frames.keys.filter { $0.hasPrefix("gridWidgetCalendarDay-") }.count,
                                               GridWidgetContentLayout.calendarDayCount(width: width - 24))
                                XCTAssertNotNil(record.frames["gridWidgetCalendarShowAll"])
                            case .notes:
                                XCTAssertEqual(record.frames.keys.filter { $0.hasPrefix("gridWidgetNotesRow-") }.count, 2)
                                XCTAssertNotNil(record.frames["gridWidgetNotesShowAll"])
                            case .tray:
                                XCTAssertEqual(record.frames.keys.filter { $0.hasPrefix("expandedPanelTrayFile-") }.count, 1)
                                XCTAssertNotNil(record.frames["expandedPanelTrayShowAll"])
                            }
                            try writeEvidence(host, record: record, name: "\(kind.rawValue)-\(Int(width))-\(language)")
                        }
                    }
                }
            }
        }
    }

    func testOverviewAndDetailResizePreserveSelectedDayWhileDetailStillScrolls() throws {
        try requireRendering()
        let fixture = try WorkflowPreviewFixture(historyCount: 0)
        defer { fixture.cleanUp() }
        let selected = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 7, to: fixture.calendar.currentDate))
        for isDetail in [false, true] {
            fixture.calendar.loadEvents(for: selected)
            try withHost(width: 220, height: 400, content: { bodyHeight in
                AnyView(CalendarWidgetView(calendarManager: fixture.calendar, recenterTrigger: .constant(0),
                    onStartFocus: nil, isDetail: isDetail, onShowAll: {}, availableHeight: bodyHeight))
            }) { host, model, _ in
                for width: CGFloat in [480, 720, 320, 220] {
                    resize(host, model: model, width: width)
                    XCTAssertTrue(Calendar.current.isDate(fixture.calendar.displayedDate, inSameDayAs: selected),
                                  "调整卡片宽度不应选择另一日期，detail=\(isDetail), width=\(width)")
                }
                if isDetail {
                    let scrollView = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }
                        .first { $0.documentView is NSStackView })
                    let origin = scrollView.contentView.bounds.origin
                    scrollView.contentView.scroll(to: CGPoint(x: origin.x - 72, y: origin.y))
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                    settle(host)
                    XCTAssertEqual(scrollView.contentView.bounds.origin.x, origin.x - 72, accuracy: 0.5,
                                   "真实横滚不能被待执行的布局重居中吞掉")
                    let scrolledDate = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -2, to: selected))
                    XCTAssertTrue(Calendar.current.isDate(fixture.calendar.displayedDate, inSameDayAs: scrolledDate),
                                  "每格36pt，真实横滚72pt应选择前两日")
                    for width: CGFloat in [480, 220] {
                        resize(host, model: model, width: width)
                        XCTAssertTrue(Calendar.current.isDate(fixture.calendar.displayedDate, inSameDayAs: scrolledDate),
                                      "再次缩放应保留用户刚滚动选中的日期")
                    }
                }
            }
        }
    }

    func testCompactNotesKeepEditingSelectionAndAllStoredContentDuringResize() throws {
        try requireRendering()
        let fixture = try WorkflowPreviewFixture(historyCount: 0)
        defer { fixture.cleanUp() }
        XCTAssertTrue(fixture.notes.selectNote(id: fixture.sampleNotes[0].id))
        let selectedID = fixture.notes.currentNote?.id
        let originalNotes = fixture.notes.notes
        try withHost(width: 220, height: 184, content: { bodyHeight in
            AnyView(NotesWidgetView(notesManager: fixture.notes, onShowAll: {}, availableHeight: bodyHeight))
        }) { host, model, record in
            try assertContentFits(record, width: 220, height: 184)
            resize(host, model: model, width: 480)
            try assertContentFits(record, width: 480, height: 184)
            XCTAssertEqual(fixture.notes.currentNote?.id, selectedID)
            XCTAssertTrue(fixture.notes.isEditing)
            XCTAssertEqual(fixture.notes.notes.map(\.id), originalNotes.map(\.id))
            XCTAssertEqual(fixture.notes.notes.map(\.content), originalNotes.map(\.content))
        }
    }

    func testCalendarAccessPromptFitsWithoutRequestingPermission() throws {
        try requireRendering()
        var accessRequests = 0
        let manager = CalendarManager(observeChanges: false, readAuthorization: { .notDetermined },
            fetchCalendars: { XCTFail("无权限概览不可读取日历"); return [] },
            requestFullAccess: { accessRequests += 1; return false }, didRefreshAuthorization: {})
        try withLanguage("en") {
            try withHost(width: 220, height: 184, scheme: .light, content: { bodyHeight in
                AnyView(CalendarWidgetView(calendarManager: manager, recenterTrigger: .constant(0),
                    onStartFocus: nil, onShowAll: {}, availableHeight: bodyHeight))
            }) { host, model, record in
                try assertContentFits(record, width: 220, height: 184)
                try writeEvidence(host, record: record, name: "calendar-no-access-220-en")
                resize(host, model: model, width: 480)
                XCTAssertEqual(accessRequests, 0)
            }
        }
    }

    private func widget(_ kind: GridWidgetPreviewKind, fixture: WorkflowPreviewFixture, bodyHeight: CGFloat) -> AnyView {
        switch kind {
        case .media:
            return AnyView(MediaWidgetView(mediaManager: fixture.media, availableHeight: bodyHeight))
        case .calendar:
            return AnyView(CalendarWidgetView(calendarManager: fixture.calendar, recenterTrigger: .constant(0),
                onStartFocus: { _ in }, onShowAll: {}, availableHeight: bodyHeight))
        case .notes:
            return AnyView(NotesWidgetView(notesManager: fixture.notes, onShowAll: {}, availableHeight: bodyHeight))
        case .tray:
            return AnyView(TrayWidgetView(trayManager: fixture.tray, onShowAll: {}, availableHeight: bodyHeight))
        }
    }

    private func makeCurrentEvents(_ manager: CalendarManager) {
        let store = EKEventStore()
        manager.upcomingEvents = (0..<3).map { index in
            let event = EKEvent(eventStore: store)
            event.title = "当前安排 \(index + 1) · Current event with a long title"
            event.startDate = Date().addingTimeInterval(TimeInterval(index * 1200 - 30))
            event.endDate = Date().addingTimeInterval(TimeInterval((index + 1) * 1200))
            return event
        }
    }

    private func requireRendering() throws {
        #if !DEBUG
        throw XCTSkip("几何探针只在 Debug 构建中启用")
        #endif
        guard ProcessInfo.processInfo.environment["XNOOK_RENDER_UI"] == "1" else {
            throw XCTSkip("使用 XNOOK_RENDER_UI=1 执行隔离原生布局验证")
        }
        _ = NSApplication.shared
    }

    private func withHost(width: CGFloat, height: CGFloat, scheme: ColorScheme = .dark,
                          content: @escaping (CGFloat) -> AnyView,
                          verify: (NSHostingView<GridWidgetPreviewSurface>, GridWidgetPreviewModel, GridWidgetPreviewRecord) throws -> Void) throws {
        let model = GridWidgetPreviewModel(width: width, height: height)
        let record = GridWidgetPreviewRecord()
        let host = NSHostingView(rootView: GridWidgetPreviewSurface(model: model, record: record, scheme: scheme, content: content))
        host.frame = CGRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        settle(host)
        XCTAssertFalse(window.isVisible)
        try verify(host, model, record)
    }

    private func resize(_ host: NSView, model: GridWidgetPreviewModel, width: CGFloat) {
        model.width = width
        host.window?.setContentSize(CGSize(width: width, height: model.height))
        settle(host)
    }

    private func settle(_ host: NSView) {
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func assertContentFits(_ record: GridWidgetPreviewRecord, width: CGFloat, height: CGFloat,
                                   file: StaticString = #filePath, line: UInt = #line) throws {
        let content = try XCTUnwrap(record.frames["gridWidgetContent"], file: file, line: line)
        XCTAssertLessThanOrEqual(content.height, height - 24 + 0.5, file: file, line: line)
        for (name, frame) in record.frames {
            XCTAssertGreaterThanOrEqual(frame.minX, 11.5, "\(name) left", file: file, line: line)
            XCTAssertLessThanOrEqual(frame.maxX, width - 11.5, "\(name) right", file: file, line: line)
            XCTAssertGreaterThanOrEqual(frame.minY, 11.5, "\(name) top", file: file, line: line)
            XCTAssertLessThanOrEqual(frame.maxY, height - 11.5, "\(name) bottom", file: file, line: line)
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func withLanguage(_ language: String, action: () throws -> Void) rethrows {
        let original = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        var arguments = original
        arguments["appLanguage"] = language
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
        try action()
    }

    private func writeEvidence(_ host: NSView, record: GridWidgetPreviewRecord, name: String) throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/grid-widget-evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent(name + ".png"))
        let geometry = record.frames.mapValues { ["x": $0.minX, "y": $0.minY, "width": $0.width, "height": $0.height] }
        try JSONSerialization.data(withJSONObject: geometry, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent(name + ".json"))
    }
}

private enum GridWidgetPreviewKind: String, CaseIterable { case media, calendar, notes, tray }

@MainActor @Observable
private final class GridWidgetPreviewModel {
    var width: CGFloat
    var height: CGFloat
    init(width: CGFloat, height: CGFloat) { self.width = width; self.height = height }
}

@MainActor
private final class GridWidgetPreviewRecord {
    var frames: [String: CGRect] = [:]
}

@MainActor
private struct GridWidgetPreviewSurface: View {
    let model: GridWidgetPreviewModel
    let record: GridWidgetPreviewRecord
    let scheme: ColorScheme
    let content: (CGFloat) -> AnyView

    var body: some View {
        content(model.height - 24)
            .frame(width: model.width - 24)
            .fixedSize(horizontal: false, vertical: true)
            .expandedPanelDebugFrame(id: "gridWidgetContent")
            .frame(width: model.width - 24, height: model.height - 24, alignment: .top)
            .padding(12)
            .background(scheme == .dark ? Color(nsColor: .windowBackgroundColor) : Color.white)
            .coordinateSpace(name: "expandedPanelDebugGeometry")
            .environment(\.reportsExpandedPanelDebugGeometry, true)
            .environment(\.colorScheme, scheme)
            .onPreferenceChange(ExpandedPanelDebugGeometryKey.self) { record.frames = $0 }
    }
}
