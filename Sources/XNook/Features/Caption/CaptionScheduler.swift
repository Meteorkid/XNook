import Foundation

/// 证据优先级链调度器（对应权 1 全部步骤）。
///
/// 数据流：各证据提供者产出候选条目 → 按绝对源时间戳写入区间单元 → 反解链长决定谁可以执行
/// → 证书决定已覆盖区间是否短路 → 首帧时限到达时取已就绪的最高等级条目渲染。
///
/// 三条约束在本类中是可执行代码，而不是注释：
/// 1. 链长 k 由有效预算反解，P 只经「修正耗时」进入反解（`chainLength(for:)`）；
/// 2. 证书的成立以覆盖率、最高等级与「该区间工作已终结」三项为条件（`refreshCertificate`）；
/// 3. 证书成立时，等级不高于最高等级的来源对该区间不再执行（`shouldExecute`）。
@MainActor
final class CaptionScheduler {

    struct Config {
        /// 时间区间单元宽度 W。
        var unit: TimeInterval = 2.0
        /// 首帧时限预算 L_budget。
        ///
        /// 取值要与实测延迟同量级，否则链长会恒为 0、主路径永不执行。
        /// 本机实测（本地识别 + 已对齐歌词两源）单源耗时 0.05 s / 0.35 s，
        /// 端到端 0.3–0.6 s 属正常范围，故预算取 0.9 s：既能容纳两源串行，
        /// 又对「再多几个来源」保持硬上限。
        var deadlineBudget: TimeInterval = 0.90
        /// 渲染预留量 δ_render。
        var renderReserve: TimeInterval = 0.02
        /// 覆盖率阈值 ρ_cov。
        var coverageThreshold: Double = 0.90
        /// 等级阈值 θ。
        var levelThreshold: EvidenceLevel = .alignedFullText
        /// 已读保护时长：区间结束后多久内仍允许晚到证据修正。
        var readProtection: TimeInterval = 2.0
        /// 闭环迭代上限 N_iter。
        var maxIterations: Int = 3
        /// 候选与证书的保留时长。
        var retention: TimeInterval = 120
        /// 一条字幕行在时间轴上额外保留的显示余量。
        var displayGrace: TimeInterval = 1.0
    }

    struct Diagnostics {
        var chainLength: Int = 0
        var certificatesEstablished: Int = 0
        var candidates: Int = 0
        var lastProvider: String = ""
    }

    let config: Config
    private(set) var chain: [CaptionEvidenceProvider] = []
    private(set) var diagnostics = Diagnostics()

    /// 当前应显示的字幕行。
    private(set) var currentLine: String = ""
    /// 当前行的证据来源等级，UI 可据此决定是否弱化显示（低等级用更淡的颜色）。
    private(set) var currentLevel: EvidenceLevel?

    var onLineChange: ((String, EvidenceLevel?) -> Void)?

    private var clock = SourceClock()
    private let unit: TimeInterval

    /// 按区间单元归档的候选条目。
    private var store: [Int: [CaptionCandidate]] = [:]
    /// 区间充分性证书。
    private var certificates: [Int: CaptionSufficiencyCertificate] = [:]
    /// 每个区间上「最高等级之外仍需执行」的来源，用于短路判定。
    private var readBoundary: TimeInterval = -.greatestFiniteMagnitude

    init(config: Config = Config()) {
        self.config = config
        self.unit = config.unit
    }

    // MARK: - 装配

    func attach(clock: SourceClock) {
        self.clock = clock
    }

    func register(_ providers: [CaptionEvidenceProvider]) {
        // 证据优先级链：按等级由高到低排列，等级相同时后来者在前（便于替换）。
        chain = providers.sorted { lhs, rhs in
            lhs.level == rhs.level ? lhs.estimatedLatency < rhs.estimatedLatency : lhs.level > rhs.level
        }
        for provider in chain {
            provider.onCandidates = { [weak self] candidates in
                Task { @MainActor in self?.ingest(candidates) }
            }
            provider.onCoverageChange = { [weak self] in
                Task { @MainActor in self?.invalidateAllCertificates() }
            }
        }
    }

    // MARK: - 候选写入

    /// 写入候选条目。写入门槛只有一条：不得回改已读区间。
    func ingest(_ candidates: [CaptionCandidate]) {
        guard !candidates.isEmpty else { return }
        let now = clock.sourceNow()
        readBoundary = now - config.readProtection
        let currentGeneration = clock.generation

        var touchedUnits = Set<Int>()
        var accepted = 0

        for candidate in candidates {
            // 代次不符的迟到结果直接丢弃（对应权 6 的迟到转写结果丢弃）。
            guard candidate.generation == currentGeneration else { continue }
            // 已读区间一律不写入，也不回改已呈现条目。
            guard candidate.end > readBoundary else { continue }
            guard !candidate.isEmpty else { continue }

            let first = CaptionInterval.index(for: candidate.start, unit: unit)
            let last = CaptionInterval.index(for: max(candidate.start, candidate.end - 0.001), unit: unit)
            for index in first...last {
                merge(candidate, into: index)
                touchedUnits.insert(index)
            }
            accepted += 1
        }

        guard accepted > 0 else { return }
        diagnostics.candidates += accepted
        diagnostics.lastProvider = candidates.first?.providerID ?? ""

        for index in touchedUnits {
            refreshCertificate(unitIndex: index, now: now)
        }
    }

    /// 同源候选直接替换（同一识别会话的静默修正）；异源候选按证据权重比较后才替换。
    private func merge(_ candidate: CaptionCandidate, into index: Int) {
        var bucket = store[index] ?? []

        if let sameSource = bucket.firstIndex(where: {
            $0.providerID == candidate.providerID && overlaps($0, candidate)
        }) {
            let existing = bucket[sameSource]
            if existing.state == .stable && existing.text == candidate.text {
                return
            }
            bucket[sameSource] = candidate
            store[index] = bucket
            return
        }

        if let overlapping = bucket.firstIndex(where: { overlaps($0, candidate) }) {
            let existing = bucket[overlapping]
            guard candidate.weight > existing.weight || candidate.level > existing.level else { return }
            bucket[overlapping] = candidate
            store[index] = bucket
            return
        }

        bucket.append(candidate)
        store[index] = bucket
    }

    private func overlaps(_ lhs: CaptionCandidate, _ rhs: CaptionCandidate) -> Bool {
        lhs.start < rhs.end && rhs.start < lhs.end
    }

    // MARK: - 反解链长

    /// 有效预算：L_budget 扣除渲染预留量。
    var effectiveBudget: TimeInterval {
        max(0.01, config.deadlineBudget - config.renderReserve)
    }

    /// 修正耗时：P 越小（越不可预取），要求可预取的来源需要等待的前瞻音频越长，耗时越大。
    /// 系统级捕获拿不到播放前沿之后的音频，A 恒为 0，故对 `prefetchRequired` 的来源修正耗时取「声明耗时 + 等待量」。
    private func correctedCost(_ provider: CaptionEvidenceProvider, prefetchability p: Double) -> TimeInterval {
        guard provider.prefetchRequired else { return provider.estimatedLatency }
        return provider.estimatedLatency + (1 - p) * min(8, provider.estimatedLatency * 6)
    }

    /// 参与本区间预算竞争的来源。
    /// 两道过滤：当前不可用的来源不占预算；已被证书覆盖的低等级来源不必再参与。
    private func eligibleProviders(for unitIndex: Int) -> [CaptionEvidenceProvider] {
        let maxLevel = certificates[unitIndex]?.maxLevel
        return chain.filter { provider in
            guard provider.isAvailable else { return false }
            if let maxLevel, provider.level <= maxLevel { return false }
            return true
        }
    }

    /// 反解区间上的链长 k。
    func chainLength(for unitIndex: Int, prefetchability p: Double) -> Int {
        var cumulative: TimeInterval = 0
        var length = 0
        for provider in eligibleProviders(for: unitIndex) {
            let cost = correctedCost(provider, prefetchability: p)
            if cumulative + cost > effectiveBudget { break }
            cumulative += cost
            length += 1
        }
        return length
    }

    /// 该区间上某来源是否允许执行。
    /// k 为 0 时退化为不要求可预取的流式识别兜底（见说明书 5.5 异常处理）。
    func shouldExecute(_ provider: CaptionEvidenceProvider, unitIndex: Int, prefetchability p: Double) -> Bool {
        guard provider.isAvailable else { return false }
        let length = chainLength(for: unitIndex, prefetchability: p)
        if length == 0 {
            return !provider.prefetchRequired && provider.level == .streaming
        }
        // 序位必须在同一份「可竞争名单」里取，否则被跳过的来源会让序位错位。
        let eligible = eligibleProviders(for: unitIndex)
        guard let position = eligible.firstIndex(where: { $0 === provider }) else { return false }
        return position < length
    }

    // MARK: - 区间充分性证书

    /// 重判单个区间的证书。
    /// 闭环：证书给出最高等级 → 重算链长 → 链长若变则再判一次，最多 N_iter 次。
    func refreshCertificate(unitIndex: Int, now: TimeInterval) {
        var certificate = certificates[unitIndex] ?? CaptionSufficiencyCertificate(intervalIndex: unitIndex)
        let bounds = CaptionInterval.range(index: unitIndex, unit: unit)

        var previousMax = certificate.maxLevel
        var iterations = 0

        repeat {
            let bucket = store[unitIndex] ?? []
            let relevant = bucket.filter { $0.end > readBoundary }

            let coverage = coverageRatio(of: relevant, in: bounds)
            let maxLevel = relevant.map(\.level).max()

            certificate.coverage = coverage
            certificate.maxLevel = maxLevel
            certificate.holders = Set(relevant.map(\.providerID))
            certificate.stamp = now

            // 第三项条件：该区间上链长以内的工作必须已终结。用「区间结束时刻 + 最慢来源耗时」判定，
            // 未来区间一律视为未终结，因此证书不会以「进行中的覆盖关系」成立。
            let slowest = chain.map(\.estimatedLatency).max() ?? 0
            let settled = now > bounds.upperBound + slowest

            if coverage >= config.coverageThreshold,
               let maxLevel,
               maxLevel >= config.levelThreshold,
               settled {
                certificate.verdict = .established
            } else if settled {
                certificate.verdict = .failed
            } else {
                certificate.verdict = .pending
            }

            iterations += 1
            if maxLevel == previousMax || iterations >= config.maxIterations { break }
            previousMax = maxLevel
        } while true

        certificates[unitIndex] = certificate
    }

    /// 某区间证书的当前判定。设置页诊断与单元测试共用同一入口。
    func certificateVerdict(unitIndex: Int) -> CaptionSufficiencyCertificate.Verdict {
        certificates[unitIndex]?.verdict ?? .pending
    }

    /// 某区间被「等级不低于 level」的候选覆盖的比例。
    /// 与证书不同，这里不要求区间已终结——它回答的是「现在还有必要跑低等级来源吗」。
    func coverageRatio(unitIndex: Int, atLeast level: EvidenceLevel) -> Double {
        guard let bucket = store[unitIndex] else { return 0 }
        let bounds = CaptionInterval.range(index: unitIndex, unit: unit)
        let relevant = bucket.filter { $0.level >= level && $0.end > readBoundary }
        return coverageRatio(of: relevant, in: bounds)
    }

    /// 该区间是否已被足够高等级的候选覆盖。
    ///
    /// 这是「什么时候可以不算了」的执行期判据：
    /// 证书要求区间已终结，只适用于回看历史；而低等级来源通常要在区间进行中决定跑不跑，
    /// 那时只能看覆盖，不能等证书。
    func hasCoverage(unitIndex: Int, atLeast level: EvidenceLevel) -> Bool {
        coverageRatio(unitIndex: unitIndex, atLeast: level) >= config.coverageThreshold
    }

    private func coverageRatio(of candidates: [CaptionCandidate], in bounds: Range<TimeInterval>) -> Double {
        let length = bounds.upperBound - bounds.lowerBound
        guard length > 0 else { return 0 }

        var intervals: [Range<TimeInterval>] = candidates.map {
            max($0.start, bounds.lowerBound)..<min($0.end, bounds.upperBound)
        }.filter { $0.upperBound > $0.lowerBound }

        guard !intervals.isEmpty else { return 0 }
        intervals.sort { $0.lowerBound < $1.lowerBound }

        var merged: [Range<TimeInterval>] = [intervals[0]]
        for interval in intervals.dropFirst() {
            if interval.lowerBound <= merged[merged.count - 1].upperBound {
                let last = merged.removeLast()
                merged.append(last.lowerBound..<max(last.upperBound, interval.upperBound))
            } else {
                merged.append(interval)
            }
        }

        let covered = merged.reduce(0.0) { $0 + ($1.upperBound - $1.lowerBound) }
        return min(1, covered / length)
    }

    private func invalidateAllCertificates() {
        for index in certificates.keys where certificates[index]?.verdict == .established {
            certificates[index]?.verdict = .pending
        }
    }

    /// 证书成立且等级不高于证书最高等级的来源，对该区间不执行推理。
    func isShortCircuited(_ provider: CaptionEvidenceProvider, unitIndex: Int) -> Bool {
        guard let certificate = certificates[unitIndex], certificate.verdict == .established else { return false }
        guard let maxLevel = certificate.maxLevel else { return false }
        return provider.level <= maxLevel
    }

    // MARK: - 调度周期

    /// 每个调度周期调用一次（默认 60 ms）。
    /// `prefetchability` 对应说明书中的可预取度 P：系统级捕获读不到播放前沿之后的音频，取值恒为 0；
    /// 音乐场景的信息来自元数据与既有歌词，上层可传入更高值以放行要求可预取的来源。
    func tick(prefetchability: Double = 0) {
        let now = clock.sourceNow()
        readBoundary = now - config.readProtection
        let current = CaptionInterval.index(for: now, unit: unit)

        // 只重判当前及其邻接区间：更早的区间已越过已读边界，重判没有意义。
        for index in (current - 2)...(current + 1) where index >= 0 {
            refreshCertificate(unitIndex: index, now: now)
        }

        diagnostics.chainLength = chainLength(for: current, prefetchability: prefetchability)
        diagnostics.certificatesEstablished = certificates.values.filter { $0.verdict == .established }.count

        if let best = bestCandidate(at: now) {
            publish(text: best.text, level: best.level)
        }

        prune(now: now)
    }

    /// 取行规则：
    /// 1. 只考虑呈现时刻已到（start ≤ now）且尚未越过显示余量的条目；
    /// 2. 在时间上最新的那一簇里（起点相差 0.8 s 内）取证据等级最高者；
    /// 3. 等级相同取证据权重较高者。
    /// 既不让旧的高等级条目压住新行，也不因一条低等级流式结果先到就丢掉高等级结果。
    private func bestCandidate(at now: TimeInterval) -> CaptionCandidate? {
        let current = CaptionInterval.index(for: now, unit: unit)
        var pool: [CaptionCandidate] = []
        for index in [current - 1, current, current + 1] {
            guard let bucket = store[index] else { continue }
            pool.append(contentsOf: bucket)
        }

        let visible = pool.filter { candidate in
            candidate.start <= now && candidate.end + config.displayGrace > now && !candidate.isEmpty
        }
        guard !visible.isEmpty else { return nil }

        let latestStart = visible.map(\.start).max() ?? now
        let cluster = visible.filter { latestStart - $0.start <= 0.8 }
        return cluster.max { lhs, rhs in
            if lhs.level != rhs.level { return lhs.level < rhs.level }
            if lhs.weight != rhs.weight { return lhs.weight < rhs.weight }
            return lhs.start < rhs.start
        }
    }

    private func publish(text: String, level: EvidenceLevel) {
        guard text != currentLine else {
            currentLevel = level
            return
        }
        currentLine = text
        currentLevel = level
        onLineChange?(text, level)
    }

    private func prune(now: TimeInterval) {
        let cutoff = CaptionInterval.index(for: now - config.retention, unit: unit)
        guard cutoff > 0 else { return }
        for key in store.keys where key < cutoff { store.removeValue(forKey: key) }
        for key in certificates.keys where key < cutoff { certificates.removeValue(forKey: key) }
    }

    /// 清空全部状态（音源切换、停止捕获时调用）。
    func reset() {
        store.removeAll()
        certificates.removeAll()
        currentLine = ""
        currentLevel = nil
        readBoundary = -.greatestFiniteMagnitude
        diagnostics = Diagnostics()
        onLineChange?("", nil)
    }
}
