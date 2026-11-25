import Foundation

/// 画面文字作为证据提供者（证据等级 3，`frameText`）。
///
/// 它是整条链里**唯一按区间执行、且真的可以被跳过**的来源：
/// - 每个时间区间最多抓一帧、跑一次 OCR，成本明确（约 0.25 s）；
/// - 区间已被更高等级证据（歌词）覆盖且证书成立时，这个区间直接不执行，
///   省下的是真实的捕获 + 推理开销，而不是一句注释。
///
/// 这也是「什么时候可以不算了」在工程上唯一能兑现的地方：
/// 流式识别是连续音频，按区间跳过就再也接不上；只有按区间取数的来源才谈得上跳过。
@MainActor
final class FrameTextEvidenceProvider: @preconcurrency CaptionEvidenceProvider {

    let providerID = "frame.ocr"
    let level: EvidenceLevel = .frameText
    /// 读的是当前画面，不需要播放前沿之后的内容。
    let prefetchRequired = false
    let allowsAsync = true
    let isSlow = false
    var weight: Double = 0.70
    let estimatedLatency: TimeInterval = 0.25
    let timeoutAction: CaptionTimeoutAction = .degradeNext

    var onCandidates: (([CaptionCandidate]) -> Void)?
    var onCoverageChange: (() -> Void)?
    var onDiagnostics: ((String) -> Void)?

    /// 执行闸门。由装配层注入，内部去问调度器的 `shouldExecute` 与 `isShortCircuited`。
    /// 返回 false 表示「这个区间不需要再做画面识别」——这就是短路。
    var runGate: ((Int) -> Bool)?

    private(set) var executedIntervals = 0
    private(set) var skippedIntervals = 0

    /// 区间开始后多久抓帧：字幕通常比画面切换晚一点出现，太早抓到的是上一句。
    private let captureDelay: TimeInterval = 0.5
    /// 连续失败几次后停手，避免权限被撤或显示器休眠时空转。
    private let failureLimit = 3

    private let clock: SourceClock
    private var isRunning = false
    private var lastRequestedInterval = -1
    private var inFlight = false
    private var consecutiveFailures = 0
    private var lastText = ""
    /// 会话代次：start/stop/reset 时递增，用于作废仍在执行中的 OCR 结果。
    private var sessionEpoch = 0
    /// 上一次是否因「屏幕上没有全屏画面」而跳过，用于只记录状态变化。
    private var gateRefused = false

    init(clock: SourceClock) {
        self.clock = clock
    }

    var isEnabled: Bool { isRunning }

    func start() {
        sessionEpoch &+= 1
        isRunning = true
        inFlight = false
        lastRequestedInterval = -1
    }

    func stop() {
        sessionEpoch &+= 1
        isRunning = false
        inFlight = false
        lastRequestedInterval = -1
    }

    /// 时间轴重建后重新遍历区间。
    func reset() {
        // 作废已发出的 OCR：它抓到的是旧时间轴上的帧，完成时算出的时间戳可能落在负区间。
        sessionEpoch &+= 1
        // 旧任务已被作废，闸门不能继续认为“有一帧在识别”，否则新时间轴永远排不上。
        inFlight = false
        lastRequestedInterval = -1
        lastText = ""
    }

    /// 每个调度周期调用。只为「新进入的区间」执行一次。
    func advance(now: TimeInterval, unit: TimeInterval) {
        guard isRunning, consecutiveFailures < failureLimit, unit > 0 else { return }

        let index = CaptionInterval.index(for: now, unit: unit)
        let intervalStart = Double(index) * unit
        // 太早抓帧会读到上一句字幕，等半秒再抓。
        guard now - intervalStart >= captureDelay else { return }
        guard index != lastRequestedInterval else { return }

        // 屏幕闸门先于一切：没有全屏视频时，底部三成读到的是用户正在写的文档、浏览器的正文，
        // 那不是字幕。等级 3 会直接压过语音（1），屏幕上就会长期挂着与音频无关的文字。
        guard ScreenTextRecognizer.isSubtitleLikelyOnScreen() else {
            lastRequestedInterval = index
            skippedIntervals += 1
            if !gateRefused {
                gateRefused = true
                onDiagnostics?("ocr idle: 屏幕最前置窗口未铺满，跳过画面文字")
            }
            return
        }
        if gateRefused {
            gateRefused = false
            onDiagnostics?("ocr resume: 检测到全屏画面")
        }

        // 短路判定：证书成立就不执行，连闸门后面的捕获都不发生。
        if let runGate, !runGate(index) {
            lastRequestedInterval = index
            skippedIntervals += 1
            onDiagnostics?("ocr skip interval=\(index) skipped=\(skippedIntervals) executed=\(executedIntervals)")
            return
        }

        // 上一帧还在识别中：不排队，等下一拍重试同一区间。
        guard !inFlight else { return }

        lastRequestedInterval = index
        inFlight = true
        executedIntervals += 1
        runInterval(index: index, unit: unit)
    }

    private func runInterval(index: Int, unit: TimeInterval) {
        let captureHost = SourceClock.hostNow()
        let epoch = sessionEpoch
        let generation = clock.generation
        Task { [weak self] in
            var text: String?
            var failure: String?
            do {
                text = try await ScreenTextRecognizer.recognizeSubtitle()
            } catch {
                failure = error.localizedDescription
            }
            self?.finish(
                index: index,
                unit: unit,
                captureHost: captureHost,
                epoch: epoch,
                generation: generation,
                text: text,
                failure: failure
            )
        }
    }

    private func finish(
        index: Int,
        unit: TimeInterval,
        captureHost: TimeInterval,
        epoch: Int,
        generation: Int,
        text: String?,
        failure: String?
    ) {
        // 会话已重置/停止：这次 OCR 读到的是旧时间轴上的画面，必须整体丢弃。
        guard epoch == sessionEpoch else { return }
        inFlight = false

        if let failure {
            consecutiveFailures += 1
            onDiagnostics?("ocr failure(\(consecutiveFailures)) \(failure)")
            return
        }
        consecutiveFailures = 0

        guard let text, !text.isEmpty else { return }
        // 时间轴本身已重建：即便 provider 没有收到 reset，也不能用新代次去解释旧抓帧时刻。
        guard generation == clock.generation else { return }

        let start = clock.sourceTime(atHost: captureHost)
        let end = start + unit
        // 同一句字幕会在多个区间被重复读到，这里不去重丢弃——
        // 每个区间都需要自己的候选来维持覆盖率，去重只会让后面的区间空着。
        if text != lastText {
            lastText = text
            onDiagnostics?("ocr line interval=\(index) \(text)")
        }
        // 注意：这里不能触发 onCoverageChange。
        // 那个回调的语义是「覆盖范围收缩，需要重判证书」，而新证据到达是覆盖增加；
        // 每次产出都去失效证书，短路就永远不会存活。
        onCandidates?([
            CaptionCandidate(
                providerID: providerID,
                level: level,
                weight: weight,
                start: start,
                end: end,
                text: text,
                generation: clock.generation,
                pipelineKey: "ocr.v1.zh-Hans",
                state: .volatile
            )
        ])
    }
}
