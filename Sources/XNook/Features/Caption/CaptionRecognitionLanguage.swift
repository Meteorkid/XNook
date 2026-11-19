import Foundation

/// 实时字幕的语音识别语言。
///
/// 「自动」不是简单地跟随系统语言：演唱内容常常与系统语言不一致（中文系统放英文歌很常见）。
/// 判定顺序是「当前内容线索 → 系统语言」，内容线索取歌词或刚出的字幕行。
enum CaptionRecognitionLanguage: String, CaseIterable, Identifiable {
    case automatic = "auto"
    case chinese = "zh-CN"
    case english = "en-US"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic:
            L10n.localized(zh: "自动（跟随内容）", en: "Automatic (follow content)")
        case .chinese:
            L10n.localized(zh: "中文", en: "Chinese")
        case .english:
            L10n.localized(zh: "英文", en: "English")
        }
    }

    static let defaultsKey = "captionLocale"

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

/// 把「语言偏好 + 内容线索」解析成 `SFSpeechRecognizer` 实际使用的 locale。
enum CaptionLanguageResolver {

    /// 判定为中文所需的汉字占比。偏低是有意的：中英混排的标题、带英文人名的中文歌词都很常见，
    /// 而中文识别器对夹杂的英文单词容忍度尚可，反过来则会把整句听成拼音碎片。
    static let chineseRatioThreshold = 0.25
    /// 少于这么多个字符不下结论，样本太短容易误判（例如歌曲前奏只有一个词）。
    static let minimumSampleLength = 4

    static func resolve(preference: CaptionRecognitionLanguage,
                        contentHint: String?,
                        systemLanguage: String) -> Locale {
        switch preference {
        case .chinese:
            return Locale(identifier: "zh-CN")
        case .english:
            return Locale(identifier: "en-US")
        case .automatic:
            if let hint = contentHint, let detected = detect(hint) { return detected }
            return Locale(identifier: normalizedSystemLanguage(systemLanguage))
        }
    }

    /// 有足够样本时给出判断，否则返回 nil（由调用方回退到系统语言）。
    static func detect(_ text: String) -> Locale? {
        var han = 0
        var latin = 0
        for scalar in text.unicodeScalars {
            if (0x4E00...0x9FFF).contains(scalar.value) {
                han += 1
            } else if CharacterSet.letters.contains(scalar) {
                latin += 1
            }
        }
        let total = han + latin
        guard total >= minimumSampleLength else { return nil }

        if Double(han) / Double(total) >= chineseRatioThreshold { return Locale(identifier: "zh-CN") }
        if han == 0 { return Locale(identifier: "en-US") }
        return nil
    }

    static func normalizedSystemLanguage(_ language: String) -> String {
        language.hasPrefix("zh") ? "zh-CN" : language
    }
}

/// 换识别语言的滞后判据。
///
/// 语种线索来自歌词与字幕行，本来就是会抖的：一首中文歌里出现英文歌名、
/// 一句中文台词里带英文术语，都会让「自动」在 zh-CN 与 en-US 之间来回跳。
/// 而换语言意味着重建识别会话——重建一次就丢一次正在进行的识别，
/// 抖动一次就重建一次的结果是「永远在重建，永远没有结果」。
///
/// 所以要求同一个目标语言连续两次探测都成立、且间隔足够，才真的换。
struct CaptionLanguageSwitchGuard {

    /// 两次探测之间至少隔这么久，避免 60 ms 的调度节拍把「连续两次」当成一次。
    let minimumProbeGap: TimeInterval
    /// 会话建立后至少跑这么久才允许换语言，否则新会话刚起来就被换掉。
    let minimumSessionAge: TimeInterval

    private var pendingIdentifier: String?
    private var pendingSince: TimeInterval = 0
    private var sessionStartedAt: TimeInterval = 0

    init(minimumProbeGap: TimeInterval = 3, minimumSessionAge: TimeInterval = 8) {
        self.minimumProbeGap = minimumProbeGap
        self.minimumSessionAge = minimumSessionAge
    }

    mutating func sessionStarted(at now: TimeInterval) {
        sessionStartedAt = now
        pendingIdentifier = nil
        pendingSince = 0
    }

    /// - Parameters:
    ///   - target: 本次解析出的语言。
    ///   - current: 当前会话正在用的语言。
    /// - Returns: 是否应当重建会话。
    mutating func shouldSwitch(to target: String, from current: String, now: TimeInterval) -> Bool {
        guard target != current else {
            pendingIdentifier = nil
            pendingSince = 0
            return false
        }
        guard now - sessionStartedAt >= minimumSessionAge else { return false }

        if pendingIdentifier == target, now - pendingSince >= minimumProbeGap {
            pendingIdentifier = nil
            pendingSince = 0
            return true
        }
        if pendingIdentifier != target {
            pendingIdentifier = target
            pendingSince = now
        }
        return false
    }
}
