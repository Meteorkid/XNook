import XCTest
import AppKit
@testable import XNook

final class AlbumArtworkPaletteTests: XCTestCase {

    // MARK: - 颜色调整

    /// 提饱和 + 抬最低亮度后，颜色不能比原始更暗。
    func testAdjustedColorMeetsMinimumBrightness() {
        let dark = PaletteRGB(red: 0.05, green: 0.06, blue: 0.08)
        let adjusted = dark.adjusted(saturationBoost: 0.3, minimumBrightness: 0.55)
        let brightness = max(adjusted.red, adjusted.green, adjusted.blue)
        XCTAssertGreaterThanOrEqual(brightness, 0.55)
    }

    /// 纯黑输入不能让色相换算除零。
    func testPureBlackDoesNotProduceNaN() {
        let black = PaletteRGB(red: 0, green: 0, blue: 0)
        let adjusted = black.adjusted(saturationBoost: 0.3, minimumBrightness: 0.55)
        XCTAssertTrue(adjusted.red.isFinite)
        XCTAssertTrue(adjusted.green.isFinite)
        XCTAssertTrue(adjusted.blue.isFinite)
    }

    /// 灰色（无饱和度）不能因 delta 为 0 而产生 NaN。
    func testGrayColorDoesNotProduceNaN() {
        let gray = PaletteRGB(red: 0.5, green: 0.5, blue: 0.5)
        let adjusted = gray.adjusted(saturationBoost: 0.3, minimumBrightness: 0.55)
        XCTAssertTrue(adjusted.red.isFinite)
        XCTAssertTrue(adjusted.green.isFinite)
        XCTAssertTrue(adjusted.blue.isFinite)
    }

    func testDistanceIsZeroForIdenticalColors() {
        let color = PaletteRGB(red: 0.2, green: 0.4, blue: 0.6)
        XCTAssertEqual(color.distance(to: color), 0, accuracy: 0.0001)
    }

    func testDistanceGrowsWithDifference() {
        let a = PaletteRGB(red: 0, green: 0, blue: 0)
        let near = PaletteRGB(red: 0.02, green: 0, blue: 0)
        let far = PaletteRGB(red: 1, green: 1, blue: 1)
        XCTAssertLessThan(a.distance(to: near), a.distance(to: far))
    }

    /// 相近的两色经色相偏移后应被拉开距离。
    func testHueShiftSeparatesSimilarColors() {
        let base = PaletteRGB(red: 0.5, green: 0.5, blue: 0.5)
        let shifted = base.hueShifted(by: 0.12, minimumSaturation: 0.25, minimumBrightness: 0.5)
        XCTAssertGreaterThan(
            base.distance(to: shifted),
            AlbumArtworkColorExtractor.similarityThreshold
        )
    }

    // MARK: - 图像取色

    /// 左红右蓝的图应取到两个明显不同的颜色，而不是被平均成紫色。
    func testTwoToneImageYieldsDistinctColors() throws {
        let image = try XCTUnwrap(makeTwoToneImage())
        let palette = try XCTUnwrap(AlbumArtworkColorExtractor.palette(from: image))
        XCTAssertGreaterThan(
            palette.primary.distance(to: palette.secondary),
            AlbumArtworkColorExtractor.similarityThreshold,
            "左右边缘色差异明显时不应被判为相近"
        )
        // 主色应偏红（左侧），辅色应偏蓝（右侧）
        XCTAssertGreaterThan(palette.primary.red, palette.primary.blue)
        XCTAssertGreaterThan(palette.secondary.blue, palette.secondary.red)
    }

    /// 单色封面必须仍能产出两个可区分的颜色，否则渐变等于只有一色。
    func testSingleColorImageStillProducesDistinctPair() throws {
        let image = try XCTUnwrap(makeSolidImage(color: NSColor(srgbRed: 0.4, green: 0.4, blue: 0.4, alpha: 1)))
        let palette = try XCTUnwrap(AlbumArtworkColorExtractor.palette(from: image))
        XCTAssertGreaterThan(
            palette.primary.distance(to: palette.secondary),
            AlbumArtworkColorExtractor.similarityThreshold
        )
    }

    /// 极小图（取样条宽度会被 max(1, ...) 兜到 1）不能崩。
    func testTinyImageDoesNotCrash() {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        image.unlockFocus()
        // 只要求不崩溃；结果可以为 nil
        _ = AlbumArtworkColorExtractor.palette(from: image)
    }

    func testEmptyImageReturnsNil() {
        let empty = NSImage(size: .zero)
        XCTAssertNil(AlbumArtworkColorExtractor.palette(from: empty))
    }

    // MARK: - 辅助

    private func makeTwoToneImage(width: CGFloat = 200, height: CGFloat = 200) -> NSImage? {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width / 2, height: height).fill()
        NSColor(srgbRed: 0.1, green: 0.1, blue: 0.9, alpha: 1).setFill()
        NSRect(x: width / 2, y: 0, width: width / 2, height: height).fill()
        image.unlockFocus()
        return image
    }

    private func makeSolidImage(color: NSColor, size: CGFloat = 200) -> NSImage? {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        color.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        image.unlockFocus()
        return image
    }
}
