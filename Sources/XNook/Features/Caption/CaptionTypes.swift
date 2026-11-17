import Foundation

// MARK: - 证据等级

/// 证据等级：数值越大，可信度越高。
/// 次序与说明书 3.2 F1 的六类严格降序一致：
/// 应用发布的文本流 > 既有全文的强制对齐 > 媒体元数据 > 画面文字识别 > 本地已转写缓存 > 流式语音识别。
enum EvidenceLevel: Int, CaseIterable, Comparable, Sendable {
    case streaming = 1
    case localCache = 2
    case frameText = 3
    case metadata = 4
    case alignedFullText = 5
    case appText = 6

    static func < (lhs: EvidenceLevel, rhs: EvidenceLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - 候选字幕条目

/// 条目状态取易变与已稳定两者之一。
/// 已读状态不在此枚举内——它是按播放前沿计算的独立判定量（见 `CaptionScheduler.readBoundary`）。
enum CaptionState: Sendable {
    case volatile
    case stable
}

/// 证据提供者声明的超时降级动作。
enum CaptionTimeoutAction: Sendable {
    case discard
    case degradeNext
    case fallbackStreaming
}

/// 一条候选字幕条目。
/// `start`/`end` 一律是**绝对源时间戳**：以音源自身的媒体时间轴为基准，不随识别窗口或缓冲窗口的起点变化。
struct CaptionCandidate: Identifiable, Sendable, Equatable {
    let id: UUID
    let providerID: String
    let level: EvidenceLevel
    /// 证据权重：由来源等级、估计耗时与该条目在时间轴上的连续性共同决定（用于晚到证据的比较替换）。
    let weight: Double
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    let generation: Int
    /// 生成该条目的管线标识（语言、模型、断句版本）；变化即缓存键失效。
    let pipelineKey: String
    var state: CaptionState

    init(
        id: UUID = UUID(),
        providerID: String,
        level: EvidenceLevel,
        weight: Double,
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        generation: Int,
        pipelineKey: String,
        state: CaptionState = .volatile
    ) {
        self.id = id
        self.providerID = providerID
        self.level = level
        self.weight = weight
        self.start = start
        self.end = end
        self.text = text
        self.generation = generation
        self.pipelineKey = pipelineKey
        self.state = state
    }

    var range: Range<TimeInterval> {
        start..<max(start, end)
    }

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - 证据提供者契约

/// 统一证据提供者接口（对应权 1 第二段）。
/// 每个字幕来源都必须声明下列字段；调度器只按契约调度，不关心来源内部实现。
protocol CaptionEvidenceProvider: AnyObject {
    var providerID: String { get }
    var level: EvidenceLevel { get }
    /// 是否必须读取播放前沿之后的音频才能产出候选。
    var prefetchRequired: Bool { get }
    /// 是否允许异步执行、结果晚于首帧时限到达。
    var allowsAsync: Bool { get }
    /// 是否为耗时来源（P 高时可前移到播放前沿之前执行）。
    var isSlow: Bool { get }
    var weight: Double { get }
    /// 估计耗时（秒）。反解链长时会被 P 修正为「修正耗时」。
    var estimatedLatency: TimeInterval { get }
    var timeoutAction: CaptionTimeoutAction { get }

    /// 当前是否有能力为本区间贡献候选。
    ///
    /// 这一项直接影响反解：没有歌词时，歌词来源不该占着预算把流式识别挤出链外。
    /// 默认实现恒为 true，只有「需要外部内容才能工作」的来源才覆盖它。
    var isAvailable: Bool { get }

    /// 产出的候选条目回调（可能多次调用，流式来源会反复产出）。
    var onCandidates: (([CaptionCandidate]) -> Void)? { get set }
    /// 产出的绝对源时间区间发生变化时回调（用于触发证书重判）。
    var onCoverageChange: (() -> Void)? { get set }

    func start()
    func stop()
}

extension CaptionEvidenceProvider {
    var isAvailable: Bool { true }
}

// MARK: - 时间区间单元

/// 时间区间单元：调度与证书判定的最小单位（对应说明书 5.0 的 W，示例取值 2 s）。
enum CaptionInterval {
    static func index(for time: TimeInterval, unit: TimeInterval) -> Int {
        guard unit > 0 else { return 0 }
        return Int(floor(max(0, time) / unit))
    }

    static func range(index: Int, unit: TimeInterval) -> Range<TimeInterval> {
        let start = Double(index) * unit
        return start..<(start + unit)
    }
}

// MARK: - 区间充分性证书

/// 区间充分性证书（对应权 1 的证书步骤）。
/// 成立需同时满足三项：覆盖率达标、最高等级达标、且该区间上链长以内的工作已终结。
struct CaptionSufficiencyCertificate: Sendable {
    enum Verdict: Sendable {
        case established
        case failed
        case pending
    }

    var verdict: Verdict = .pending
    var coverage: Double = 0
    var maxLevel: EvidenceLevel?
    /// 产出上述候选条目的来源标识集合，用于在链长变化时定位需重判的区间。
    var holders: Set<String> = []
    var intervalIndex: Int = 0
    var stamp: TimeInterval = 0
}
