import XCTest
@testable import XNook

/// 歌词来源是让链里出现第二个、也是第一个高等级来源的关键，因此单独验证它的产出形状。
@MainActor
final class LyricEvidenceProviderTests: XCTestCase {

    private func lines(_ times: [TimeInterval], _ texts: [String]) -> [LyricsManager.LrcLine] {
        zip(times, texts).map { LyricsManager.LrcLine(time: $0, text: $1) }
    }

    func testSubmitEmitsAlignedCandidatePerLine() {
        var generation = 3
        let provider = LyricEvidenceProvider { generation }
        var captured: [CaptionCandidate] = []
        provider.onCandidates = { captured = $0 }

        provider.submit(lines([0, 10, 20], ["第一句", "第二句", "最后一句"]), signature: "a")

        XCTAssertEqual(captured.count, 3)
        XCTAssertEqual(captured.map(\.start), [0, 10, 20])
        // 行区间用下一行的起点收口；最后一行没有下一行，给固定展示窗口。
        XCTAssertEqual(captured[0].end, 10)
        XCTAssertEqual(captured[1].end, 20)
        XCTAssertEqual(captured[2].end, 24)
        XCTAssertTrue(captured.allSatisfy { $0.level == .alignedFullText })
        XCTAssertTrue(captured.allSatisfy { $0.state == .stable })
        XCTAssertTrue(captured.allSatisfy { $0.generation == 3 })
    }

    /// 同一份歌词重复提交不应产生候选洪泛；换了签名才重灌。
    func testSameSignatureIsIgnored() {
        var emitted = 0
        let provider = LyricEvidenceProvider { 1 }
        provider.onCandidates = { emitted += $0.count }

        provider.submit(lines([0, 10], ["甲", "乙"]), signature: "same")
        XCTAssertEqual(emitted, 2)

        provider.submit(lines([0, 10], ["甲", "乙"]), signature: "same")
        XCTAssertEqual(emitted, 2, "同一份歌词不应再次灌入")
    }

    /// 时间轴跳变后调度器会清空，歌词必须按新代次重灌，否则整首歌词会被当成迟到结果丢弃。
    func testResubmitUsesCurrentGeneration() {
        var generation = 1
        let provider = LyricEvidenceProvider { generation }
        var captured: [CaptionCandidate] = []
        provider.onCandidates = { captured = $0 }

        provider.submit(lines([0, 10], ["甲", "乙"]), signature: "song")
        XCTAssertEqual(captured.map(\.generation), [1, 1])

        generation = 7
        provider.resubmit()
        XCTAssertEqual(captured.map(\.generation), [7, 7])
    }

    func testEmptySubmitClearsCoverage() {
        var coverageInvalidations = 0
        let provider = LyricEvidenceProvider { 1 }
        provider.onCandidates = { _ in }
        provider.onCoverageChange = { coverageInvalidations += 1 }

        provider.submit(lines([0, 10], ["甲", "乙"]), signature: "song")
        provider.submit([], signature: "")
        XCTAssertEqual(coverageInvalidations, 1)
    }

    /// 空白行不该变成一条看不见的候选占住区间。
    func testBlankLinesAreDropped() {
        let provider = LyricEvidenceProvider { 1 }
        var captured: [CaptionCandidate] = []
        provider.onCandidates = { captured = $0 }

        provider.submit(lines([0, 5, 10], ["有效", "   ", "也有效"]), signature: "x")
        XCTAssertEqual(captured.map(\.text), ["有效", "也有效"])
    }
}
