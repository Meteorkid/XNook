import AppKit
import SwiftUI
import XCTest
@testable import XNook

/// 只渲染真实媒体视图；播放器监控和所有偏好均由隔离夹具关闭或替代。
/// XNOOK_RENDER_UI=1 swift test --filter MediaWidgetLayoutTests
@MainActor
final class MediaWidgetLayoutTests: XCTestCase {
    func testEmptyStateLaunchesMusicWithoutMonitoringOrExistingSource() {
        let manager = MediaManager(startMonitoring: false)
        var openedPlayers: [ScriptingBridgeHelper.SupportedApp] = []
        manager.openCurrentPlayer { openedPlayers.append($0) }
        XCTAssertNil(manager.currentSource)
        XCTAssertEqual(openedPlayers, [.music], "空态入口应实际请求打开 Music，不应提前返回")
    }

    func testOpenPlayerKeepsExistingSpotifySource() async {
        let manager = MediaManager(startMonitoring: false,
            infoProvider: { ["source": "Spotify"] }, artworkProvider: { _ in nil })
        await manager.refreshNowPlayingInfo()
        var openedPlayers: [ScriptingBridgeHelper.SupportedApp] = []
        manager.openCurrentPlayer { openedPlayers.append($0) }
        XCTAssertEqual(openedPlayers, [.spotify])
    }

    func testOverviewGroupsControlsWithInfoBesideHundredPointArtwork() throws {
        try requireRendering()
        try forEachAppearance { language, scheme in
            for width in [CGFloat(290), CGFloat(360)] {
                try render(width: width, language: language, scheme: scheme, name: "overview-standard") { fixture in
                    fixture.media.currentTitle = language == "zh" ? "安静的工作时光" : "Quiet Working Session"
                    fixture.media.currentAlbum = language == "zh" ? "日常片段" : "Everyday Moments"
                    fixture.media.currentArtist = language == "zh" ? "本地测试艺术家" : "Local Preview Artist"
                } verify: { result in
                    try assertLayout(result)
                    XCTAssertEqual(try frame("mediaWidgetArtwork", in: result).width, 100, accuracy: 0.5)
                    XCTAssertNotNil(result.frames["mediaWidgetAlbum"], "只展示播放器已有的真实专辑字段")
                    XCTAssertNil(result.frames["mediaWidgetLyricsDetails"], "歌词校正入口只放在详情，不增加概览高度")
                }
            }
        }
    }

    func testNarrowOverviewKeepsLongTitlesAndAllControlsVisible() throws {
        try requireRendering()
        try forEachAppearance { language, scheme in
            for width in [CGFloat(112), CGFloat(120), CGFloat(160), CGFloat(203)] {
                try render(width: width, language: language, scheme: scheme, name: "overview-long-title") { fixture in
                    setLongTrack(on: fixture.media, language: language)
                } verify: { result in
                    try assertLayout(result)
                    XCTAssertNil(result.fixture.media.currentArtwork)
                }
            }
        }
    }

    func testOverviewAndDetailPreserveRealArtworkAspectRatio() throws {
        try requireRendering()
        let artworkData = try makeArtworkData()
        try forEachAppearance { language, scheme in
            for isDetail in [false, true] {
                try render(width: isDetail ? 420 : 290, isDetail: isDetail, language: language,
                    scheme: scheme, name: "artwork") { fixture in
                    setLongTrack(on: fixture.media, language: language)
                    fixture.media.currentArtworkData = artworkData
                    fixture.media.isPlaying = true
                    XCTAssertNotNil(fixture.media.currentArtwork)
                } verify: { result in
                    try assertLayout(result)
                    let artwork = try frame("mediaWidgetArtwork", in: result)
                    let visibleArtwork = try XCTUnwrap(coloredArtworkBounds(in: result.bitmap, frame: artwork,
                        hostSize: result.host.bounds.size), "测试封面应实际出现在渲染结果中")
                    XCTAssertGreaterThanOrEqual(visibleArtwork.width, artwork.width - 2,
                        "识别到的测试封面应覆盖容器宽度，不能只匹配零散彩色像素")
                    XCTAssertEqual(visibleArtwork.width / visibleArtwork.height, 1.5, accuracy: 0.12,
                        "120×80封面应保留原始比例，不能拉伸成正方形")
                }
            }
        }
    }

    func testEmptyOverviewAndDetailOfferPlayerWithoutPlaceholderControls() throws {
        try requireRendering()
        try forEachAppearance { language, scheme in
            for isDetail in [false, true] {
                for width in [CGFloat(120), CGFloat(290), CGFloat(420)] {
                    try render(width: width, isDetail: isDetail, language: language,
                        scheme: scheme, name: "empty", configure: { _ in }) { result in
                        let root = try frame("mediaWidgetRoot", in: result)
                        let emptyState = try frame("mediaWidgetEmptyState", in: result)
                        let openPlayer = try frame("mediaWidgetOpenPlayer", in: result)
                        XCTAssertEqual(root.width, result.width, accuracy: 1)
                        XCTAssertEqual(root.height, isDetail ? 100 : 132, accuracy: 1)
                        XCTAssertEqual(emptyState.height, 100, accuracy: 1)
                        try assertHeader(result)
                        try assertContained(openPlayer, in: root, identifier: "open player")
                        XCTAssertEqual(emptyState.midX, root.midX, accuracy: 1)
                        XCTAssertGreaterThanOrEqual(openPlayer.height, 32)
                        for identifier in ["mediaWidgetArtwork", "mediaWidgetInfo", "mediaWidgetControls",
                                           "mediaWidgetPrevious", "mediaWidgetPlayPause", "mediaWidgetNext"] {
                            XCTAssertNil(result.frames[identifier], "空态不应出现无上下文控件：\(identifier)")
                        }
                    }
                }
            }
        }
    }

    func testDetailLongTitleProgressAndLyricsFitAtNarrowAndPreferredWidths() throws {
        try requireRendering()
        try forEachAppearance { language, scheme in
            for width in [CGFloat(120), CGFloat(420)] {
                try render(width: width, isDetail: true, language: language, scheme: scheme,
                    name: "detail-long-title") { fixture in
                    setLongTrack(on: fixture.media, language: language)
                    fixture.defaults.set(true, forKey: "showLyrics")
                    fixture.media.duration = 240
                    fixture.media.elapsedTime = 75
                    fixture.media.currentLyricLine = language == "zh"
                        ? "灯火映照归途，远方仍有回声"
                        : "The lights lead us home while distant echoes remain"
                } verify: { result in
                    try assertLayout(result)
                    let root = try frame("mediaWidgetRoot", in: result)
                    let progress = try frame("mediaWidgetProgress", in: result)
                    let lyrics = try frame("mediaWidgetLyrics", in: result)
                    let controls = try frame("mediaWidgetControls", in: result)
                    let lyricsDetails = try frame("mediaWidgetLyricsDetails", in: result)
                    let trackGroup = try frame("mediaWidgetTrackGroup", in: result)
                    try assertContained(progress, in: root, identifier: "progress")
                    try assertContained(lyrics, in: root, identifier: "lyrics")
                    try assertContained(lyricsDetails, in: trackGroup, identifier: "lyrics details")
                    XCTAssertGreaterThanOrEqual(lyricsDetails.height, 28)
                    XCTAssertLessThan(progress.maxY, lyrics.minY)
                    XCTAssertLessThan(lyrics.maxY, controls.minY)
                }
            }
        }
    }

    func testMissingAlbumAndDisabledLyricsDoNotAddEmptyMetadataRows() throws {
        try requireRendering()
        try forEachAppearance { language, scheme in
            try render(width: 420, isDetail: true, language: language, scheme: scheme,
                name: "detail-metadata-unavailable") { fixture in
                fixture.media.currentTitle = "Local Preview Track"
                fixture.defaults.set(false, forKey: "showLyrics")
            } verify: { result in
                try assertLayout(result)
                XCTAssertNil(result.frames["mediaWidgetAlbum"])
                XCTAssertNil(result.frames["mediaWidgetProgress"])
                XCTAssertNil(result.frames["mediaWidgetLyrics"])
                XCTAssertNotNil(result.frames["mediaWidgetLyricsDetails"], "关闭歌词时仍可从详情查看状态与偏移")
            }
        }
    }

    private func requireRendering() throws {
        #if !DEBUG
        throw XCTSkip("媒体几何探针只在 Debug 构建启用")
        #endif
        guard ProcessInfo.processInfo.environment["XNOOK_RENDER_UI"] == "1" else {
            throw XCTSkip("使用 XNOOK_RENDER_UI=1 执行隔离离屏原生渲染")
        }
        _ = NSApplication.shared
    }

    private func forEachAppearance(_ action: (String, ColorScheme) throws -> Void) throws {
        let original = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
        for language in ["zh", "en"] {
            var arguments = original
            arguments["appLanguage"] = language
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            for scheme in [ColorScheme.light, .dark] { try action(language, scheme) }
        }
    }

    private func setLongTrack(on media: MediaManager, language: String) {
        media.currentTitle = language == "zh"
            ? "在漫长的夜晚里继续记录每一个尚未完成的故事与远方的回声"
            : "A Very Long Song Title That Must Never Push Playback Controls Outside the Widget"
        media.currentAlbum = language == "zh"
            ? "沿着漫长的旅程记录每一个值得留念的片刻"
            : "Collected Recordings from a Very Long Journey"
        media.currentArtist = language == "zh"
            ? "来自遥远城市的独立音乐人与现场演奏乐团"
            : "An Independent Artist and the Complete Live Session Ensemble"
    }

    private func render(width: CGFloat, isDetail: Bool = false, language: String, scheme: ColorScheme,
                        name: String, configure: (WorkflowPreviewFixture) throws -> Void,
                        verify: (MediaWidgetRenderResult) throws -> Void) throws {
        let fixture = try WorkflowPreviewFixture(historyCount: 0, trayFileCount: 0,
            mediaHasContent: false, calendarEventTitles: [])
        defer { fixture.cleanUp() }
        try configure(fixture)
        let model = MediaWidgetRenderModel(width: width)
        let record = MediaWidgetGeometryRecord()
        let host = NSHostingView(rootView: MediaWidgetPreview(fixture: fixture, model: model,
            record: record, isDetail: isDetail, scheme: scheme))
        host.frame = NSRect(origin: .zero, size: model.size)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: model.size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        settle(host)
        let measuredRoot = try XCTUnwrap(record.frames["mediaWidgetRoot"], "未捕获真实媒体组件根视图")
        XCTAssertTrue(measuredRoot.height.isFinite && measuredRoot.height > 0)
        model.height = ceil(measuredRoot.height)
        window.setContentSize(model.size)
        settle(host)
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(host.bounds.size, model.size)
        XCTAssertEqual(try XCTUnwrap(record.frames["mediaWidgetRoot"]).height, measuredRoot.height, accuracy: 1,
            "调整离屏视口高度不应改变组件自然高度")
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let result = MediaWidgetRenderResult(fixture: fixture, host: host, window: window, bitmap: bitmap,
            frames: record.frames, width: width, isDetail: isDetail, scheme: scheme)
        let evidenceName = "\(name)-\(isDetail ? "detail" : "overview")-\(Int(width))-\(language)-\(scheme == .dark ? "dark" : "light")"
        try writeEvidence(result, name: evidenceName)
        try verify(result)
    }

    private func settle(_ host: NSView) {
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
    }

    private func assertLayout(_ result: MediaWidgetRenderResult) throws {
        let root = try frame("mediaWidgetRoot", in: result)
        let artwork = try frame("mediaWidgetArtwork", in: result)
        let info = try frame("mediaWidgetInfo", in: result)
        let group = try frame("mediaWidgetTrackGroup", in: result)
        let controls = try frame("mediaWidgetControls", in: result)
        let buttonIDs = ["mediaWidgetPrevious", "mediaWidgetPlayPause", "mediaWidgetNext"]
        let buttons = try buttonIDs.map { try frame($0, in: result) }
        XCTAssertEqual(root.width, result.width, accuracy: 1)
        XCTAssertEqual(artwork.width, 100, accuracy: 1, "正常和窄宽度均保留100pt封面")
        XCTAssertEqual(artwork.width, artwork.height, accuracy: 1)
        XCTAssertNil(result.frames["mediaWidgetEmptyState"])
        let content = try frame("mediaWidgetContent", in: result)
        try assertHeader(result)
        let summaryHeight = result.width >= 223 ? max(artwork.height, group.height) : artwork.height + 12 + group.height
        if result.isDetail {
            let lyricsDetails = try frame("mediaWidgetLyricsDetails", in: result)
            try assertContained(lyricsDetails, in: group, identifier: "lyrics details")
            XCTAssertEqual(lyricsDetails.height, 28, accuracy: 1)
            XCTAssertEqual(lyricsDetails.minY, info.maxY + 8, accuracy: 1,
                "歌词入口应计入曲目信息分组，避免额外撑出全宽详情行")
            XCTAssertEqual(group.maxY, lyricsDetails.maxY, accuracy: 1)
            var previousBottom = content.minY + summaryHeight
            for identifier in ["mediaWidgetProgress", "mediaWidgetLyrics", "mediaWidgetControls"] {
                guard let section = result.frames[identifier] else { continue }
                XCTAssertEqual(section.minY, previousBottom + 16, accuracy: 1,
                    "详情内容分组之间应保持16pt间距：\(identifier)")
                previousBottom = section.maxY
            }
            XCTAssertEqual(content.maxY, previousBottom, accuracy: 1)
            XCTAssertEqual(root.height, content.height, accuracy: 1)
        } else {
            XCTAssertEqual(content.height, summaryHeight, accuracy: 1)
            XCTAssertEqual(root.height, 24 + 8 + content.height, accuracy: 1)
        }
        if result.width >= 223 {
            XCTAssertEqual(artwork.maxX + 12, group.minX, accuracy: 1)
            XCTAssertEqual(artwork.midY, group.midY, accuracy: 1)
        } else {
            XCTAssertEqual(artwork.midX, root.midX, accuracy: 1)
            XCTAssertEqual(artwork.maxY + 12, group.minY, accuracy: 1)
        }
        if result.isDetail {
            XCTAssertEqual(controls.midX, root.midX, accuracy: 1)
            XCTAssertGreaterThan(controls.minY, max(artwork.maxY, info.maxY))
        } else {
            XCTAssertEqual(controls.minX, info.minX, accuracy: 1, "概览控制和曲目信息应在同一分组内左对齐")
            XCTAssertGreaterThan(controls.minY, info.maxY)
            try assertContained(controls, in: group, identifier: "overview controls")
            if result.width >= 223 {
                XCTAssertGreaterThan(controls.minX, artwork.maxX, "概览控制应在封面右侧，不能落回全宽下排")
                XCTAssertEqual(root.height, 132, accuracy: 1)
            }
        }
        for (identifier, rectangle) in [("artwork", artwork), ("info", info), ("group", group), ("controls", controls)]
            + Array(zip(buttonIDs, buttons)) {
            try assertContained(rectangle, in: root, identifier: identifier)
        }
        for (index, button) in buttons.enumerated() {
            XCTAssertGreaterThanOrEqual(button.width, 37, buttonIDs[index])
            XCTAssertGreaterThanOrEqual(button.height, 37, buttonIDs[index])
            XCTAssertEqual(button.midY, controls.midY, accuracy: 1)
            if index > 0 { XCTAssertLessThanOrEqual(buttons[index - 1].maxX, button.minX + 0.5) }
            try assertNeutralControlPixels(in: result, frame: button)
        }
    }

    private func assertHeader(_ result: MediaWidgetRenderResult) throws {
        if result.isDetail {
            XCTAssertNil(result.frames["mediaWidgetHeader"])
            XCTAssertNil(result.frames["mediaWidgetShowDetails"])
            return
        }
        let root = try frame("mediaWidgetRoot", in: result)
        let header = try frame("mediaWidgetHeader", in: result)
        let navigation = try frame("mediaWidgetShowDetails", in: result)
        let content = try frame("mediaWidgetContent", in: result)
        XCTAssertEqual(header.height, 24, accuracy: 0.5)
        XCTAssertEqual(header.minY, root.minY, accuracy: 0.5)
        XCTAssertEqual(header.maxY + 8, content.minY, accuracy: 0.5)
        XCTAssertEqual(navigation.width, 28, accuracy: 0.5)
        XCTAssertEqual(navigation.height, 24, accuracy: 0.5)
        try assertContained(header, in: root, identifier: "header")
        try assertContained(navigation, in: header, identifier: "show details")
    }

    private func assertContained(_ rectangle: CGRect, in root: CGRect, identifier: String) throws {
        XCTAssertGreaterThan(rectangle.width, 0, identifier)
        XCTAssertGreaterThan(rectangle.height, 0, identifier)
        XCTAssertGreaterThanOrEqual(rectangle.minX, root.minX - 0.5, identifier)
        XCTAssertLessThanOrEqual(rectangle.maxX, root.maxX + 0.5, identifier)
        XCTAssertGreaterThanOrEqual(rectangle.minY, root.minY - 0.5, identifier)
        XCTAssertLessThanOrEqual(rectangle.maxY, root.maxY + 0.5, identifier)
    }

    private func assertNeutralControlPixels(in result: MediaWidgetRenderResult, frame: CGRect) throws {
        let scaleX = CGFloat(result.bitmap.pixelsWide) / result.host.bounds.width
        let scaleY = CGFloat(result.bitmap.pixelsHigh) / result.host.bounds.height
        var visiblePixels = 0
        let background: CGFloat = result.scheme == .dark ? 17.0 / 255.0 : 0.92
        for y in max(0, Int(frame.minY * scaleY))..<min(result.bitmap.pixelsHigh, Int(ceil(frame.maxY * scaleY))) {
            for x in max(0, Int(frame.minX * scaleX))..<min(result.bitmap.pixelsWide, Int(ceil(frame.maxX * scaleX))) {
                guard let color = result.bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let channels = [color.redComponent, color.greenComponent, color.blueComponent]
                let maximum = try XCTUnwrap(channels.max())
                if abs(maximum - background) > 0.25 {
                    visiblePixels += 1
                    let minimum = try XCTUnwrap(channels.min())
                    XCTAssertLessThanOrEqual(maximum - minimum, 0.08,
                        "播放控制应保持统一中性色，不应恢复蓝色强调按钮")
                }
            }
        }
        XCTAssertGreaterThan(visiblePixels, 5, "播放图标应实际可见")
    }

    private func frame(_ identifier: String, in result: MediaWidgetRenderResult) throws -> CGRect {
        try XCTUnwrap(result.frames[identifier], "未捕获真实媒体元素：\(identifier)")
    }

    private func makeArtworkData() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 120, pixelsHigh: 80,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let color = NSColor(deviceRed: 0.1, green: 0.65, blue: 0.45, alpha: 1)
        for y in 0..<80 { for x in 0..<120 { bitmap.setColor(color, atX: x, y: y) } }
        let image = NSImage(size: NSSize(width: 120, height: 80))
        image.addRepresentation(bitmap)
        return try XCTUnwrap(image.tiffRepresentation)
    }

    private func coloredArtworkBounds(in bitmap: NSBitmapImageRep, frame: CGRect, hostSize: CGSize) -> CGRect? {
        let scaleX = CGFloat(bitmap.pixelsWide) / hostSize.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / hostSize.height
        var bounds: CGRect?
        for y in max(0, Int(frame.minY * scaleY))..<min(bitmap.pixelsHigh, Int(ceil(frame.maxY * scaleY))) {
            for x in max(0, Int(frame.minX * scaleX))..<min(bitmap.pixelsWide, Int(ceil(frame.maxX * scaleX))) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                    // 使用绿色通道顺序排除灰底与白色文字，只计入夹具封面。
                    color.greenComponent - color.redComponent > 0.08,
                    color.blueComponent - color.redComponent > 0.04,
                    color.greenComponent - color.blueComponent > 0.03 else { continue }
                let pixel = CGRect(x: CGFloat(x) / scaleX, y: CGFloat(y) / scaleY,
                    width: 1 / scaleX, height: 1 / scaleY)
                bounds = bounds.map { $0.union(pixel) } ?? pixel
            }
        }
        return bounds
    }

    private func writeEvidence(_ result: MediaWidgetRenderResult, name: String) throws {
        let directory = WorkflowPreviewEvidence.directory.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = try XCTUnwrap(result.bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 500)
        try png.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
        let geometry: [String: Any] = [
            "view": "MediaWidgetView", "width": result.width, "height": result.host.bounds.height,
            "mode": result.isDetail ? "detail" : "overview", "windowVisible": result.window.isVisible,
            "acceptanceScope": "isolated-offscreen-production-view", "realWindowAcceptance": false,
            "mediaMonitoringEnabled": false, "temporaryDefaults": true,
            "framesSource": "ExpandedPanelDebugGeometryKey",
            "frames": result.frames.mapValues { ["x": $0.minX, "y": $0.minY, "width": $0.width, "height": $0.height] }
        ]
        try JSONSerialization.data(withJSONObject: geometry, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent(name + ".json"), options: .atomic)
    }
}

@MainActor
private final class MediaWidgetRenderModel: ObservableObject {
    let width: CGFloat
    @Published var height: CGFloat = 240
    var size: CGSize { CGSize(width: width, height: height) }
    init(width: CGFloat) { self.width = width }
}

private final class MediaWidgetGeometryRecord {
    var frames: [String: CGRect] = [:]
}

@MainActor
private struct MediaWidgetRenderResult {
    let fixture: WorkflowPreviewFixture
    let host: NSView
    let window: NSWindow
    let bitmap: NSBitmapImageRep
    let frames: [String: CGRect]
    let width: CGFloat
    let isDetail: Bool
    let scheme: ColorScheme
}

@MainActor
private struct MediaWidgetPreview: View {
    let fixture: WorkflowPreviewFixture
    @ObservedObject var model: MediaWidgetRenderModel
    let record: MediaWidgetGeometryRecord
    let isDetail: Bool
    let scheme: ColorScheme

    var body: some View {
        MediaWidgetView(mediaManager: fixture.media, isDetail: isDetail, onShowAll: {})
            .frame(width: model.width)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: model.width, height: model.height, alignment: .top)
            .background(Color(white: scheme == .dark ? 17.0 / 255.0 : 0.92))
            .coordinateSpace(name: "expandedPanelDebugGeometry")
            .environment(\.colorScheme, scheme)
            .defaultAppStorage(fixture.defaults)
            .environment(\.reportsExpandedPanelDebugGeometry, true)
            .onPreferenceChange(ExpandedPanelDebugGeometryKey.self) { record.frames = $0 }
    }
}
