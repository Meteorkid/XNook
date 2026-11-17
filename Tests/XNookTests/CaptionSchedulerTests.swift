import XCTest
@testable import XNook

/// 调度器是整个字幕功能里唯一承载权 1 判定逻辑的部件，
/// 因此这里逐条验证三件事：链长由有效预算反解、证书三项条件同时成立才短路、已读边界与代次过滤不放过迟到证据。
@MainActor
final class CaptionSchedulerTests: XCTestCase {

    // MARK: - 测试替身

    private final class StubProvider: CaptionEvidenceProvider {
        let providerID: String
        let level: EvidenceLevel
        let prefetchRequired: Bool
        let allowsAsync = true
        let isSlow = false
        var weight: Double
        let estimatedLatency: TimeInterval
        let timeoutAction: CaptionTimeoutAction = .discard
        var onCandidates: (([CaptionCandidate]) -> Void)?
        var onCoverageChange: (() -> Void)?

        init(
            id: String,
            level: EvidenceLevel,
            latency: TimeInterval,
            prefetchRequired: Bool = false,
            weight: Double = 0.5
        ) {
            self.providerID = id
            self.level = level
            self.estimatedLatency = latency
            self.prefetchRequired = prefetchRequired
            self.weight = weight
        }

        func start() {}
        func stop() {}
    }

    // MARK: - 夹具

    private func anchoredClock(_ time: TimeInterval) -> SourceClock {
        let clock = SourceClock()
        clock.align(sourceTime: time, rate: 1, signature: "test")
        return clock
    }

    private func makeScheduler(
        clock: SourceClock,
        providers: [CaptionEvidenceProvider],
        config: CaptionScheduler.Config = CaptionScheduler.Config()
    ) -> CaptionScheduler {
        let scheduler = CaptionScheduler(config: config)
        scheduler.attach(clock: clock)
        scheduler.register(providers)
        return scheduler
    }

    /// 紧预算（L_eff = 0.28）。链长算术用固定预算验证，避免被线上默认值的变化牵着走。
    private var tightBudget: CaptionScheduler.Config {
        .init(deadlineBudget: 0.30, renderReserve: 0.02)
    }

    private func candidate(
        _ provider: StubProvider,
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        generation: Int
    ) -> CaptionCandidate {
        CaptionCandidate(
            providerID: provider.providerID,
            level: provider.level,
            weight: provider.weight,
            start: start,
            end: end,
            text: text,
            generation: generation,
            pipelineKey: "test"
        )
    }

    // MARK: - 有效预算与链长反解

    func testEffectiveBudgetSubtractsRenderReserve() {
        let scheduler = CaptionScheduler(config: .init(deadlineBudget: 0.30, renderReserve: 0.02))
        XCTAssertEqual(scheduler.effectiveBudget, 0.28, accuracy: 1e-9)
    }

    func testChainLengthAccumulatesUntilBudgetIsExceeded() {
        let clock = anchoredClock(100)
        // 排序后：appText(0.20) → alignedFullText(0.15) → streaming(0.10)
        let app = StubProvider(id: "app", level: .appText, latency: 0.20)
        let aligned = StubProvider(id: "align", level: .alignedFullText, latency: 0.15)
        let speech = StubProvider(id: "speech", level: .streaming, latency: 0.10)
        let scheduler = makeScheduler(clock: clock, providers: [speech, app, aligned], config: tightBudget)

        // 0.20 ≤ 0.28，再加 0.15 就超了。
        XCTAssertEqual(scheduler.chainLength(for: 50, prefetchability: 0), 1)
        XCTAssertTrue(scheduler.shouldExecute(app, unitIndex: 50, prefetchability: 0))
        XCTAssertFalse(scheduler.shouldExecute(aligned, unitIndex: 50, prefetchability: 0))
        XCTAssertFalse(scheduler.shouldExecute(speech, unitIndex: 50, prefetchability: 0))
    }

    /// 链长的核心性质：无论注册多少个来源，入链来源的累计耗时都不超过有效预算，
    /// 且再多放一个就一定超——这正是「呈现时刻不随来源数量增大而增大」的可执行形式。
    func testChainCostNeverExceedsEffectiveBudget() {
        let clock = anchoredClock(100)
        var providers: [CaptionEvidenceProvider] = [StubProvider(id: "app", level: .appText, latency: 0.20)]
        for index in 0..<11 {
            providers.append(StubProvider(id: "cheap-\(index)", level: .streaming, latency: 0.02))
        }
        let scheduler = makeScheduler(clock: clock, providers: providers)

        let length = scheduler.chainLength(for: 50, prefetchability: 0)
        XCTAssertGreaterThan(length, 0)
        let cost = scheduler.chain.prefix(length).reduce(0.0) { $0 + $1.estimatedLatency }
        XCTAssertLessThanOrEqual(cost, scheduler.effectiveBudget + 1e-9)

        if length < scheduler.chain.count {
            let next = scheduler.chain[length].estimatedLatency
            XCTAssertGreaterThan(cost + next, scheduler.effectiveBudget)
        }
    }

    /// P 只经「修正耗时」进入反解：同一个来源在 P = 0 时被排除，在 P = 1 时入链。
    func testPrefetchRequiredProviderIsPricedByPrefetchability() {
        let clock = anchoredClock(100)
        let prefetching = StubProvider(id: "frame", level: .frameText, latency: 0.05, prefetchRequired: true)
        let scheduler = makeScheduler(clock: clock, providers: [prefetching], config: tightBudget)

        // 修正耗时 = 0.05 + (1-0) × min(8, 0.3) = 0.35 > 0.28
        XCTAssertEqual(scheduler.chainLength(for: 50, prefetchability: 0), 0)
        XCTAssertFalse(scheduler.shouldExecute(prefetching, unitIndex: 50, prefetchability: 0))
        // P = 1 时不加等待量，0.05 直接入链。
        XCTAssertEqual(scheduler.chainLength(for: 50, prefetchability: 1), 1)
        XCTAssertTrue(scheduler.shouldExecute(prefetching, unitIndex: 50, prefetchability: 1))
    }

    /// 链长塌到 0 时退化为不要求可预取的流式兜底。
    func testChainLengthZeroFallsBackToStreamingProvider() {
        let clock = anchoredClock(100)
        let slow = StubProvider(id: "speech", level: .streaming, latency: 0.5)
        let scheduler = makeScheduler(clock: clock, providers: [slow], config: tightBudget)

        XCTAssertEqual(scheduler.chainLength(for: 0, prefetchability: 0), 0)
        XCTAssertTrue(scheduler.shouldExecute(slow, unitIndex: 0, prefetchability: 0))
    }

    // MARK: - 区间充分性证书

    func testCertificateRequiresCoverageLevelAndSettledWork() {
        let clock = anchoredClock(100)
        let aligned = StubProvider(id: "align", level: .alignedFullText, latency: 0.10)
        let scheduler = makeScheduler(clock: clock, providers: [aligned])
        let generation = clock.generation

        // 只覆盖一半：覆盖率 0.5 < 0.90
        scheduler.ingest([candidate(aligned, start: 100, end: 101, text: "半句", generation: generation)])
        scheduler.refreshCertificate(unitIndex: 50, now: 103)
        XCTAssertNotEqual(scheduler.certificateVerdict(unitIndex: 50), .established)

        // 补满整个单元，但区间尚未终结（now 未越过结束时刻 + 最慢来源耗时）
        scheduler.ingest([candidate(aligned, start: 101, end: 102, text: "后半句", generation: generation)])
        scheduler.refreshCertificate(unitIndex: 50, now: 101.5)
        XCTAssertNotEqual(scheduler.certificateVerdict(unitIndex: 50), .established)

        // 三项条件全部满足
        scheduler.refreshCertificate(unitIndex: 50, now: 103)
        XCTAssertEqual(scheduler.certificateVerdict(unitIndex: 50), .established)
    }

    func testLowLevelEvidenceNeverEstablishesCertificate() {
        let clock = anchoredClock(100)
        let speech = StubProvider(id: "speech", level: .streaming, latency: 0.10)
        let scheduler = makeScheduler(clock: clock, providers: [speech])

        scheduler.ingest([candidate(speech, start: 100, end: 102, text: "整句", generation: clock.generation)])
        scheduler.refreshCertificate(unitIndex: 50, now: 110)
        // 覆盖率满、工作已终结，但最高等级低于 θ，证书不成立。
        XCTAssertEqual(scheduler.certificateVerdict(unitIndex: 50), .failed)
    }

    func testEstablishedCertificateShortCircuitsLowerLevelProviders() {
        let clock = anchoredClock(100)
        let aligned = StubProvider(id: "align", level: .alignedFullText, latency: 0.10)
        let speech = StubProvider(id: "speech", level: .streaming, latency: 0.10)
        let scheduler = makeScheduler(clock: clock, providers: [aligned, speech])

        scheduler.ingest([candidate(aligned, start: 100, end: 102, text: "整句", generation: clock.generation)])
        scheduler.refreshCertificate(unitIndex: 50, now: 103)

        XCTAssertTrue(scheduler.isShortCircuited(speech, unitIndex: 50))
        XCTAssertTrue(scheduler.isShortCircuited(aligned, unitIndex: 50))
    }

    /// 证书成立后，链长反解会跳过等级不高于证书最高等级的来源，本区间不再为它们分配预算。
    func testChainLengthSkipsProvidersBelowCertificateLevel() {
        let clock = anchoredClock(100)
        let aligned = StubProvider(id: "align", level: .alignedFullText, latency: 0.05)
        let speech = StubProvider(id: "speech", level: .streaming, latency: 0.05)
        let app = StubProvider(id: "app", level: .appText, latency: 0.20)
        let scheduler = makeScheduler(clock: clock, providers: [aligned, speech, app], config: tightBudget)

        XCTAssertEqual(scheduler.chainLength(for: 50, prefetchability: 0), 2) // app 0.20 + align 0.05

        scheduler.ingest([candidate(aligned, start: 100, end: 102, text: "整句", generation: clock.generation)])
        scheduler.refreshCertificate(unitIndex: 50, now: 103)

        // 证书最高等级为 alignedFullText：speech 与 align 都不再占预算，只剩 app。
        XCTAssertEqual(scheduler.chainLength(for: 50, prefetchability: 0), 1)
    }

    // MARK: - 覆盖判定（执行期短路）

    /// 执行期不能用证书做闸门：证书要求区间已终结，而低等级来源要在区间进行中就决定跑不跑。
    func testHasCoverageSeesHigherLevelCandidateBeforeIntervalSettles() {
        let clock = anchoredClock(100)
        let lyrics = StubProvider(id: "lyrics", level: .alignedFullText, latency: 0.05)
        let scheduler = makeScheduler(clock: clock, providers: [lyrics])

        scheduler.ingest([candidate(lyrics, start: 100, end: 102, text: "整句", generation: clock.generation)])

        XCTAssertTrue(scheduler.hasCoverage(unitIndex: 50, atLeast: .frameText))
        // 等级不够的来源不算覆盖：画面文字要求 ≥3，这里给 6 级自然满足；反过来问 6 级则未覆盖
        XCTAssertFalse(scheduler.hasCoverage(unitIndex: 50, atLeast: .appText))
        // 同一时刻证书还不会成立（区间未终结），证明确实是两条不同的判据
        XCTAssertNotEqual(scheduler.certificateVerdict(unitIndex: 50), .established)
    }

    func testHasCoverageIsFalseForPartlyCoveredInterval() {
        let clock = anchoredClock(100)
        let lyrics = StubProvider(id: "lyrics", level: .alignedFullText, latency: 0.05)
        let scheduler = makeScheduler(clock: clock, providers: [lyrics])

        scheduler.ingest([candidate(lyrics, start: 100, end: 101, text: "半句", generation: clock.generation)])
        XCTAssertFalse(scheduler.hasCoverage(unitIndex: 50, atLeast: .frameText))
    }

    // MARK: - 已读边界与代次

    func testEvidenceEndingBeforeReadBoundaryIsRejected() {
        let clock = anchoredClock(200)
        let speech = StubProvider(id: "speech", level: .streaming, latency: 0.10)
        let scheduler = makeScheduler(clock: clock, providers: [speech])

        // 结束于 102，已越过 now - readProtection(=2) 的边界。
        scheduler.ingest([candidate(speech, start: 100, end: 102, text: "旧句", generation: clock.generation)])
        XCTAssertEqual(scheduler.diagnostics.candidates, 0)
    }

    func testEvidenceFromPreviousGenerationIsDiscarded() {
        let clock = anchoredClock(100)
        let speech = StubProvider(id: "speech", level: .streaming, latency: 0.10)
        let scheduler = makeScheduler(clock: clock, providers: [speech])

        scheduler.ingest([
            candidate(speech, start: 100, end: 102, text: "跳变前的迟到结果", generation: clock.generation + 1)
        ])
        XCTAssertEqual(scheduler.diagnostics.candidates, 0)
    }

    func testEmptyTextIsNotIngested() {
        let clock = anchoredClock(100)
        let speech = StubProvider(id: "speech", level: .streaming, latency: 0.10)
        let scheduler = makeScheduler(clock: clock, providers: [speech])

        scheduler.ingest([candidate(speech, start: 100, end: 101, text: "   ", generation: clock.generation)])
        XCTAssertEqual(scheduler.diagnostics.candidates, 0)
    }

    // MARK: - 取行

    func testTickPublishesHighestLevelInLatestCluster() {
        let clock = anchoredClock(100)
        let speech = StubProvider(id: "speech", level: .streaming, latency: 0.10)
        let cache = StubProvider(id: "cache", level: .localCache, latency: 0.12)
        let scheduler = makeScheduler(clock: clock, providers: [cache, speech])
        let generation = clock.generation

        scheduler.ingest([
            candidate(speech, start: 100, end: 101.4, text: "流式结果", generation: generation),
            candidate(cache, start: 100, end: 101.4, text: "缓存结果", generation: generation),
        ])

        var published: [String] = []
        scheduler.onLineChange = { text, _ in published.append(text) }
        scheduler.tick(prefetchability: 0)

        XCTAssertEqual(scheduler.currentLine, "缓存结果")
        XCTAssertEqual(scheduler.currentLevel, .localCache)
        XCTAssertEqual(published.last, "缓存结果")
    }

    func testTickKeepsSilentWhenNothingIsVisibleYet() {
        let clock = anchoredClock(100)
        let speech = StubProvider(id: "speech", level: .streaming, latency: 0.10)
        let scheduler = makeScheduler(clock: clock, providers: [speech])

        // 起点在未来：还没到呈现时刻。
        scheduler.ingest([candidate(speech, start: 108, end: 109, text: "还没说到", generation: clock.generation)])
        scheduler.tick(prefetchability: 0)

        XCTAssertTrue(scheduler.currentLine.isEmpty)
    }

    func testResetClearsPublishedLine() {
        let clock = anchoredClock(100)
        let speech = StubProvider(id: "speech", level: .streaming, latency: 0.10)
        let scheduler = makeScheduler(clock: clock, providers: [speech])

        scheduler.ingest([candidate(speech, start: 100, end: 101, text: "一句", generation: clock.generation)])
        scheduler.tick(prefetchability: 0)
        XCTAssertFalse(scheduler.currentLine.isEmpty)

        scheduler.reset()
        XCTAssertTrue(scheduler.currentLine.isEmpty)
        XCTAssertNil(scheduler.currentLevel)
        XCTAssertEqual(scheduler.diagnostics.chainLength, 0)
    }

    // MARK: - 区间单元

    func testIntervalIndexAndRangeAgree() {
        XCTAssertEqual(CaptionInterval.index(for: 0, unit: 2), 0)
        XCTAssertEqual(CaptionInterval.index(for: 1.999, unit: 2), 0)
        XCTAssertEqual(CaptionInterval.index(for: 2, unit: 2), 1)
        XCTAssertEqual(CaptionInterval.range(index: 50, unit: 2), 100..<102)
        // 负数时间不应产生负索引
        XCTAssertEqual(CaptionInterval.index(for: -3, unit: 2), 0)
    }
}
