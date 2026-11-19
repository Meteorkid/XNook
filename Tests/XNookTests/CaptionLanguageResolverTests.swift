import XCTest
@testable import XNook

/// 识别语言的解析规则：显式选择优先，其次内容线索，最后系统语言。
final class CaptionLanguageResolverTests: XCTestCase {

    func testExplicitPreferenceWinsOverContent() {
        XCTAssertEqual(
            CaptionLanguageResolver.resolve(
                preference: .chinese,
                contentHint: "Paint my nails cherry red",
                systemLanguage: "en-US"
            ).identifier,
            "zh-CN"
        )
        XCTAssertEqual(
            CaptionLanguageResolver.resolve(
                preference: .english,
                contentHint: "我們之間沒有延伸的關系",
                systemLanguage: "zh-Hans-CN"
            ).identifier,
            "en-US"
        )
    }

    func testAutomaticFollowsContentInBothDirections() {
        // 中文系统放英文歌
        XCTAssertEqual(
            CaptionLanguageResolver.resolve(
                preference: .automatic,
                contentHint: "Paint my nails cherry red",
                systemLanguage: "zh-Hans-CN"
            ).identifier,
            "en-US"
        )
        // 英文系统放中文歌
        XCTAssertEqual(
            CaptionLanguageResolver.resolve(
                preference: .automatic,
                contentHint: "我們之間沒有延伸的關系",
                systemLanguage: "en-US"
            ).identifier,
            "zh-CN"
        )
    }

    func testAutomaticFallsBackToSystemLanguage() {
        XCTAssertEqual(
            CaptionLanguageResolver.resolve(
                preference: .automatic,
                contentHint: nil,
                systemLanguage: "zh-Hans-CN"
            ).identifier,
            "zh-CN"
        )
        // 样本太短不构成判断
        XCTAssertEqual(
            CaptionLanguageResolver.resolve(
                preference: .automatic,
                contentHint: "Hi",
                systemLanguage: "en-GB"
            ).identifier,
            "en-GB"
        )
    }

    func testMixedContentLeansChinese() {
        // 英文人名 + 中文歌词：中文识别器对夹杂英文的容忍度更好，反过来会听成拼音碎片。
        XCTAssertEqual(CaptionLanguageResolver.detect("Adele 唱的這首歌"), Locale(identifier: "zh-CN"))
    }

    func testShortOrEmptySamplesAreInconclusive() {
        XCTAssertNil(CaptionLanguageResolver.detect("Hi"))
        XCTAssertNil(CaptionLanguageResolver.detect(""))
        XCTAssertNil(CaptionLanguageResolver.detect("1234567"))
    }

    func testPreferenceRoundTripsThroughDefaults() {
        let original = CaptionRecognitionLanguage.current
        defer { CaptionRecognitionLanguage.current = original }

        CaptionRecognitionLanguage.current = .english
        XCTAssertEqual(CaptionRecognitionLanguage.current, .english)

        CaptionRecognitionLanguage.current = .automatic
        XCTAssertEqual(CaptionRecognitionLanguage.current, .automatic)
    }
}

/// 换语言的滞后判据。
///
/// 根因记录：语种线索曾被 OCR 读到的桌面中文与歌词里的西文交替污染，
/// 「自动」每 2–4 秒在 zh-CN / en-US 之间翻转，识别会话随之反复重建，字幕始终为空。
final class CaptionLanguageSwitchGuardTests: XCTestCase {

    func testSwitchRequiresTwoStableProbes() {
        var guardUnit = CaptionLanguageSwitchGuard(minimumProbeGap: 3, minimumSessionAge: 8)
        guardUnit.sessionStarted(at: 0)

        XCTAssertFalse(guardUnit.shouldSwitch(to: "en-US", from: "zh-CN", now: 10))
        XCTAssertFalse(guardUnit.shouldSwitch(to: "en-US", from: "zh-CN", now: 12), "间隔不足 3 秒不算连续成立")
        XCTAssertTrue(guardUnit.shouldSwitch(to: "en-US", from: "zh-CN", now: 13))
    }

    func testFlippingTargetsNeverSwitches() {
        var guardUnit = CaptionLanguageSwitchGuard(minimumProbeGap: 3, minimumSessionAge: 8)
        guardUnit.sessionStarted(at: 0)

        XCTAssertFalse(guardUnit.shouldSwitch(to: "en-US", from: "zh-CN", now: 10))
        XCTAssertFalse(guardUnit.shouldSwitch(to: "zh-CN", from: "zh-CN", now: 13), "回到当前语言即清空待定项")
        XCTAssertFalse(guardUnit.shouldSwitch(to: "en-US", from: "zh-CN", now: 16))
        XCTAssertFalse(guardUnit.shouldSwitch(to: "en-US", from: "zh-CN", now: 17), "尚未攒够间隔")
        XCTAssertTrue(guardUnit.shouldSwitch(to: "en-US", from: "zh-CN", now: 20))
    }

    func testYoungSessionIsNotRestarted() {
        var guardUnit = CaptionLanguageSwitchGuard(minimumProbeGap: 3, minimumSessionAge: 8)
        guardUnit.sessionStarted(at: 100)

        XCTAssertFalse(guardUnit.shouldSwitch(to: "en-US", from: "zh-CN", now: 103))
        XCTAssertFalse(guardUnit.shouldSwitch(to: "en-US", from: "zh-CN", now: 107), "会话未满 8 秒不换")
        // 110 才满足会话年龄，此处只是「记下待定语言」，不立刻换。
        XCTAssertFalse(guardUnit.shouldSwitch(to: "en-US", from: "zh-CN", now: 110))
        XCTAssertTrue(guardUnit.shouldSwitch(to: "en-US", from: "zh-CN", now: 113))
    }
}

/// 字幕来源偏好如何裁剪证据链。
final class CaptionSourcePreferenceTests: XCTestCase {

    func testAutomaticKeepsEverySource() {
        XCTAssertTrue(CaptionSourcePreference.automatic.includesLyrics)
        XCTAssertTrue(CaptionSourcePreference.automatic.includesFrameText)
    }

    func testMusicSkipsScreenText() {
        XCTAssertTrue(CaptionSourcePreference.music.includesLyrics)
        XCTAssertFalse(CaptionSourcePreference.music.includesFrameText, "音乐场景不该每秒截图跑 OCR")
    }

    func testVisualIgnoresLyrics() {
        XCTAssertFalse(CaptionSourcePreference.visual.includesLyrics, "看视频时暂停中的歌曲歌词必须让位")
        XCTAssertTrue(CaptionSourcePreference.visual.includesFrameText)
    }
}
