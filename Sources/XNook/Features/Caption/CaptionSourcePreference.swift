import Foundation

/// 字幕来源的优先级。
///
/// 调度器本身按证据等级排序（歌词 5 > 画面文字 3 > 语音 1），这在单一场景下是对的：
/// 唱词比识别准，内嵌字幕比识别准。但两种场景会打架——
/// 音乐播放器和视频同时出声时，用户想要的往往是其中一路，而不是「谁等级高听谁的」。
///
/// 所以这里给一个显式开关，决定哪些来源进入证据链。它不改变等级次序，
/// 只决定「这一路参不参与」。
enum CaptionSourcePreference: String, CaseIterable, Identifiable {
    /// 三路都参与，按证据等级排序。
    case automatic
    /// 只要歌词与语音：音乐场景，省掉每秒一次截图 + OCR。
    case music
    /// 只要画面文字与语音：视频场景，忽略正在播放的音乐歌词。
    case visual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic:
            L10n.localized(zh: "自动（按证据等级）", en: "Automatic (by evidence level)")
        case .music:
            L10n.localized(zh: "优先音乐歌词", en: "Prefer lyrics")
        case .visual:
            L10n.localized(zh: "优先视频画面", en: "Prefer on-screen text")
        }
    }

    var detail: String {
        switch self {
        case .automatic:
            L10n.localized(
                zh: "歌词 > 画面文字 > 语音，谁更可信用谁。",
                en: "Lyrics first, then on-screen text, then speech — whichever is more reliable."
            )
        case .music:
            L10n.localized(
                zh: "只用歌词与语音，不读画面。适合边听歌边干活。",
                en: "Lyrics and speech only; on-screen text is skipped. Best while listening to music."
            )
        case .visual:
            L10n.localized(
                zh: "只用画面文字与语音，忽略正在播放的音乐歌词。适合看视频。",
                en: "On-screen text and speech only; the playing track's lyrics are ignored. Best for video."
            )
        }
    }

    var includesLyrics: Bool { self != .visual }
    var includesFrameText: Bool { self != .music }

    static let defaultsKey = "captionSourcePreference"

    static var current: Self {
        get {
            UserDefaults.standard.string(forKey: defaultsKey)
                .flatMap(Self.init(rawValue:)) ?? .automatic
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
        }
    }
}
