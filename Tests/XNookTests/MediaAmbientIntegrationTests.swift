import AppKit
import SwiftUI
import XCTest
@testable import XNook

/// XNOOK_RENDER_UI=1 swift test --filter MediaAmbientIntegrationTests
@MainActor
final class MediaAmbientIntegrationTests: XCTestCase {
    func testRealMediaWidgetPreservesLayoutAndShowsArtworkAmbientInEveryAppearance() async throws {
        #if !DEBUG
        throw XCTSkip("真实媒体视图几何探针只在 Debug 构建启用")
        #endif
        guard ProcessInfo.processInfo.environment["XNOOK_RENDER_UI"] == "1" else {
            throw XCTSkip("使用 XNOOK_RENDER_UI=1 执行隔离离屏集成渲染")
        }
        _ = NSApplication.shared
        let original = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        var arguments = original
        arguments["appLanguage"] = "en"
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
        let suite = "XNook.MediaAmbientIntegration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "showLyrics")
        defaults.set(true, forKey: "reduceMotion")
        let artwork = try makeArtwork()
        let timestamp = Date(timeIntervalSinceReferenceDate: 1000)
        let lyrics = LyricsManager(defaults: defaults, loadRequest: { _ in
            XCTFail("集成渲染不得发起歌词网络请求")
            throw URLError(.notConnectedToInternet)
        }, readCache: { _, _, _ in nil }, writeCache: { _, _, _, _, _, _ in })
        let media = MediaManager(startMonitoring: false, defaults: defaults, lyricsManager: lyrics,
            infoProvider: { [
                "title": "Quiet Working Session", "artist": "Local Preview Artist", "album": "Everyday Moments",
                "source": "Music", "duration": 240.0, "playerPosition": 75.0, "playbackRate": 1.0,
                "positionTimestamp": timestamp, "artworkData": artwork
            ] }, artworkProvider: { _ in
                XCTFail("已提供测试封面，不得请求真实播放器")
                return nil
            }, clock: { timestamp }, commandSender: { _ in XCTFail("离屏渲染不得发送播放命令") })
        defer {
            // SwiftUI 可能延后释放宿主；先清空曲目，避免恢复偏好时为测试歌曲启动歌词查询。
            media.currentTitle = ""
            media.currentArtist = ""
            media.currentAlbum = ""
            media.isPlaying = false
            lyrics.reset()
        }
        await media.refreshNowPlayingInfo()
        for _ in 0..<200 {
            if media.artworkPalette != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(media.artworkPalette, "真实后台封面取色必须在有界等待内完成")
        XCTAssertNotNil(media.currentArtwork)
        XCTAssertTrue(media.isPlaying)
        XCTAssertEqual(media.elapsedTime, 75)
        for isDetail in [false, true] {
            for scheme in [ColorScheme.light, .dark] {
                let off = try render(media: media, defaults: defaults, style: .off, isDetail: isDetail, scheme: scheme)
                for style in [MediaAmbientStyle.glow, .dynamicBlur] {
                    let result = try render(media: media, defaults: defaults, style: style, isDetail: isDetail, scheme: scheme)
                    try assertUnchangedLayout(result, baseline: off, isDetail: isDetail)
                    XCTAssertGreaterThan(try backgroundDifference(result, off), 0.003,
                        "\(style.rawValue) 的真实媒体背景必须与关闭档产生可见像素差异")
                }
            }
        }
    }

    private func render(media: MediaManager, defaults: UserDefaults, style: MediaAmbientStyle,
                        isDetail: Bool, scheme: ColorScheme) throws -> AmbientWidgetImage {
        defaults.set(style.rawValue, forKey: "mediaAmbientStyle")
        let record = AmbientWidgetGeometry()
        let width: CGFloat = isDetail ? 420 : 290
        let host = NSHostingView(rootView: MediaWidgetView(mediaManager: media, isDetail: isDetail, onShowAll: {})
            .frame(width: width).fixedSize(horizontal: false, vertical: true)
            .padding(ExpandedPanelLayout.cardPadding)
            .background(Color(white: scheme == .dark ? 17.0 / 255.0 : 0.92))
            .coordinateSpace(name: "expandedPanelDebugGeometry")
            .environment(\.colorScheme, scheme)
            .environment(\.mediaAmbientAnimationEnabled, false)
            .environment(\.reportsExpandedPanelDebugGeometry, true)
            .defaultAppStorage(defaults)
            .onPreferenceChange(ExpandedPanelDebugGeometryKey.self) { record.frames = $0 })
        let size = host.fittingSize
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10000, y: -10000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
        XCTAssertFalse(window.isVisible)
        XCTAssertNotNil(record.frames["mediaWidgetRoot"])
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".build/layout-profiles-20261026/ui", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "ambient-widget-\(isDetail ? "detail" : "overview")-\(style.rawValue)-\(scheme == .dark ? "dark" : "light")"
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
        let evidence: [String: Any] = [
            "view": "MediaWidgetView", "style": style.rawValue, "paletteAvailable": media.artworkPalette != nil,
            "windowVisible": window.isVisible, "isolatedDefaults": true, "monitoringEnabled": false,
            "width": size.width, "height": size.height,
            "frames": record.frames.mapValues { ["x": $0.minX, "y": $0.minY, "width": $0.width, "height": $0.height] }
        ]
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent(name + ".json"), options: .atomic)
        return AmbientWidgetImage(bitmap: bitmap, size: size, frames: record.frames)
    }

    private func assertUnchangedLayout(_ result: AmbientWidgetImage, baseline: AmbientWidgetImage,
                                       isDetail: Bool) throws {
        XCTAssertEqual(result.size, baseline.size, "氛围背景不应改变媒体卡片宽高")
        XCTAssertEqual(Set(result.frames.keys), Set(baseline.frames.keys))
        for (id, expected) in baseline.frames {
            let actual = try XCTUnwrap(result.frames[id])
            XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.5, id)
            XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.5, id)
            XCTAssertEqual(actual.width, expected.width, accuracy: 0.5, id)
            XCTAssertEqual(actual.height, expected.height, accuracy: 0.5, id)
        }
        let buttons = ["mediaWidgetPrevious", "mediaWidgetPlayPause", "mediaWidgetNext",
                       isDetail ? "mediaWidgetLyricsDetails" : "mediaWidgetShowDetails"]
        for id in buttons {
            let frame = try XCTUnwrap(result.frames[id])
            XCTAssertGreaterThanOrEqual(frame.width, 28, id)
            XCTAssertGreaterThanOrEqual(frame.height, id == "mediaWidgetShowDetails" ? 24 : 28, id)
        }
    }

    private func backgroundDifference(_ result: AmbientWidgetImage, _ baseline: AmbientWidgetImage) throws -> Double {
        let artwork = try XCTUnwrap(result.frames["mediaWidgetArtwork"])
        let track = try XCTUnwrap(result.frames["mediaWidgetTrackGroup"])
        let scale = CGFloat(result.bitmap.pixelsWide) / result.size.width
        // 封面与文字分组之间的留白不含内容，差异只能来自真实媒体背景。
        let xRange = Int((artwork.maxX + 3) * scale)..<Int((track.minX - 3) * scale)
        let yRange = Int((artwork.minY + 5) * scale)..<Int((artwork.maxY - 5) * scale)
        var difference = 0.0
        var count = 0
        for y in yRange {
            for x in xRange {
                let first = try XCTUnwrap(result.bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                let second = try XCTUnwrap(baseline.bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                difference += Double(abs(first.redComponent - second.redComponent)
                    + abs(first.greenComponent - second.greenComponent) + abs(first.blueComponent - second.blueComponent)) / 3
                count += 1
            }
        }
        XCTAssertGreaterThan(count, 0)
        return difference / Double(max(1, count))
    }

    private func makeArtwork() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 120, pixelsHigh: 80,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .calibratedRGB, bytesPerRow: 120 * 4, bitsPerPixel: 32))
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        for y in 0..<80 {
            for x in 0..<120 {
                let offset = y * bitmap.bytesPerRow + x * 4
                let rgb: [UInt8] = x < 60 ? [242, 71, 31] : [38, 166, 153]
                pixels[offset] = rgb[0]
                pixels[offset + 1] = rgb[1]
                pixels[offset + 2] = rgb[2]
                pixels[offset + 3] = 255
            }
        }
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}

private final class AmbientWidgetGeometry {
    var frames: [String: CGRect] = [:]
}

private struct AmbientWidgetImage {
    let bitmap: NSBitmapImageRep
    let size: CGSize
    let frames: [String: CGRect]
}
