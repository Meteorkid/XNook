import AppKit
import SwiftUI
import XCTest
@testable import XNook

final class MediaAmbientBackgroundTests: XCTestCase {
    func testStoredStyleResolvesWithGlowFallback() {
        for style in MediaAmbientStyle.allCases {
            XCTAssertEqual(MediaAmbientStyle.resolved(style.rawValue), style)
        }
        XCTAssertEqual(MediaAmbientStyle.resolved(""), .glow)
        XCTAssertEqual(MediaAmbientStyle.resolved("future-style"), .glow)
    }

    func testMotionRequiresEveryPlaybackAndVisibilityCondition() {
        var activeCombinations = 0
        for style in MediaAmbientStyle.allCases {
            for hasPalette in [false, true] {
                for isPlaying in [false, true] {
                    for isVisible in [false, true] {
                        for reduceMotion in [false, true] {
                            let active = MediaAmbientMotion.shouldAnimate(style: style, hasPalette: hasPalette,
                                isPlaying: isPlaying, isVisible: isVisible, reduceMotion: reduceMotion)
                            if active { activeCombinations += 1 }
                            if style != .dynamicBlur || !hasPalette || !isPlaying || !isVisible || reduceMotion {
                                XCTAssertFalse(active, "静态、暂停、隐藏、无封面或减少动态时均不应调度")
                            }
                        }
                    }
                }
            }
        }
        XCTAssertEqual(activeCombinations, 1)
    }

    func testPauseFreezesPositionAndResumeContinuesWithoutCountingHiddenTime() {
        let start = Date(timeIntervalSinceReferenceDate: 100)
        var motion = MediaAmbientMotion()
        motion.setRunning(true, at: start)
        motion.setRunning(false, at: start.addingTimeInterval(7))
        XCTAssertEqual(motion.elapsedTime(at: start.addingTimeInterval(200)), 7, accuracy: 0.0001)
        let pausedPosition = MediaAmbientMotion.displacement(at: motion.elapsedTime(at: start))
        motion.setRunning(true, at: start.addingTimeInterval(200))
        XCTAssertEqual(MediaAmbientMotion.displacement(at: motion.elapsedTime(at: start.addingTimeInterval(200))),
                       pausedPosition)
        XCTAssertEqual(motion.elapsedTime(at: start.addingTimeInterval(202)), 9, accuracy: 0.0001)
    }

    func testRepeatedVisibilityUpdatesDoNotRestartAnActiveCycle() {
        let start = Date(timeIntervalSinceReferenceDate: 100)
        var motion = MediaAmbientMotion()
        motion.setRunning(true, at: start)
        motion.setRunning(true, at: start.addingTimeInterval(3))
        XCTAssertEqual(motion.elapsedTime(at: start.addingTimeInterval(5)), 5, accuracy: 0.0001)
        motion.setRunning(false, at: start.addingTimeInterval(5))
        motion.setRunning(false, at: start.addingTimeInterval(8))
        XCTAssertEqual(motion.elapsedTime(at: start.addingTimeInterval(10)), 5, accuracy: 0.0001)
    }

    func testMotionIsSlowBoundedAndSeamlessAcrossCycles() {
        XCTAssertGreaterThanOrEqual(MediaAmbientMotion.cycleDuration, 20)
        XCTAssertGreaterThanOrEqual(MediaAmbientMotion.frameInterval, 1.0 / 15.0)
        for time in stride(from: 0.0, through: 20.0, by: 0.1) {
            let position = MediaAmbientMotion.displacement(at: time)
            let nextCycle = MediaAmbientMotion.displacement(at: time + MediaAmbientMotion.cycleDuration)
            XCTAssertLessThanOrEqual(abs(position.width), 0.1001)
            XCTAssertLessThanOrEqual(abs(position.height), 0.1201)
            XCTAssertEqual(position.width, nextCycle.width, accuracy: 0.0001)
            XCTAssertEqual(position.height, nextCycle.height, accuracy: 0.0001)
        }
        let before = MediaAmbientMotion.displacement(at: 19.99)
        let after = MediaAmbientMotion.displacement(at: 20.01)
        XCTAssertLessThan(abs(before.width - after.width), 0.001)
        XCTAssertLessThan(abs(before.height - after.height), 0.001)
    }

    func testInvalidAnimationTimeHasFiniteFallback() {
        for time in [TimeInterval.nan, .infinity, -.infinity] {
            XCTAssertEqual(MediaAmbientMotion.displacement(at: time), .zero)
        }
    }
}

/// XNOOK_RENDER_UI=1 swift test --filter MediaAmbientBackgroundRenderingTests
/// 独立离屏画布用于比较氛围强度；真实卡片布局另由 MediaWidgetLayoutTests 验证。
@MainActor
final class MediaAmbientBackgroundRenderingTests: XCTestCase {
    private let palette = AlbumArtworkPalette(
        primary: PaletteRGB(red: 0.95, green: 0.32, blue: 0.13),
        secondary: PaletteRGB(red: 0.18, green: 0.64, blue: 0.62))

    func testOffAndMissingPaletteLeaveBaseUnchanged() throws {
        try requireRendering()
        for scheme in [ColorScheme.light, .dark] {
            let off = try render(style: .off, palette: palette, scheme: scheme)
            for style in [MediaAmbientStyle.glow, .dynamicBlur] {
                let missing = try render(style: style, palette: nil, scheme: scheme)
                XCTAssertEqual(try pixels(of: off), try pixels(of: missing))
            }
        }
    }

    func testLightAppearanceUsesLowerIntensityAndWritesStyleEvidence() throws {
        try requireRendering()
        let darkBase = try render(style: .off, palette: palette, scheme: .dark)
        let lightBase = try render(style: .off, palette: palette, scheme: .light)
        for style in [MediaAmbientStyle.glow, .dynamicBlur] {
            let dark = try render(style: style, palette: palette, scheme: .dark)
            let light = try render(style: style, palette: palette, scheme: .light)
            let darkChange = try meanDifference(dark, darkBase)
            let lightChange = try meanDifference(light, lightBase)
            XCTAssertGreaterThan(darkChange, 0.005, "封面色应在深色背景实际可见")
            XCTAssertGreaterThan(lightChange, 0.001, "浅色背景仍保留柔和封面色")
            XCTAssertLessThan(lightChange, darkChange, "浅色氛围强度应更低")
            XCTAssertLessThan(darkChange, 0.15, "氛围不应盖过卡片内容")
        }
    }

    func testBackgroundDoesNotChangeContentFittingSize() throws {
        try requireRendering()
        let baseline = NSHostingView(rootView: measuredContent)
        let expected = baseline.fittingSize
        for style in MediaAmbientStyle.allCases {
            let host = NSHostingView(rootView: measuredContent.background {
                MediaAmbientBackground(style: style, palette: palette, isPlaying: false,
                    isVisible: true, reduceMotion: false)
            })
            XCTAssertEqual(host.fittingSize.width, expected.width, accuracy: 0.5)
            XCTAssertEqual(host.fittingSize.height, expected.height, accuracy: 0.5)
        }
    }

    private var measuredContent: some View {
        HStack(spacing: 12) {
            Rectangle().frame(width: 100, height: 100)
            Text("Quiet Working Session").font(.system(size: 13))
        }
        .padding(12)
    }

    private func requireRendering() throws {
        guard ProcessInfo.processInfo.environment["XNOOK_RENDER_UI"] == "1" else {
            throw XCTSkip("使用 XNOOK_RENDER_UI=1 执行隔离离屏渲染")
        }
        _ = NSApplication.shared
    }

    private func render(style: MediaAmbientStyle, palette: AlbumArtworkPalette?, scheme: ColorScheme) throws -> NSBitmapImageRep {
        let size = CGSize(width: 320, height: 160)
        let host = NSHostingView(rootView: Color(white: scheme == .dark ? 0.067 : 0.92)
            .overlay {
                MediaAmbientBackground(style: style, palette: palette, isPlaying: false,
                    isVisible: true, reduceMotion: false)
            }
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, scheme))
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
        XCTAssertEqual(host.bounds.size, size)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".build/layout-profiles-20261026/ui", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = "ambient-\(style.rawValue)-\(scheme == .dark ? "dark" : "light")\(palette == nil ? "-no-palette" : "").png"
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent(filename), options: .atomic)
        return bitmap
    }

    private func pixels(of bitmap: NSBitmapImageRep) throws -> [Double] {
        var channels: [Double] = []
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
                let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                channels.append(contentsOf: [Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent)])
            }
        }
        return channels
    }

    private func meanDifference(_ first: NSBitmapImageRep, _ second: NSBitmapImageRep) throws -> Double {
        let lhs = try pixels(of: first)
        let rhs = try pixels(of: second)
        XCTAssertEqual(lhs.count, rhs.count)
        return zip(lhs, rhs).reduce(0) { $0 + abs($1.0 - $1.1) } / Double(lhs.count)
    }
}
