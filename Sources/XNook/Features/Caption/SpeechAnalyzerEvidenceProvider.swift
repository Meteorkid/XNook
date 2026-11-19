import AVFoundation
import Foundation
import Speech

/// macOS 26 起的语音识别通路，基于 `SpeechAnalyzer` + 多个 `SpeechTranscriber`。
///
/// 与旧通路（`SFSpeechRecognizer`）的关键差别：
/// - **没有单会话时长上限**：旧引擎约一分钟要换会话，换会话就换时间原点，迟到分段只能丢弃；
///   这里一个分析器可以一直跑，时间轴连续。
/// - **可以同时挂多种语言的模块**：中英各一个 transcriber，两路结果按脚本归属合并
///   （见 `SpeechModuleTextMerger`），解决「中文系统放英文内容」只能二选一的问题。
/// - 输入必须先转成 `bestAvailableAudioFormat`（实测 16 kHz / Int16 / 单声道），
///   直接喂 ScreenCaptureKit 的 48 kHz Float32 会让分析器直接崩（SIGTRAP）。
@available(macOS 26.0, *)
final class SpeechAnalyzerEvidenceProvider: SpeechEvidenceProviding, @unchecked Sendable {

    // MARK: - 契约字段

    let providerID = "speech.analyzer"
    let level: EvidenceLevel = .streaming
    let prefetchRequired = false
    let allowsAsync = true
    let isSlow = false
    var weight: Double = 0.45
    let estimatedLatency: TimeInterval = 0.35
    let timeoutAction: CaptionTimeoutAction = .fallbackStreaming

    // MARK: - 回调

    var onCandidates: (([CaptionCandidate]) -> Void)?
    var onCoverageChange: (() -> Void)?
    var onFailure: ((Error) -> Void)?
    var onDiagnostics: ((String) -> Void)?

    // MARK: - 内部状态

    private let queue = DispatchQueue(label: "com.meteorkid.xnook.caption.analyzer", qos: .userInitiated)
    private let clock: SourceClock
    private let generation: () -> Int
    private let locales: [Locale]

    private var analyzer: SpeechAnalyzer?
    private var modules: [SpeechTranscriber] = []
    private var prepareTask: Task<Void, Never>?
    private var streamContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultTasks: [Task<Void, Never>] = []
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var isRunning = false
    private var hasFailed = false

    /// 分析器时间轴的零点对应的源时间。分析器的时间轴从 0 开始，两者相加即为源时间。
    ///
    /// 不能只在首帧算一次：播放器位置对齐（`SourceClock.align`）会重锚整条源时间轴，
    /// 此后旧的零点会让每条结果都落在几百秒之前，被调度器的已读保护整批丢弃——
    /// 现象就是「分析器一直在出结果，字幕一条都不显示」。
    private var originSource: TimeInterval = 0
    /// originSource 是按哪一代时间轴算出来的。
    private var originGeneration = 0
    /// 最近一次送入分析器的音频对应的宿主时刻，以及那一刻分析器时间轴的位置。
    private var lastFedHost: TimeInterval = 0
    private var lastFedAnalyzerSeconds: TimeInterval = 0
    /// 已送入分析器的采样数，用于给每个 buffer 标注起始时刻。
    private var fedFrames: AVAudioFramePosition = 0
    private var lastEmitted: Set<String> = []
    /// 同一区间的多语言结果暂存在这里，等合并后再产出。
    private var pending: [String: [SpeechModuleTextMerger.Entry]] = [:]
    private var pipelineKey = "speech.analyzer.v1"

    /// 端到端延迟样本：从「这段音频说完」到「结果送达」的秒数。
    /// 与旧通路同口径，否则两套引擎没法直接对比。
    private var latencySamples: [TimeInterval] = []
    private var finalLatencySamples: [TimeInterval] = []
    private var lastLatencyReport: TimeInterval = 0
    private var firstResultLogged = false
    /// 已处理的结果条数与上次「喂入/产出」上报时刻。
    private var handledResults = 0
    private var lastFedReport: TimeInterval = 0

    private let hintLock = NSLock()
    private var contentHintText = ""

    init(clock: SourceClock, generation: @escaping () -> Int, locales: [Locale]) {
        self.clock = clock
        self.generation = generation
        self.locales = locales
    }

    // MARK: - 生命周期

    func start() {
        guard !isRunning else { return }
        isRunning = true
        // 留住任务句柄：stop() 要能取消它，否则失败的 prepare 会在取消后继续把
        // 分析器接上一条已经 finish 的输入流，留下一个永远等不到数据的任务。
        prepareTask = Task { [weak self] in await self?.prepare() }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        prepareTask?.cancel()
        prepareTask = nil
        streamContinuation?.finish()
        streamContinuation = nil
        resultTasks.forEach { $0.cancel() }
        resultTasks.removeAll()
        let analyzer = self.analyzer
        self.analyzer = nil
        Task { try? await analyzer?.finalizeAndFinishThroughEndOfInput() }
    }

    private func prepare() async {
        guard SpeechTranscriber.isAvailable else {
            hasFailed = true
            onFailure?(SpeechAnalyzerError.engineUnavailable)
            return
        }

        let modules = locales.map { locale in
            SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults, .fastResults],
                attributeOptions: [.audioTimeRange]
            )
        }
        self.modules = modules

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
            guard isRunning else { return }
            hasFailed = true
            onFailure?(SpeechAnalyzerError.noCompatibleFormat)
            return
        }
        guard isRunning else { return }
        targetFormat = format

        let analyzer = SpeechAnalyzer(modules: modules)
        do {
            try await analyzer.prepareToAnalyze(in: format)
        } catch {
            guard isRunning else { return }
            hasFailed = true
            onFailure?(SpeechAnalyzerError.prepareFailed(error.localizedDescription))
            return
        }
        guard isRunning else { return }
        self.analyzer = analyzer

        for (index, module) in modules.enumerated() {
            let locale = locales[index].identifier
            resultTasks.append(Task { [weak self] in
                guard let self else { return }
                do {
                    for try await result in module.results {
                        self.handle(result: result, locale: locale)
                    }
                } catch {
                    guard self.isRunning else { return }
                    self.onDiagnostics?("analyzer results error(\(locale)): \(error.localizedDescription)")
                }
            })
        }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        streamContinuation = continuation
        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            guard isRunning else { return }
            hasFailed = true
            onFailure?(SpeechAnalyzerError.prepareFailed(error.localizedDescription))
            return
        }
        guard isRunning else { return }
        pipelineKey = "speech.analyzer.v1.\(locales.map(\.identifier).joined(separator: "+"))"
        let moduleCount = await analyzer.modules.count
        onDiagnostics?(
            "analyzer ready locales=\(locales.map(\.identifier)) "
            + "format=\(format.sampleRate)Hz/\(format.channelCount)ch modules=\(moduleCount)"
        )
    }

    // MARK: - 音频输入

    func updateContentHint(_ text: String) {
        hintLock.lock()
        contentHintText = text
        hintLock.unlock()
    }

    private var contentHintSnapshot: String {
        hintLock.lock()
        defer { hintLock.unlock() }
        return contentHintText
    }

    func append(buffer: AVAudioPCMBuffer, hostTime: TimeInterval) {
        guard isRunning, buffer.frameLength > 0 else { return }
        queue.async { [weak self] in
            guard let self, self.isRunning else { return }
            self.enqueue(buffer: buffer, hostTime: hostTime)
        }
    }

    private func enqueue(buffer: AVAudioPCMBuffer, hostTime: TimeInterval) {
        guard let targetFormat, let continuation = streamContinuation else { return }

        if converter == nil {
            guard let created = AVAudioConverter(from: buffer.format, to: targetFormat) else {
                hasFailed = true
                onFailure?(SpeechAnalyzerError.noCompatibleFormat)
                return
            }
            // 不做预滚：实时流里预滚只会把开头几个 buffer 吞掉。
            created.primeMethod = .none
            converter = created
        }
        guard let converter else { return }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 512
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, state in
            if supplied {
                state.pointee = .noDataNow
                return nil
            }
            supplied = true
            state.pointee = .haveData
            return buffer
        }
        if status == .error, let conversionError {
            onDiagnostics?("analyzer convert error: \(conversionError.localizedDescription)")
            return
        }
        guard output.frameLength > 0 else { return }

        let startTime = CMTime(value: fedFrames, timescale: CMTimeScale(targetFormat.sampleRate))
        continuation.yield(AnalyzerInput(buffer: output, bufferStartTime: startTime))
        fedFrames += AVAudioFramePosition(output.frameLength)
        lastFedHost = hostTime
        lastFedAnalyzerSeconds = Double(fedFrames) / max(1, targetFormat.sampleRate)
        refreshOriginIfNeeded()

        // 每 20 秒报一次「喂了多少、出了多少」：两者都为零说明音频没进来，
        // 喂了却没出才是分析器本身的问题。这两种情况在现象上都是「字幕没反应」。
        let now = SourceClock.hostNow()
        if lastFedReport == 0 {
            lastFedReport = now
        } else if now - lastFedReport > 20 {
            lastFedReport = now
            let seconds = Double(fedFrames) / max(1, targetFormat.sampleRate)
            onDiagnostics?(
                String(format: "analyzer fed=%.1fs results=%d", seconds, handledResults)
            )
        }
    }

    // MARK: - 结果

    /// 时间轴重锚后重新计算零点。
    ///
    /// 用「最近一帧的宿主时刻 − 它对应的分析器时间」反推零点，
    /// 这样不论重锚发生在第几帧，映射关系都是当前这一代时间轴的。
    private func refreshOriginIfNeeded() {
        let generation = clock.generation
        guard generation != originGeneration, lastFedHost > 0 else { return }
        originGeneration = generation
        originSource = clock.sourceTime(atHost: lastFedHost) - lastFedAnalyzerSeconds
    }

    private func handle(result: SpeechTranscriber.Result, locale: String) {
        handledResults += 1
        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, lastFedHost > 0 else { return }
        // 模块吐出与自身语言不符的文本，基本是把外语音素硬套成母语拼写的乱码：
        // 中文模块读英文歌会产出「Bavemens even if felese」这类字符串。
        // 直接丢掉，比让它和另一路的结果比长度更可靠。
        guard SpeechModuleTextMerger.scriptMatches(locale: locale, text: text) else { return }
        refreshOriginIfNeeded()

        let start = originSource + result.range.start.seconds
        let end = max(start + 0.12, originSource + result.range.end.seconds)
        let key = "\(Int((start * 10).rounded()))|\(Int((end * 10).rounded()))"

        var entries = pending[key] ?? []
        entries.removeAll { $0.locale == locale }
        entries.append(.init(locale: locale, text: text, isFinal: result.isFinal))
        pending[key] = entries
        // 区间只保留最近一小段，避免长时间运行后无限增长。
        if pending.count > 64 { pending.removeAll(keepingCapacity: true) }

        guard let chosen = SpeechModuleTextMerger.preferred(from: entries) else { return }
        let fingerprint = "\(key)|\(chosen.text)"
        guard !lastEmitted.contains(fingerprint) else { return }
        lastEmitted.insert(fingerprint)
        if lastEmitted.count > 2000 { lastEmitted.removeAll(keepingCapacity: true) }

        let candidate = CaptionCandidate(
            providerID: providerID,
            level: level,
            weight: weight,
            start: start,
            end: end,
            text: chosen.text,
            generation: generation(),
            pipelineKey: pipelineKey,
            state: chosen.isFinal ? .stable : .volatile
        )
        onCandidates?([candidate])
        recordLatency(end: end, isFinal: chosen.isFinal)
    }

    /// 记录「这段音频说完 → 结果到手」的延迟。
    ///
    /// 口径与旧通路一致（`arrival - 段落结束时刻`），否则换引擎后的数字不可比。
    /// 全量样本和已稳定样本分开统计：易变结果来得早但会被改写，只报全量会让人误判成「变快了」。
    private func recordLatency(end: TimeInterval, isFinal: Bool) {
        let arrival = clock.sourceNow()
        // 易变结果的区间右端常常略晚于到达时刻，负值不是错误，按 0.02 s 记。
        let latency = max(0.02, arrival - end)
        guard latency.isFinite, latency < 60 else { return }

        if !firstResultLogged {
            firstResultLogged = true
            onDiagnostics?(String(format: "analyzer first result %.2fs", latency))
        }

        latencySamples.append(latency)
        if latencySamples.count > 400 { latencySamples.removeFirst(latencySamples.count - 400) }
        if isFinal {
            finalLatencySamples.append(latency)
            if finalLatencySamples.count > 400 {
                finalLatencySamples.removeFirst(finalLatencySamples.count - 400)
            }
        }

        let now = SourceClock.hostNow()
        guard lastLatencyReport == 0 || now - lastLatencyReport > 5 else { return }
        lastLatencyReport = now

        let average = latencySamples.reduce(0, +) / Double(latencySamples.count)
        let worst = latencySamples.max() ?? 0
        onDiagnostics?(
            String(format: "analyzer latency avg=%.2fs max=%.2fs n=%d", average, worst, latencySamples.count)
        )
        if !finalLatencySamples.isEmpty {
            let finalAverage = finalLatencySamples.reduce(0, +) / Double(finalLatencySamples.count)
            let finalWorst = finalLatencySamples.max() ?? 0
            onDiagnostics?(
                String(
                    format: "analyzer final latency avg=%.2fs max=%.2fs n=%d",
                    finalAverage, finalWorst, finalLatencySamples.count
                )
            )
        }
    }
}

@available(macOS 26.0, *)
enum SpeechAnalyzerError: LocalizedError {
    case engineUnavailable
    case noCompatibleFormat
    case prepareFailed(String)

    var errorDescription: String? {
        switch self {
        case .engineUnavailable:
            L10n.localized(zh: "系统语音分析引擎不可用。", en: "The system speech analyzer is unavailable.")
        case .noCompatibleFormat:
            L10n.localized(zh: "没有与语音分析器兼容的音频格式。", en: "No audio format compatible with the speech analyzer.")
        case .prepareFailed(let message):
            L10n.localized(zh: "语音分析器启动失败：\(message)", en: "Speech analyzer failed to start: \(message)")
        }
    }
}
