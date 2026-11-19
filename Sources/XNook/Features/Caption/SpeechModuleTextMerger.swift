import Foundation

/// 双语模块的结果合并。
///
/// 同一个 `SpeechAnalyzer` 可以挂多个 `SpeechTranscriber`（各绑一种语言），两路会为同一段音频各出一份文本。
/// 实测规律（macOS 26.7，中英各一句合成语音）：
///
/// | 音频 | zh 模块 | en 模块 |
/// | --- | --- | --- |
/// | 中文 | 正常输出汉字 | 无输出 |
/// | 英文 | 输出拉丁字符串（能拼对常见词） | 更完整、带标点 |
///
/// 所以按「文本脚本是否匹配模块语言」排序，比按长度或到达顺序更稳：
/// 中文音频只有 zh 有货，英文音频两路都有货时选 en。
struct SpeechModuleTextMerger {

    struct Entry: Equatable {
        let locale: String
        let text: String
        let isFinal: Bool
    }

    /// 从同一区间的多份结果里选一份；全部为空时返回 nil。
    static func preferred(from entries: [Entry]) -> Entry? {
        let candidates = entries.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return candidates.max { rank($0) < rank($1) }
    }

    /// 排序依据：最终结果 > 中间结果；脚本匹配 > 脚本不匹配；同等条件下更长者更完整。
    static func rank(_ entry: Entry) -> (Int, Int, Int) {
        (entry.isFinal ? 1 : 0, scriptMatches(locale: entry.locale, text: entry.text) ? 1 : 0, entry.text.count)
    }

    /// 文本脚本是否与模块语言相符。
    ///
    /// 中文侧只要求「出现汉字」：中文句子里夹英文术语（`这个 feature 的 latency`）很常见，
    /// 按比例判定会把这类句子误判成英文。英文侧要求拉丁字母多于汉字，避免中文内容被英文模块抢走。
    static func scriptMatches(locale: String, text: String) -> Bool {
        var han = 0
        var latin = 0
        for scalar in text.unicodeScalars {
            if (0x4E00...0x9FFF).contains(scalar.value) {
                han += 1
            } else if CharacterSet.letters.contains(scalar) {
                latin += 1
            }
        }
        if locale.hasPrefix("zh") { return han > 0 }
        if locale.hasPrefix("en") { return latin > 0 && latin >= han }
        return false
    }
}
