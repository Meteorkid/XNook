import Foundation

/// 已对齐全文歌词作为证据提供者（证据等级 5，`alignedFullText`）。
///
/// 这是链里第一个「高质量、可预取」的来源，也是让权 1 的机制真正运转起来的那个来源：
/// - 它需要播放前沿之后的全文（`prefetchRequired = true`），因此它的修正耗时随可预取度 P 变化；
/// - 它的等级高于阈值 θ，所以它覆盖的区间**可以**让证书成立；
/// - 它一次产出整首的区间，等级与权重都高于流式识别，重叠区间会稳定替换掉识别文本。
///
/// 时间戳直接使用媒体时间轴（LRC 的秒数），与 `SourceClock` 对齐后的绝对源时间同一基准，
/// 不需要任何相对窗口换算。
final class LyricEvidenceProvider: CaptionEvidenceProvider {

    let providerID = "lyrics.lrc"
    let level: EvidenceLevel = .alignedFullText
    let prefetchRequired = true
    let allowsAsync = true
    let isSlow = false
    var weight: Double = 0.90
    /// 已经解析好的文本，取用成本近似为零；真正的成本在「拿到歌词」那一步，已由 P 体现。
    let estimatedLatency: TimeInterval = 0.05
    let timeoutAction: CaptionTimeoutAction = .discard

    var onCandidates: (([CaptionCandidate]) -> Void)?
    var onCoverageChange: (() -> Void)?

    /// 没有歌词时不占预算：否则它会以 5 级身份把流式识别挤出链外，
    /// 而视频/会议恰恰只能靠流式识别出字。
    var isAvailable: Bool { !lines.isEmpty }

    private let generation: () -> Int
    /// 上次提交的签名。同一份歌词不重复灌入，避免无谓的候选洪泛。
    private var lastSignature: String = ""
    /// 保留一份最近提交的歌词，跳变重建调度器后需要按新代次重新灌入。
    private var lines: [LyricsManager.LrcLine] = []
    private var pipelineKey = "lrc.v1"

    init(generation: @escaping () -> Int) {
        self.generation = generation
    }

    func start() {}

    func stop() {
        lastSignature = ""
        lines = []
        onCoverageChange?()
    }

    /// 提交一份已对齐歌词。`signature` 用于判断是否同一份内容。
    func submit(_ newLines: [LyricsManager.LrcLine], signature: String) {
        guard !newLines.isEmpty else {
            clear()
            return
        }
        guard signature != lastSignature else { return }
        lastSignature = signature
        lines = newLines
        emit()
    }

    /// 时间轴重建（seek / 切源）后按当前代次重新灌入。
    /// 不重灌的话，旧代次的条目会被调度器当成迟到结果整体丢弃，歌词就此消失。
    func resubmit() {
        guard !lines.isEmpty else { return }
        emit()
    }

    func clear() {
        guard !lines.isEmpty || !lastSignature.isEmpty else { return }
        lines = []
        lastSignature = ""
        onCoverageChange?()
    }

    private func emit() {
        guard !lines.isEmpty else { return }
        let currentGeneration = generation()
        var candidates: [CaptionCandidate] = []
        candidates.reserveCapacity(lines.count)

        for (index, line) in lines.enumerated() {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let start = max(0, line.time)
            // 结束时刻取下一行的起点；最后一行没有下一行，给 4 秒展示窗口。
            let next = index + 1 < lines.count ? lines[index + 1].time : start + 4
            let end = max(start + 0.2, next)

            candidates.append(
                CaptionCandidate(
                    providerID: providerID,
                    level: level,
                    weight: weight,
                    start: start,
                    end: end,
                    text: text,
                    generation: currentGeneration,
                    pipelineKey: pipelineKey,
                    state: .stable
                )
            )
        }

        guard !candidates.isEmpty else { return }
        onCandidates?(candidates)
    }
}
