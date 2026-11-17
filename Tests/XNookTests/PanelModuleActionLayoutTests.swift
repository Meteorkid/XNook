import AppKit
import SwiftUI
import XCTest
@testable import XNook

/// 只检查隔离数据的生产视图，不点击文件操作或启动外部应用。
/// XNOOK_RENDER_UI=1 swift test --filter PanelModuleActionLayoutTests
@MainActor
final class PanelModuleActionLayoutTests: XCTestCase {
    func testPopulatedModuleActionsRemainVisibleAtNarrowAndStandardWidths() throws {
        try verifyModules(isEmpty: false)
    }

    func testEmptyModulesRetainVisibleDateAndDropEntrances() throws {
        try verifyModules(isEmpty: true)
    }

    func testCalendarSelectionColorsAndWeekdayLocaleFollowLightAndDarkAppearances() throws {
        try requireRendering()
        let original = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
        for language in ["zh", "en"] {
            var arguments = original
            arguments["appLanguage"] = language
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            for scheme in [ColorScheme.light, .dark] {
                try render(module: .calendar, width: 224, isEmpty: false, language: language,
                    scheme: scheme, verifyAppearanceChange: true)
            }
        }
    }

    private func requireRendering() throws {
        #if !DEBUG
        throw XCTSkip("模块几何探针只在 Debug 构建启用")
        #endif
        guard ProcessInfo.processInfo.environment["XNOOK_RENDER_UI"] == "1" else {
            throw XCTSkip("使用 XNOOK_RENDER_UI=1 执行隔离离屏原生渲染")
        }
        _ = NSApplication.shared
    }

    private func verifyModules(isEmpty: Bool) throws {
        try requireRendering()
        let original = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
        for language in ["zh", "en"] {
            var arguments = original
            arguments["appLanguage"] = language
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            for width in [CGFloat(120), CGFloat(160), CGFloat(224), CGFloat(388)] {
                for module in PanelModuleKind.allCases {
                    try render(module: module, width: width, isEmpty: isEmpty, language: language)
                }
            }
        }
    }

    private func render(module: PanelModuleKind, width: CGFloat, isEmpty: Bool, language: String,
                        scheme: ColorScheme = .dark, verifyAppearanceChange: Bool = false) throws {
        let fixture = try WorkflowPreviewFixture(historyCount: 0, trayFileCount: isEmpty ? 0 : 6,
            mediaHasContent: false, calendarEventTitles: isEmpty ? [] : nil)
        defer { fixture.cleanUp() }
        let notes: NotesManager
        if isEmpty {
            // 不存在的文件会创建示例笔记；真实空态必须从合法的空数组读取。
            let emptyNotesURL = fixture.directory.appendingPathComponent("empty-notes.json")
            try JSONEncoder().encode([NotesManager.Note]()).write(to: emptyNotesURL, options: .atomic)
            notes = NotesManager(storageURL: emptyNotesURL)
        } else {
            notes = fixture.notes
        }
        XCTAssertEqual(notes.notes.isEmpty, isEmpty, "渲染前确认隔离便笺夹具的空态")
        let model = PanelModuleRenderModel(width: width, scheme: scheme)
        let record = PanelModuleGeometryRecord()
        let host = NSHostingView(rootView: PanelModulePreview(fixture: fixture, notes: notes,
            module: module, model: model, record: record))
        host.frame = NSRect(origin: .zero, size: model.size)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: model.size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        settle(host)
        let initialRoot = try XCTUnwrap(record.frames["panelModuleRoot"])
        XCTAssertTrue(initialRoot.height.isFinite && initialRoot.height > 0)
        model.height = ceil(initialRoot.height)
        window.setContentSize(model.size)
        settle(host)
        let root = try XCTUnwrap(record.frames["panelModuleRoot"])
        XCTAssertEqual(root.width, width, accuracy: 0.5)
        XCTAssertEqual(root.height, initialRoot.height, accuracy: 1)
        XCTAssertFalse(window.isVisible)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)

        var actionIDs: [String] = []
        switch module {
        case .tray:
            let rows = record.frames.filter { $0.key.hasPrefix("expandedPanelTrayFile-") }
            XCTAssertEqual(rows.count, isEmpty ? 0 : 2)
            if isEmpty {
                actionIDs = ["expandedPanelTrayDropZone"]
                XCTAssertNil(record.frames["expandedPanelTrayShowAll"])
            } else {
                actionIDs = ["expandedPanelTrayShowAll"]
                for file in fixture.tray.files.prefix(2) {
                    let row = try XCTUnwrap(rows["expandedPanelTrayFile-\(file.id.uuidString)"])
                    let removeID = "expandedPanelTrayRemove-\(file.id.uuidString)"
                    let openID = "expandedPanelTrayOpen-\(file.id.uuidString)"
                    let remove = try XCTUnwrap(record.frames[removeID])
                    let open = try XCTUnwrap(record.frames[openID])
                    assertContained(remove, in: row, identifier: removeID)
                    assertContained(open, in: row, identifier: openID)
                    XCTAssertLessThanOrEqual(remove.maxX, open.minX + 0.5)
                    XCTAssertGreaterThanOrEqual(remove.width, 24)
                    XCTAssertGreaterThanOrEqual(open.height, 28)
                    actionIDs += [removeID, openID]
                }
            }
        case .notes:
            XCTAssertEqual(record.frames.keys.filter { $0.hasPrefix("expandedPanelNote-") }.count, isEmpty ? 0 : 3)
            actionIDs = ["expandedPanelNotesShowAll"]
        case .calendar:
            actionIDs = ["expandedPanelCalendarDates"]
            try assertVisibleDateCells(in: host, root: root)
            try assertSelectedDateAppearance(in: host, date: fixture.calendar.displayedDate,
                language: language, scheme: scheme)
        }
        for identifier in actionIDs {
            let action = try XCTUnwrap(record.frames[identifier], "未捕获真实操作：\(identifier)")
            assertContained(action, in: root, identifier: identifier)
            assertVisiblePixels(bitmap, frame: action, hostSize: host.bounds.size, identifier: identifier)
        }
        try writeEvidence(bitmap: bitmap, frames: record.frames, size: host.bounds.size,
            name: "\(module.rawValue)-\(isEmpty ? "empty" : "populated")-\(Int(width))-\(language)-\(scheme == .dark ? "dark" : "light")")
        if verifyAppearanceChange {
            let nextScheme: ColorScheme = scheme == .dark ? .light : .dark
            model.scheme = nextScheme
            window.appearance = NSAppearance(named: nextScheme == .dark ? .darkAqua : .aqua)
            settle(host)
            try assertSelectedDateAppearance(in: host, date: fixture.calendar.displayedDate,
                language: language, scheme: nextScheme)
            try assertVisibleDateCells(in: host, root: try XCTUnwrap(record.frames["panelModuleRoot"]))
            let switchedBitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: switchedBitmap)
            try writeEvidence(bitmap: switchedBitmap, frames: record.frames, size: host.bounds.size,
                name: "calendar-switched-to-\(nextScheme == .dark ? "dark" : "light")-\(language)")
        }
    }

    private func assertSelectedDateAppearance(in host: NSView, date: Date, language: String, scheme: ColorScheme) throws {
        let scroll = try XCTUnwrap(descendants(of: host).compactMap { $0 as? NSScrollView }.first)
        let viewport = topLeftFrame(scroll.contentView, in: host)
        let document = try XCTUnwrap(scroll.documentView)
        let selected = try XCTUnwrap(descendants(of: document).compactMap { $0 as? NSButton }.min {
            abs(topLeftFrame($0, in: host).midX - viewport.midX) < abs(topLeftFrame($1, in: host).midX - viewport.midX)
        })
        let weekday = try XCTUnwrap(selected.subviews.compactMap { $0 as? NSTextField }.first)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language == "zh" ? "zh_CN" : "en_US")
        formatter.dateFormat = "E"
        XCTAssertEqual(weekday.stringValue, formatter.string(from: date), "星期应服从应用语言，而非系统当前语言")
        XCTAssertEqual(selected.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]),
            scheme == .dark ? .darkAqua : .aqua)

        var actualText: NSColor?
        var semanticText: NSColor?
        selected.effectiveAppearance.performAsCurrentDrawingAppearance {
            actualText = weekday.textColor?.usingColorSpace(.deviceRGB)
            semanticText = NSColor.labelColor.usingColorSpace(.deviceRGB)
        }
        let actual = try XCTUnwrap(actualText)
        let semantic = try XCTUnwrap(semanticText)
        XCTAssertEqual(actual.redComponent, semantic.redComponent, accuracy: 0.01)
        XCTAssertEqual(actual.greenComponent, semantic.greenComponent, accuracy: 0.01)
        XCTAssertEqual(actual.blueComponent, semantic.blueComponent, accuracy: 0.01)
        XCTAssertEqual(actual.alphaComponent, semantic.alphaComponent, accuracy: 0.01)

        let background = try XCTUnwrap(NSColor(white: scheme == .dark ? 17.0 / 255.0 : 0.92, alpha: 1)
            .usingColorSpace(.deviceRGB))
        let backgroundLuminance = luminance(background, over: background)
        let textLuminance = luminance(actual, over: background)
        XCTAssertGreaterThanOrEqual((max(textLuminance, backgroundLuminance) + 0.05)
            / (min(textLuminance, backgroundLuminance) + 0.05), 4.5,
            "选中星期在当前模块表面上应有清楚对比")

        let highlight = try XCTUnwrap(selected.layer?.sublayers?.first { $0.cornerRadius == 12 && $0.zPosition == -1 })
        let highlightColor = try XCTUnwrap(highlight.backgroundColor.flatMap { NSColor(cgColor: $0) }?.usingColorSpace(.deviceRGB))
        XCTAssertEqual(highlightColor.redComponent, semantic.redComponent, accuracy: 0.01)
        XCTAssertEqual(highlightColor.greenComponent, semantic.greenComponent, accuracy: 0.01)
        XCTAssertEqual(highlightColor.blueComponent, semantic.blueComponent, accuracy: 0.01)
        XCTAssertEqual(highlightColor.alphaComponent, 0.12, accuracy: 0.01,
            "切换外观后，选中圆底应重新解析语义色")
    }

    private func luminance(_ color: NSColor, over background: NSColor) -> CGFloat {
        let alpha = color.alphaComponent
        let components = [color.redComponent * alpha + background.redComponent * (1 - alpha),
                          color.greenComponent * alpha + background.greenComponent * (1 - alpha),
                          color.blueComponent * alpha + background.blueComponent * (1 - alpha)]
        let linear = components.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
    }

    private func assertVisibleDateCells(in host: NSView, root: CGRect) throws {
        let scroll = try XCTUnwrap(descendants(of: host).compactMap { $0 as? NSScrollView }.first)
        let viewport = topLeftFrame(scroll.contentView, in: host)
        assertContained(viewport, in: root, identifier: "calendar date viewport")
        let document = try XCTUnwrap(scroll.documentView)
        // 日期条有意横向滚动，只检查视口中完整可见的真实日期按钮。
        let cells = descendants(of: document).compactMap { $0 as? NSButton }.filter {
            viewport.insetBy(dx: -0.5, dy: -0.5).contains(topLeftFrame($0, in: host))
        }
        let minimumVisibleCells = viewport.width < 160 ? 2 : 3
        XCTAssertGreaterThanOrEqual(cells.count, minimumVisibleCells,
            "日期条应在实际视口内保留足够的完整可点日期")
        for cell in cells {
            let cellFrame = topLeftFrame(cell, in: host)
            assertContained(cellFrame, in: viewport, identifier: "calendar date button")
            let labels = cell.subviews.compactMap { $0 as? NSTextField }
            XCTAssertEqual(labels.count, 2, "日期按钮应实际呈现星期和日期")
            for label in labels {
                let labelFrame = topLeftFrame(label, in: host)
                let drawingBounds = label.cell?.drawingRect(forBounds: label.bounds) ?? label.bounds
                let convertedDrawingFrame = label.convert(drawingBounds, to: host)
                let drawingFrame = host.isFlipped ? convertedDrawingFrame
                    : CGRect(x: convertedDrawingFrame.minX, y: host.bounds.height - convertedDrawingFrame.maxY,
                        width: convertedDrawingFrame.width, height: convertedDrawingFrame.height)
                let diagnostic = "calendar date label text=\(label.stringValue.debugDescription) "
                    + "font=\(String(describing: label.font)) cell=\(NSStringFromRect(cellFrame)) "
                    + "label=\(NSStringFromRect(labelFrame)) intrinsic=\(label.intrinsicContentSize) "
                    + "alignmentInsets=\(label.alignmentRectInsets) drawing=\(NSStringFromRect(drawingFrame)) viewport=\(NSStringFromRect(viewport))"
                assertContained(labelFrame, in: cellFrame, identifier: diagnostic)
                if let font = label.font, let fieldCell = label.cell {
                    let textWidth = (label.stringValue as NSString).size(withAttributes: [.font: font]).width
                    XCTAssertLessThanOrEqual(textWidth, fieldCell.drawingRect(forBounds: label.bounds).width + 0.5,
                        "文字本身不能因修正标签外沿而截断：\(diagnostic)")
                }
            }
        }
    }

    private func assertContained(_ frame: CGRect, in parent: CGRect, identifier: String) {
        XCTAssertGreaterThan(frame.width, 0, identifier)
        XCTAssertGreaterThan(frame.height, 0, identifier)
        XCTAssertGreaterThanOrEqual(frame.minX, parent.minX - 0.5, identifier)
        XCTAssertLessThanOrEqual(frame.maxX, parent.maxX + 0.5, identifier)
        XCTAssertGreaterThanOrEqual(frame.minY, parent.minY - 0.5, identifier)
        XCTAssertLessThanOrEqual(frame.maxY, parent.maxY + 0.5, identifier)
    }

    private func assertVisiblePixels(_ bitmap: NSBitmapImageRep, frame: CGRect, hostSize: CGSize, identifier: String) {
        let scaleX = CGFloat(bitmap.pixelsWide) / hostSize.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / hostSize.height
        let xStart = max(0, Int(frame.minX * scaleX))
        let xEnd = min(bitmap.pixelsWide, Int(ceil(frame.maxX * scaleX)))
        let yStart = max(0, Int(frame.minY * scaleY))
        let yEnd = min(bitmap.pixelsHigh, Int(ceil(frame.maxY * scaleY)))
        guard xStart < xEnd, yStart < yEnd else {
            XCTFail("操作没有可绘制区域：\(identifier)")
            return
        }
        var visiblePixels = 0
        for y in yStart..<yEnd {
            for x in xStart..<xEnd {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if max(color.redComponent, max(color.greenComponent, color.blueComponent)) > 0.25 { visiblePixels += 1 }
            }
        }
        XCTAssertGreaterThan(visiblePixels, 3, "操作的文字或图标应实际可见：\(identifier)")
    }

    private func settle(_ host: NSView) {
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func topLeftFrame(_ view: NSView, in host: NSView) -> CGRect {
        let rectangle = view.convert(view.bounds, to: host)
        return host.isFlipped ? rectangle : CGRect(x: rectangle.minX, y: host.bounds.height - rectangle.maxY,
            width: rectangle.width, height: rectangle.height)
    }

    private func writeEvidence(bitmap: NSBitmapImageRep, frames: [String: CGRect], size: CGSize, name: String) throws {
        let directory = WorkflowPreviewEvidence.directory.appendingPathComponent("panel-modules", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
        let geometry: [String: Any] = [
            "width": size.width, "height": size.height, "windowVisible": false,
            "acceptanceScope": "isolated-offscreen-production-view", "realWindowAcceptance": false,
            "frames": frames.mapValues { ["x": $0.minX, "y": $0.minY, "width": $0.width, "height": $0.height] }
        ]
        try JSONSerialization.data(withJSONObject: geometry, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent(name + ".json"), options: .atomic)
    }
}

private enum PanelModuleKind: String, CaseIterable {
    case calendar, tray, notes
}

@MainActor
private final class PanelModuleRenderModel: ObservableObject {
    let width: CGFloat
    @Published var height: CGFloat = 400
    @Published var scheme: ColorScheme
    var size: CGSize { CGSize(width: width, height: height) }
    init(width: CGFloat, scheme: ColorScheme) {
        self.width = width
        self.scheme = scheme
    }
}

private final class PanelModuleGeometryRecord {
    var frames: [String: CGRect] = [:]
}

@MainActor
private struct PanelModulePreview: View {
    let fixture: WorkflowPreviewFixture
    let notes: NotesManager
    let module: PanelModuleKind
    @ObservedObject var model: PanelModuleRenderModel
    let record: PanelModuleGeometryRecord

    var body: some View {
        moduleView
            .frame(width: model.width)
            .fixedSize(horizontal: false, vertical: true)
            .expandedPanelDebugFrame(id: "panelModuleRoot")
            .frame(width: model.width, height: model.height, alignment: .top)
            .background(Color(white: model.scheme == .dark ? 17.0 / 255.0 : 0.92))
            .coordinateSpace(name: "expandedPanelDebugGeometry")
            .environment(\.colorScheme, model.scheme)
            .defaultAppStorage(fixture.defaults)
            .environment(\.reportsExpandedPanelDebugGeometry, true)
            .onPreferenceChange(ExpandedPanelDebugGeometryKey.self) { record.frames = $0 }
    }

    @ViewBuilder
    private var moduleView: some View {
        switch module {
        case .calendar:
            CalendarWidgetView(calendarManager: fixture.calendar, recenterTrigger: .constant(0), onStartFocus: { _ in }, onShowAll: {})
        case .tray:
            TrayWidgetView(trayManager: fixture.tray, onShowAll: {})
        case .notes:
            NotesWidgetView(notesManager: notes, onShowAll: {})
        }
    }
}
