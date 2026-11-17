import XCTest
@testable import XNook

/// 用可复现的数字回答「这套机制到底有没有用」。
///
/// 权 1 的效果句是「呈现时刻由有效预算确定、不随证据提供者数量增大而增大」。
/// 这里就测这句话：来源数从 1 涨到 32，朴素串行做法的呈现耗时会线性增长，
/// 而按预算反解链长后的耗时必须钉在 L_eff 以内。
@MainActor
final class CaptionBudgetBenchmarkTests: XCTestCase {

    private final class StubProvider: CaptionEvidenceProvider {
        let providerID: String
        let level: EvidenceLevel
        let prefetchRequired = false
        let allowsAsync = true
        let isSlow = false
        var weight: Double = 0.5
        let estimatedLatency: TimeInterval
        let timeoutAction: CaptionTimeoutAction = .discard
        var onCandidates: (([CaptionCandidate]) -> Void)?
        var onCoverageChange: (() -> Void)?

        init(id: String, level: EvidenceLevel = .frameText, latency: TimeInterval) {
            self.providerID = id
            self.level = level
            self.estimatedLatency = latency
        }

        func start() {}
        func stop() {}
    }

    /// 单源耗时统一的串行模型：每多一个来源就多等一份推理时间。
    /// 这正是本地推理真实的样子——单核算力只能一个一个跑。
    func testPresentedLatencyStaysBoundedAsProviderCountGrows() {
        let perProvider: TimeInterval = 0.20
        let scheduler = CaptionScheduler(config: .init(deadlineBudget: 0.90, renderReserve: 0.02))
        let budget = scheduler.effectiveBudget

        var rows: [String] = []
        rows.append("来源数 | 朴素串行 | 反解后 | 入链数")
        rows.append("------|----------|--------|-------")

        for count in [1, 2, 4, 8, 16, 32] {
            let providers: [CaptionEvidenceProvider] = (0..<count).map { index in
                StubProvider(id: "p\(index)", latency: perProvider)
            }
            let bench = CaptionScheduler(config: .init(deadlineBudget: 0.90, renderReserve: 0.02))
            bench.register(providers)

            let length = bench.chainLength(for: 0, prefetchability: 0)
            let naive = perProvider * Double(count)
            let bounded = perProvider * Double(length)

            XCTAssertLessThanOrEqual(bounded, budget + 1e-9, "入链耗时必须落在有效预算内")
            XCTAssertGreaterThan(length, 0, "链长不能塌到 0，否则主路径没有执行")
            if count > Int(budget / perProvider) {
                XCTAssertLessThan(bounded, naive, "来源超出预算后必须开始封顶")
            }

            rows.append(String(format: "%6d | %8.2fs | %6.2fs | %6d", count, naive, bounded, length))
        }

        print("\n" + rows.joined(separator: "\n") + "\n")
    }

    /// 来源再多，只要有一个来源的等级更高，它就必须排在最前面——
    /// 预算紧张时先牺牲低等级来源，而不是牺牲可信度。
    func testHigherLevelProviderWinsTheBudget() {
        let scheduler = CaptionScheduler(config: .init(deadlineBudget: 0.30, renderReserve: 0.02))
        let low = StubProvider(id: "speech", level: .streaming, latency: 0.20)
        let high = StubProvider(id: "app", level: .appText, latency: 0.20)
        scheduler.register([low, high])

        // L_eff = 0.28，只够一个来源：必须留给等级更高的那个。
        XCTAssertEqual(scheduler.chainLength(for: 0, prefetchability: 0), 1)
        XCTAssertTrue(scheduler.shouldExecute(high, unitIndex: 0, prefetchability: 0))
        XCTAssertFalse(scheduler.shouldExecute(low, unitIndex: 0, prefetchability: 0))
    }

    /// 线上真实配置：歌词（5 级、05 s、需预取）+ 流式识别（1 级、0.35 s、不需预取），预算 0.9 s。
    /// 两源都应在链内，且歌词排在识别之前。
    func testProductionChainAdmitsBothSources() {
        let lyrics = LyricEvidenceProvider { 1 }
        let speech = StubProvider(id: "speech", level: .streaming, latency: 0.35)
        let scheduler = CaptionScheduler(config: .init())
        scheduler.register([speech, lyrics])

        XCTAssertEqual(scheduler.chain.first?.providerID, "lyrics.lrc")
        // P = 0.9（有全文歌词，可预取）
        XCTAssertEqual(scheduler.chainLength(for: 0, prefetchability: 0.9), 2)
        XCTAssertTrue(scheduler.shouldExecute(speech, unitIndex: 0, prefetchability: 0.9))
        // P = 0（无歌词，视频/会议）时歌词源被按最坏情况计价，但两源合计仍在预算内
        XCTAssertEqual(scheduler.chainLength(for: 0, prefetchability: 0), 2)
    }
}
