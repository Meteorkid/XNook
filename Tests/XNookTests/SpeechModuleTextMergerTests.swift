import XCTest
@testable import XNook

/// 双语模块结果的择优规则。
///
/// 实测依据（macOS 26.7）：中文音频只有 zh 模块有输出；英文音频两路都出拉丁字符串，
/// 但 en 模块更完整。所以「脚本是否匹配模块语言」比「谁先到」更可靠。
final class SpeechModuleTextMergerTests: XCTestCase {

    private typealias Entry = SpeechModuleTextMerger.Entry

    func testChineseTextPrefersChineseModule() {
        let chosen = SpeechModuleTextMerger.preferred(from: [
            Entry(locale: "en-US", text: "我们要聊一聊", isFinal: true),
            Entry(locale: "zh-CN", text: "我们要聊一聊", isFinal: true)
        ])
        XCTAssertEqual(chosen?.locale, "zh-CN")
    }

    func testLatinTextPrefersEnglishModule() {
        let chosen = SpeechModuleTextMerger.preferred(from: [
            Entry(locale: "zh-CN", text: "This feature is still", isFinal: true),
            Entry(locale: "en-US", text: "This feature is still too slow.", isFinal: true)
        ])
        XCTAssertEqual(chosen?.locale, "en-US")
    }

    func testFinalResultBeatsVolatileEvenAcrossLanguages() {
        let chosen = SpeechModuleTextMerger.preferred(from: [
            Entry(locale: "en-US", text: "This feature", isFinal: false),
            Entry(locale: "zh-CN", text: "这个功能", isFinal: true)
        ])
        XCTAssertEqual(chosen?.isFinal, true)
    }

    func testChineseModuleToleratesEnglishTerms() {
        XCTAssertTrue(SpeechModuleTextMerger.scriptMatches(locale: "zh-CN", text: "这个 feature 的 latency 太高"))
        XCTAssertFalse(SpeechModuleTextMerger.scriptMatches(locale: "zh-CN", text: "this feature is still too slow"))
    }

    func testEmptyEntriesAreIgnored() {
        XCTAssertNil(SpeechModuleTextMerger.preferred(from: [
            Entry(locale: "zh-CN", text: "   ", isFinal: true)
        ]))
        XCTAssertNil(SpeechModuleTextMerger.preferred(from: []))
    }
}
