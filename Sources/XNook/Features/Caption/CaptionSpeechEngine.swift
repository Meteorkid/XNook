import Foundation
import Speech

/// 语音识别引擎的选择。
///
/// - `stable`：`SFSpeechRecognizer`，macOS 14 起可用，单会话约一分钟换一次。
/// - `multilingual`：`SpeechAnalyzer` + 多语言模块（macOS 26 起），无会话上限，
///   且能中英两路并行、按脚本归属择优。
enum CaptionSpeechEngine: String, CaseIterable, Identifiable {
    case stable
    case multilingual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stable:
            L10n.localized(zh: "稳定（系统听写）", en: "Stable (system dictation)")
        case .multilingual:
            L10n.localized(zh: "多语言并行", en: "Multilingual")
        }
    }

    var detail: String {
        switch self {
        case .stable:
            L10n.localized(
                zh: "兼容 macOS 14 及以上。单个识别会话约一分钟，需要周期性换会话。",
                en: "Works on macOS 14 and later. Each recognition session lasts about a minute and is restarted periodically.")
        case .multilingual:
            L10n.localized(
                zh: "需要 macOS 26 及以上，并已下载对应语言模型。中英两路同时识别，按文本脚本择优；没有会话时长上限。",
                en: "Requires macOS 26 or later with the language models installed. Chinese and English run in parallel and the better script wins; no session length limit.")
        }
    }

    static let defaultsKey = "captionSpeechEngine"

    static var current: Self {
        get {
            if let stored = UserDefaults.standard.string(forKey: defaultsKey),
               let engine = Self.init(rawValue: stored) {
                return engine
            }
            // 默认给多语言并行。旧通路在这台机器上实测端到端延迟 13–30 秒，
            // 而调度器的已读保护窗只有 2 秒——超过这个窗的结果会被整批丢弃，
            // 屏幕上于是永远看不到语音字幕。能力不足时仍回落到稳定引擎。
            return supportsMultilingual ? .multilingual : .stable
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
        }
    }

    /// 当前系统是否具备多语言引擎的运行条件。
    static var supportsMultilingual: Bool {
        if #available(macOS 26.0, *) {
            return SpeechTranscriber.isAvailable
        }
        return false
    }
}
