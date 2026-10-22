import XCTest
import AppKit
import SwiftUI
import EventKit
@testable import XNook

/// 手动视觉验收入口；普通测试不创建窗口，也不读取真实业务数据。
/// XNOOK_RENDER_UI=1 swift test --filter WorkflowPreviewTests
@MainActor
final class WorkflowPreviewTests: XCTestCase {
    func testRenderIsolatedWorkflowPanels() throws {
        guard ProcessInfo.processInfo.environment["XNOOK_RENDER_UI"] == "1" else {
            throw XCTSkip("Set XNOOK_RENDER_UI=1 to render isolated workflow previews.")
        }
        _ = NSApplication.shared
        let fixture = try WorkflowPreviewFixture()
        defer { fixture.cleanUp() }
        let outputDirectory = URL(fileURLWithPath: "/tmp/xnook-workflow-ui", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        try render(fixture, selected: nil, size: NSSize(width: 800, height: 400), scheme: .dark,
                   output: outputDirectory.appendingPathComponent("overview-800-dark.png"))
        try render(fixture, selected: nil, size: NSSize(width: 800, height: 400), scheme: .light,
                   output: outputDirectory.appendingPathComponent("overview-800-light.png"))
        try render(fixture, selected: nil, size: NSSize(width: 160, height: 400), scheme: .dark,
                   output: outputDirectory.appendingPathComponent("overview-160-dark.png"))
        try render(fixture, selected: .notes, size: NSSize(width: 320, height: 400), scheme: .light,
                   output: outputDirectory.appendingPathComponent("notes-list-320-light.png"))
        XCTAssertTrue(fixture.notes.selectNote(id: fixture.sampleNotes[0].id))
        try render(fixture, selected: .notes, size: NSSize(width: 320, height: 400), scheme: .dark,
                   output: outputDirectory.appendingPathComponent("notes-editor-320-dark.png"))
        XCTAssertTrue(fixture.notes.closeEditor())
        try render(fixture, selected: .calendar, size: NSSize(width: 320, height: 400), scheme: .light,
                   output: outputDirectory.appendingPathComponent("calendar-320-light.png"))
        try render(fixture, selected: nil, size: NSSize(width: 320, height: 400), scheme: .light,
                   enabledWidgets: [], output: outputDirectory.appendingPathComponent("history-320-light.png"))
    }

    private func render(
        _ fixture: WorkflowPreviewFixture,
        selected: NotchContentView.WidgetType?,
        size: NSSize,
        scheme: ColorScheme,
        enabledWidgets: [NotchContentView.WidgetType] = [.media, .calendar, .notes, .tray],
        output: URL
    ) throws {
        var measuredHeights: [CGFloat] = []
        let panel = ExpandedPanelView(
            selectedWidget: .constant(selected),
            calendarRecenterTrigger: .constant(0),
            enabledWidgets: enabledWidgets,
            panelWidth: size.width,
            mediaManager: fixture.media,
            calendarManager: fixture.calendar,
            notesManager: fixture.notes,
            trayManager: fixture.tray,
            focusSessionManager: fixture.focus,
            showHistory: true,
            historyDisplayLimit: 3,
            onCreateLinkedNote: { false },
            onLinkTrayFiles: {},
            onEndSession: {},
            onOpenNote: { _ in false },
            onOpenFile: { _ in false },
            onStartFocus: { _ in },
            onInteractionChanged: { _ in },
            onLinksPresentationChanged: { _ in },
            onSettings: {},
            onClose: {},
            onMeasuredHeight: { measuredHeights.append($0) }
        )
        .frame(width: size.width, height: size.height)
        .background(IslandStyle.surface(for: scheme))
        .environment(\.colorScheme, scheme)
        .defaultAppStorage(fixture.defaults)

        let hosting = NSHostingView(rootView: panel)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        defer {
            window.contentView = nil
            window.close()
        }
        // 不 orderFront、不激活应用；短暂处理布局和 SwiftUI 的 onAppear 即可离屏绘制。
        for _ in 0..<3 {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(hosting.bounds.size, size)
        XCTAssertFalse(measuredHeights.isEmpty)
        XCTAssertTrue(measuredHeights.allSatisfy { $0.isFinite && $0 > 0 })

        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1000, "Preview must contain rendered content: \(output.lastPathComponent)")
        let decoded = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertEqual(decoded.pixelsWide, bitmap.pixelsWide)
        XCTAssertEqual(decoded.pixelsHigh, bitmap.pixelsHigh)
        XCTAssertGreaterThanOrEqual(decoded.pixelsWide, Int(size.width))
        XCTAssertGreaterThanOrEqual(decoded.pixelsHigh, Int(size.height))
        XCTAssertEqual(Double(decoded.pixelsWide) / Double(decoded.pixelsHigh), Double(size.width / size.height), accuracy: 0.01)

        var sampledColors: Set<String> = []
        for y in stride(from: 0, to: decoded.pixelsHigh, by: 8) {
            for x in stride(from: 0, to: decoded.pixelsWide, by: 8) {
                if let color = decoded.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                    sampledColors.insert("\(Int(color.redComponent * 255)),\(Int(color.greenComponent * 255)),\(Int(color.blueComponent * 255))")
                }
            }
        }
        XCTAssertGreaterThan(sampledColors.count, 8, "Preview cannot be a uniform placeholder: \(output.lastPathComponent)")
        try png.write(to: output, options: .atomic)
        print("Workflow preview: \(output.path) (\(decoded.pixelsWide) × \(decoded.pixelsHigh))")
    }
}

@MainActor
private final class WorkflowPreviewFixture {
    let directory: URL
    let suiteName: String
    let defaults: UserDefaults
    let media: MediaManager
    let notes: NotesManager
    let tray: TrayManager
    let focus: FocusSessionManager
    let calendar: CalendarManager
    let sampleNotes: [NotesManager.Note]

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("XNookWorkflowPreview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "XNook.WorkflowPreview.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set(true, forKey: "reduceMotion")
        media = MediaManager(startMonitoring: false)
        media.currentTitle = "Quiet Working Session"
        media.currentArtist = "Local Preview"

        sampleNotes = (0..<8).map { index in
            NotesManager.Note(
                title: index == 0 ? "项目验收：记录、日程与任务资料完整流程的详细笔记" : "工作笔记 \(index + 1)",
                content: "# 项目记录 \(index + 1)\n\n保留重要信息，快速找到下一步。\n\n" + String(repeating: "- 检查列表、资料入口和窄面板显示。\n", count: 12),
                isMarkdown: index % 2 == 0
            )
        }
        let notesURL = directory.appendingPathComponent("notes.json")
        try JSONEncoder().encode(sampleNotes).write(to: notesURL, options: .atomic)
        notes = NotesManager(storageURL: notesURL)
        tray = TrayManager(storageURL: directory.appendingPathComponent("tray.json"), resolveBookmark: { _ in nil }, makeBookmark: { _ in Data() })
        tray.files = [
            TrayManager.TrayFile(id: UUID(), bookmarkData: Data(), name: "项目验收记录.md", icon: "doc.text", size: 2048, addedAt: Date()),
            TrayManager.TrayFile(id: UUID(), bookmarkData: Data(), name: "界面说明.pdf", icon: "doc.richtext", size: 4096, addedAt: Date())
        ]

        focus = FocusSessionManager(userDefaults: defaults)
        for index in 0..<4 {
            _ = focus.start(title: "已完成任务 \(index + 1)：复核工作流和资料")
            focus.linkNote(id: sampleNotes[index].id, title: sampleNotes[index].title)
            focus.linkFile(id: UUID(), name: "相关设计文档.pdf", icon: "doc.richtext")
            focus.end()
        }

        let eventStore = EKEventStore()
        let eventCalendar = EKCalendar(for: .event, eventStore: eventStore)
        eventCalendar.title = "预览日历"
        eventCalendar.cgColor = NSColor.systemTeal.cgColor
        let now = Date()
        let dayStart = Calendar.current.startOfDay(for: now)
        let events = (0..<6).map { index in
            let event = EKEvent(eventStore: eventStore)
            event.calendar = eventCalendar
            event.title = index == 0 ? "产品与工程协作评审：一个需要换行的完整日程标题" : "项目日程 \(index + 1)"
            event.startDate = dayStart.addingTimeInterval(TimeInterval(8 + index * 2) * 3600)
            event.endDate = event.startDate.addingTimeInterval(3600)
            return event
        }
        calendar = CalendarManager(
            eventStore: eventStore,
            defaults: defaults,
            notificationCenter: NotificationCenter(),
            now: { now },
            observeChanges: false,
            readAuthorization: { .fullAccess },
            fetchCalendars: { [eventCalendar] },
            fetchEvents: { _, _ in events },
            requestFullAccess: { XCTFail("Preview must never request calendar access"); return false },
            didRefreshAuthorization: {}
        )
        calendar.refresh()
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            XCTFail("Failed to remove isolated preview data: \(error)")
        }
    }
}
