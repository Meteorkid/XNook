import XCTest
@testable import XNook

/// 画面文字来源是「什么时候可以不算了」唯一的真实受益人，因此重点验证闸门与计数，
/// 而不是识别质量（那取决于屏幕内容和用户权限，无法在单测里复现）。
@MainActor
final class FrameTextEvidenceProviderTests: XCTestCase {

    func testGateRejectionSkipsIntervalWithoutExecuting() {
        let provider = FrameTextEvidenceProvider(clock: SourceClock())
        // 注入一个恒拒绝的闸门，等价于「该区间已有更高等级证书，不必再算」。
        provider.runGate = { _ in false }
        provider.start()

        provider.advance(now: 1.0, unit: 2.0)

        XCTAssertEqual(provider.skippedIntervals, 1)
        XCTAssertEqual(provider.executedIntervals, 0)
    }

    func testSameIntervalIsNotRequestedTwice() {
        let provider = FrameTextEvidenceProvider(clock: SourceClock())
        provider.runGate = { _ in false }
        provider.start()

        provider.advance(now: 1.0, unit: 2.0)
        provider.advance(now: 1.5, unit: 2.0)
        provider.advance(now: 1.9, unit: 2.0)

        XCTAssertEqual(provider.skippedIntervals, 1, "同一区间只判定一次")
    }

    /// 区间刚开始就抓帧会读到上一句字幕，因此延迟窗口内不应消耗判定。
    func testCaptureDelayDefersJudgement() {
        let provider = FrameTextEvidenceProvider(clock: SourceClock())
        provider.runGate = { _ in false }
        provider.start()

        provider.advance(now: 0.1, unit: 2.0)
        XCTAssertEqual(provider.skippedIntervals, 0)

        provider.advance(now: 0.6, unit: 2.0)
        XCTAssertEqual(provider.skippedIntervals, 1)
    }

    func testResetAllowsRejudgingAfterTimelineJump() {
        let provider = FrameTextEvidenceProvider(clock: SourceClock())
        provider.runGate = { _ in false }
        provider.start()

        provider.advance(now: 1.0, unit: 2.0)
        XCTAssertEqual(provider.skippedIntervals, 1)

        provider.reset()
        provider.advance(now: 1.2, unit: 2.0)
        XCTAssertEqual(provider.skippedIntervals, 2)
    }

    func testStopDisablesAdvance() {
        let provider = FrameTextEvidenceProvider(clock: SourceClock())
        provider.runGate = { _ in false }
        provider.start()
        provider.stop()

        provider.advance(now: 5.0, unit: 2.0)
        XCTAssertEqual(provider.skippedIntervals, 0)
        XCTAssertEqual(provider.executedIntervals, 0)
    }

    // MARK: - 文本清洗

    /// 清洗规则决定了 OCR 会不会用噪声覆盖掉准确的字幕，是这条链路的质量闸门。
    func testSanitizeAcceptsSubtitleLikeText() {
        XCTAssertEqual(ScreenTextRecognizer.sanitize("  你好，世界  "), "你好，世界")
        XCTAssertEqual(ScreenTextRecognizer.sanitize("Hello there"), "Hello there")
        XCTAssertEqual(ScreenTextRecognizer.sanitize("第 3 集"), "第 3 集")
    }

    func testSanitizeRejectsNoise() {
        XCTAssertNil(ScreenTextRecognizer.sanitize(""))
        XCTAssertNil(ScreenTextRecognizer.sanitize("   "))
        XCTAssertNil(ScreenTextRecognizer.sanitize("—"))
        XCTAssertNil(ScreenTextRecognizer.sanitize("12:34"))
        XCTAssertNil(ScreenTextRecognizer.sanitize("2026-11-17"))
        XCTAssertNil(ScreenTextRecognizer.sanitize(String(repeating: "长", count: 80)))
    }
}
