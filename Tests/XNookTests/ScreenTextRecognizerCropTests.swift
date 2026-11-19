import XCTest
import CoreGraphics
@testable import XNook

/// 字幕带的裁剪范围。这个方向搞反过一次：`CGImage.cropping(to:)` 的原点在左上角，
/// 写成 `y: 0` 拿到的是顶部菜单栏，于是 OCR 一直把「帮助」「11月17日 周二」当成字幕输出。
final class ScreenTextRecognizerCropTests: XCTestCase {

    func testBottomBandTakesTheLowerPartOfTheImage() {
        // 顶部 30% 红、其余蓝：底部带应当全是蓝的。
        let width = 40
        let height = 100
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        // CGContext 原点在左下：先铺满蓝色，再把上半部分（视觉上的顶部）涂红。
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: CGFloat(height) * 0.3, width: CGFloat(width), height: CGFloat(height) * 0.7))

        let image = context.makeImage()!
        let band = ScreenTextRecognizer.cropBottomBand(image)

        XCTAssertNotNil(band)
        XCTAssertEqual(band?.height, Int((CGFloat(height) * ScreenTextRecognizer.bottomBandRatio).rounded()))
        XCTAssertEqual(band?.width, width)

        let average = self.averageColor(of: band!, colorSpace: colorSpace)
        XCTAssertGreaterThan(average.blue, 0.8, "底部带应当是蓝色区域")
        XCTAssertLessThan(average.red, 0.2, "取到红色说明裁的是顶部菜单栏")
    }

    /// 把整块图缩到 1×1 取均值：带内是纯色，缩放方向不影响结论。
    private func averageColor(of image: CGImage, colorSpace: CGColorSpace) -> (red: Double, green: Double, blue: Double) {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (Double(pixel[0]) / 255, Double(pixel[1]) / 255, Double(pixel[2]) / 255)
    }
}
