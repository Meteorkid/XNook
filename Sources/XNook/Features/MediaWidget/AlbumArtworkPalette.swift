import AppKit
import CoreImage

/// 一组 RGB 颜色分量（sRGB，0...1）。
///
/// 刻意用纯值类型而不是 NSColor：取色在后台线程完成，结果要跨线程送回主线程，
/// NSColor 不是 Sendable，直接传递在严格并发下不合法。这里只传分量，
/// 需要绘制时再由主线程构造 NSColor。
struct PaletteRGB: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    func withAlpha(_ alpha: Double) -> NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    /// 与另一颜色的欧氏距离（用于判断两色是否过于接近）
    func distance(to other: PaletteRGB) -> Double {
        let dr = red - other.red
        let dg = green - other.green
        let db = blue - other.blue
        return (dr * dr + dg * dg + db * db).squareRoot()
    }

    /// 提饱和并抬最低亮度，保证在深色面板上可读。
    func adjusted(saturationBoost: Double, minimumBrightness: Double) -> PaletteRGB {
        let maxComponent = max(red, green, blue)
        let minComponent = min(red, green, blue)
        let brightness = maxComponent
        guard brightness > 0 else {
            return PaletteRGB(red: minimumBrightness, green: minimumBrightness, blue: minimumBrightness)
        }
        let delta = maxComponent - minComponent
        let saturation = delta == 0 ? 0 : delta / maxComponent
        let hue = Self.hue(red: red, green: green, blue: blue, maxComponent: maxComponent, delta: delta)

        let newSaturation = min(1, saturation + saturationBoost)
        let newBrightness = max(brightness, minimumBrightness)
        return Self.rgb(hue: hue, saturation: newSaturation, brightness: newBrightness)
    }

    /// 沿色相环偏移，用于把过于接近的两色区分开。
    func hueShifted(by offset: Double, minimumSaturation: Double, minimumBrightness: Double) -> PaletteRGB {
        let maxComponent = max(red, green, blue)
        let minComponent = min(red, green, blue)
        let brightness = max(maxComponent, minimumBrightness)
        let delta = maxComponent - minComponent
        let saturation = max(delta == 0 ? 0 : delta / max(maxComponent, 0.0001), minimumSaturation)
        let hue = Self.hue(red: red, green: green, blue: blue, maxComponent: maxComponent, delta: delta)
        return Self.rgb(hue: (hue + offset).truncatingRemainder(dividingBy: 1), saturation: saturation, brightness: brightness)
    }

    // MARK: - 色相换算

    private static func hue(red: Double, green: Double, blue: Double, maxComponent: Double, delta: Double) -> Double {
        guard delta > 0 else { return 0 }
        let hue: Double
        if maxComponent == red {
            hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
        } else if maxComponent == green {
            hue = (blue - red) / delta + 2
        } else {
            hue = (red - green) / delta + 4
        }
        let normalized = hue / 6
        return normalized < 0 ? normalized + 1 : normalized
    }

    private static func rgb(hue: Double, saturation: Double, brightness: Double) -> PaletteRGB {
        let c = brightness * saturation
        let x = c * (1 - abs((hue * 6).truncatingRemainder(dividingBy: 2) - 1))
        let m = brightness - c
        let segment = Int(hue * 6) % 6
        let (r, g, b): (Double, Double, Double)
        switch segment {
        case 0: (r, g, b) = (c, x, 0)
        case 1: (r, g, b) = (x, c, 0)
        case 2: (r, g, b) = (0, c, x)
        case 3: (r, g, b) = (0, x, c)
        case 4: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        return PaletteRGB(red: r + m, green: g + m, blue: b + m)
    }
}

/// 从专辑封面提取的强调色。
///
/// 思路：取封面**左右各 10% 的边缘条**做区域平均，而不是整图平均。
/// 整图平均很容易被大面积的背景色（多为黑白灰）拉向灰色；边缘条更接近
/// 封面的"主视觉色"，取出来更有辨识度。
struct AlbumArtworkPalette: Equatable, Sendable {
    /// 主色 — 用于标题、进度条等强调元素
    var primary: PaletteRGB
    /// 辅色 — 用于渐变另一端
    var secondary: PaletteRGB

    /// 面板背景用的低强度渐变
    var backgroundGradient: [NSColor] {
        [primary.withAlpha(0.16), secondary.withAlpha(0.10)]
    }
}

enum AlbumArtworkColorExtractor {
    /// 左右取样条的宽度占整图比例
    static let sampleStripFraction: CGFloat = 0.10
    /// 两色距离低于此值视为过于接近
    static let similarityThreshold: Double = 0.05
    /// 饱和度提升量
    static let saturationBoost: Double = 0.30
    /// 背景色的最低亮度
    static let backgroundMinimumBrightness: Double = 0.55
    /// 强调色的最低亮度
    static let accentMinimumBrightness: Double = 0.75
    /// 相近两色的色相偏移量
    static let hueOffset: Double = 0.12

    /// 复用同一个 CIContext：每次新建代价很高，且这个操作只在切歌时触发。
    private static let context = CIContext(options: [
        .workingColorSpace: NSNull(),
        .outputColorSpace: NSNull(),
    ])

    static func palette(from image: NSImage) -> AlbumArtworkPalette? {
        guard let ciImage = ciImage(from: image) else { return nil }
        let extent = ciImage.extent
        guard extent.width > 0, extent.height > 0 else { return nil }

        let stripWidth = max(1, extent.width * sampleStripFraction)
        let leftRect = CGRect(x: extent.minX, y: extent.minY, width: stripWidth, height: extent.height)
        let rightRect = CGRect(
            x: extent.maxX - stripWidth, y: extent.minY,
            width: stripWidth, height: extent.height
        )

        guard let left = averageColor(of: ciImage, in: leftRect),
              let right = averageColor(of: ciImage, in: rightRect) else { return nil }

        let distinct = left.distance(to: right) < similarityThreshold
            ? (left, right.hueShifted(by: hueOffset, minimumSaturation: 0.25, minimumBrightness: 0.5))
            : (left, right)

        return AlbumArtworkPalette(
            primary: distinct.0.adjusted(
                saturationBoost: saturationBoost,
                minimumBrightness: accentMinimumBrightness
            ),
            secondary: distinct.1.adjusted(
                saturationBoost: saturationBoost,
                minimumBrightness: backgroundMinimumBrightness
            )
        )
    }

    // MARK: - 内部

    private static func ciImage(from image: NSImage) -> CIImage? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let cgImage = bitmap.cgImage else { return nil }
        return CIImage(cgImage: cgImage)
    }

    /// CIAreaAverage 把指定区域压成 1×1，再读回那一个像素。
    private static func averageColor(of image: CIImage, in rect: CGRect) -> PaletteRGB? {
        guard rect.width >= 1, rect.height >= 1,
              let filter = CIFilter(name: "CIAreaAverage") else { return nil }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: rect), forKey: kCIInputExtentKey)
        guard let output = filter.outputImage else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(
            output,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return PaletteRGB(
            red: Double(pixel[0]) / 255,
            green: Double(pixel[1]) / 255,
            blue: Double(pixel[2]) / 255
        )
    }
}
