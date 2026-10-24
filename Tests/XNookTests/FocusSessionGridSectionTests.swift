import AppKit
import SwiftUI
import XCTest
@testable import XNook

@MainActor
final class FocusSessionGridSectionTests: XCTestCase {
    func testIndependentSectionsDoNotIncludeEachOthersContent() {
        XCTAssertTrue(FocusSessionView.Section.currentTask.includesCurrentTask)
        XCTAssertFalse(FocusSessionView.Section.currentTask.includesHistory(showHistory: true, hasHistory: true))
        XCTAssertFalse(FocusSessionView.Section.recentTasks.includesCurrentTask)
        XCTAssertTrue(FocusSessionView.Section.recentTasks.includesHistory(showHistory: false, hasHistory: false),
                      "独立最近任务模块保留空态；旧 combined 的 showHistory 开关不隐藏已选模块")
        XCTAssertTrue(FocusSessionView.Section.combined.includesCurrentTask)
        XCTAssertTrue(FocusSessionView.Section.combined.includesHistory(showHistory: true, hasHistory: true))
        XCTAssertFalse(FocusSessionView.Section.combined.includesHistory(showHistory: false, hasHistory: true))
        XCTAssertFalse(FocusSessionView.Section.combined.includesHistory(showHistory: true, hasHistory: false))
    }

    func testHistoryBudgetReservesRoomForViewAllAtMinimumCardHeight() {
        XCTAssertEqual(FocusSessionView.visibleHistoryCount(recordCount: 20, displayLimit: 5, availableHeight: 116), 1)
        XCTAssertEqual(FocusSessionView.visibleHistoryCount(recordCount: 20, displayLimit: 5, availableHeight: 180), 3)
        XCTAssertEqual(FocusSessionView.visibleHistoryCount(recordCount: 20, displayLimit: 5, availableHeight: 240), 5)
        XCTAssertEqual(FocusSessionView.visibleHistoryCount(recordCount: 20, displayLimit: 2, availableHeight: 500), 2)
        XCTAssertEqual(FocusSessionView.visibleHistoryCount(recordCount: 1, displayLimit: 5, availableHeight: 500), 1)
        XCTAssertEqual(FocusSessionView.visibleHistoryCount(recordCount: 0, displayLimit: 5, availableHeight: 116), 0)
    }

    func testInvalidOrMissingHeightBudgetIsSafeAndDoesNotInventRecords() {
        let heights: [CGFloat?] = [nil, .nan, .infinity, -.infinity, .greatestFiniteMagnitude]
        for height in heights {
            XCTAssertEqual(FocusSessionView.visibleHistoryCount(recordCount: 4, displayLimit: 99, availableHeight: height), 4)
        }
        XCTAssertEqual(FocusSessionView.visibleHistoryCount(recordCount: 4, displayLimit: 5, availableHeight: -100), 1)
        XCTAssertEqual(FocusSessionView.visibleHistoryCount(recordCount: -1, displayLimit: 5, availableHeight: 116), 0)
    }

    func testDefaultInitializerAndIndependentSectionsShareTheSuppliedManager() throws {
        let suiteName = "XNook.FocusGrid.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manager = FocusSessionManager(userDefaults: defaults)
        let legacy = FocusSessionView(manager: manager, historyDisplayLimit: 3, trayFileCount: 0,
            onCreateLinkedNote: { false }, onLinkTrayFiles: {}, onEndSession: {})
        let current = makeView(manager: manager, section: .currentTask, height: 116)
        let recent = makeView(manager: manager, section: .recentTasks, height: 116)
        XCTAssertEqual(legacy.section, .combined)
        XCTAssertNil(legacy.availableHeight)
        XCTAssertTrue(current.manager === manager)
        XCTAssertTrue(recent.manager === manager)
        let session = try XCTUnwrap(manager.start(title: "共享任务上下文"))
        XCTAssertEqual(current.manager.activeSession?.id, session.id)
        XCTAssertTrue(manager.end())
        XCTAssertNil(current.manager.activeSession)
        XCTAssertEqual(recent.manager.history.first?.id, session.id)
    }

    /// 可选原生渲染验收：直接读真实布局，验证最小卡片没有挤出操作按钮。
    func testRenderIndependentSectionsAndVerticalCombinedLayout() throws {
        guard ProcessInfo.processInfo.environment["XNOOK_RENDER_UI"] == "1" else {
            throw XCTSkip("Set XNOOK_RENDER_UI=1 to render isolated focus grid sections.")
        }
        _ = NSApplication.shared
        let suiteName = "XNook.FocusGridRender.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let originalArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            UserDefaults.standard.setVolatileDomain(originalArguments, forName: UserDefaults.argumentDomain)
        }
        let manager = FocusSessionManager(userDefaults: defaults)
        let minimumSize = CGSize(width: 260, height: 136)
        try render(manager: manager, section: .recentTasks, size: minimumSize, scheme: .dark,
                   name: "recent-empty", expectedRows: 0)
        for index in 0..<5 {
            _ = manager.start(title: "历史任务 \(index) · " + String(repeating: "完整长标题 ", count: 30))
            XCTAssertTrue(manager.end())
        }
        try render(manager: manager, section: .currentTask, size: minimumSize, scheme: .light,
                   name: "current-entry", expectedRows: 0)
        let session = try XCTUnwrap(manager.start(title: String(repeating: "正在执行的长标题 · A long active task title ", count: 20)))
        manager.linkNote(id: UUID(), title: String(repeating: "关联笔记 ", count: 20))
        for index in 0..<10 {
            manager.linkFile(id: UUID(), name: "任务资料 \(index).pdf", icon: "doc.richtext")
        }
        guard case .added = manager.addTaskURL(urlString: "https://example.com/focus", title: "任务网页", to: session.id) else {
            return XCTFail("隔离链接创建失败")
        }
        let preservedStore = defaults.data(forKey: "nookflow.sessions")
        for language in ["zh", "en"] {
            var arguments = originalArguments
            arguments["appLanguage"] = language
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            for scheme in [ColorScheme.light, .dark] {
                let suffix = "\(language)-\(scheme == .dark ? "dark" : "light")"
                try render(manager: manager, section: .currentTask, size: minimumSize, scheme: scheme,
                           name: "current-active-\(suffix)", expectedRows: 0)
                try render(manager: manager, section: .recentTasks, size: minimumSize, scheme: scheme,
                           name: "recent-minimum-\(suffix)", expectedRows: 1)
                try render(manager: manager, section: .recentTasks, size: CGSize(width: 360, height: 200), scheme: scheme,
                           name: "recent-expanded-\(suffix)", expectedRows: 3)
            }
        }
        try render(manager: manager, section: .combined, size: CGSize(width: 800, height: 600), scheme: .light,
                   name: "combined-vertical", expectedRows: 5, bounded: false)
        XCTAssertEqual(defaults.data(forKey: "nookflow.sessions"), preservedStore,
                       "视图拆分、调整尺寸和渲染不能重启计时或改写业务快照")
    }

    private func makeView(manager: FocusSessionManager, section: FocusSessionView.Section, height: CGFloat?) -> FocusSessionView {
        FocusSessionView(manager: manager, historyDisplayLimit: 5, trayFileCount: 2,
            onCreateLinkedNote: { XCTFail("渲染不得创建笔记"); return false },
            onLinkTrayFiles: { XCTFail("渲染不得关联文件") },
            onEndSession: { XCTFail("渲染不得结束任务") },
            onOpenNote: { _ in XCTFail("渲染不得打开笔记"); return false },
            onOpenFile: { _ in XCTFail("渲染不得打开文件"); return false },
            section: section, availableHeight: height)
    }

    private func render(manager: FocusSessionManager, section: FocusSessionView.Section, size: CGSize,
                        scheme: ColorScheme, name: String, expectedRows: Int, bounded: Bool = true) throws {
        let record = FocusGridFrameRecord()
        let content = makeView(manager: manager, section: section, height: bounded ? size.height - 20 : nil)
            .padding(10)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(IslandStyle.surface(for: scheme))
            .coordinateSpace(name: "expandedPanelDebugGeometry")
            .environment(\.colorScheme, scheme)
            .environment(\.reportsExpandedPanelDebugGeometry, true)
            .onPreferenceChange(ExpandedPanelDebugGeometryKey.self) { record.frames = $0 }
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10000, y: -10000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(record.frames["focusSessionCurrentTask"] != nil, section.includesCurrentTask)
        XCTAssertEqual(record.frames["focusSessionRecentTasks"] != nil, section != .currentTask)
        XCTAssertEqual(record.frames.keys.filter { $0.hasPrefix("expandedPanelHistoryRow-") }.count, expectedRows)
        for (id, frame) in record.frames {
            XCTAssertGreaterThan(frame.width, 0, id)
            XCTAssertGreaterThan(frame.height, 0, id)
            XCTAssertGreaterThanOrEqual(frame.minX, -0.5, id)
            XCTAssertGreaterThanOrEqual(frame.minY, -0.5, id)
            XCTAssertLessThanOrEqual(frame.maxX, size.width + 0.5, id)
            XCTAssertLessThanOrEqual(frame.maxY, size.height + 0.5, id)
            if id.hasPrefix("expandedPanelHistoryRow-") {
                if bounded {
                    XCTAssertLessThanOrEqual(frame.height, 32, "网格长标题须遵守历史行预算")
                } else {
                    XCTAssertGreaterThan(frame.height, 28, "无预算的 combined 模式保留完整长标题")
                }
            }
        }
        if section == .currentTask, manager.activeSession != nil {
            for id in ["focusSessionTaskDetails", "focusSessionTaskActions", "focusSessionEndTask"] {
                XCTAssertNotNil(record.frames[id], id)
            }
        }
        if section == .combined {
            let current = try XCTUnwrap(record.frames["focusSessionCurrentTask"])
            let recent = try XCTUnwrap(record.frames["focusSessionRecentTasks"])
            XCTAssertLessThan(current.maxY, recent.minY, "combined 在宽面板中也必须上下排列")
        }
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1000)
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/grid-editor-evidence/ui/focus", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try png.write(to: output.appendingPathComponent(name + ".png"), options: .atomic)
    }
}

private final class FocusGridFrameRecord {
    var frames: [String: CGRect] = [:]
}
