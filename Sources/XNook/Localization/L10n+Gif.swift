import Foundation

extension L10n {
    static var gifInvalidData: String { localized(zh: "无法读取有效的 GIF 图像。", en: "The file is not a readable GIF image.") }
    static var gifEncodedSizeLimit: String { localized(zh: "GIF 文件不能超过 10 MiB。", en: "GIF files must not exceed 10 MiB.") }
    static var gifDimensionLimit: String { localized(zh: "GIF 宽高均不能超过 2048 像素。", en: "GIF width and height must not exceed 2048 pixels.") }
    static var gifFrameCountLimit: String { localized(zh: "GIF 不能超过 500 帧。", en: "GIF files must not exceed 500 frames.") }
    static var gifTotalPixelsLimit: String { localized(zh: "GIF 累计解码像素不能超过 64 Mi 像素，请缩小尺寸或减少帧数。", en: "GIF decoded pixels must not exceed 64 Mi pixels. Reduce its dimensions or frame count.") }
    static var gifUnavailable: String { localized(zh: "GIF 不可用", en: "GIF unavailable") }
    static func gifLoadFailed(_ name: String, reason: String) -> String { localized(
        zh: "“\(name)”无法使用：\(reason) 原选择未更改。",
        en: "“\(name)” could not be used: \(reason) The previous selection is unchanged.") }
}
