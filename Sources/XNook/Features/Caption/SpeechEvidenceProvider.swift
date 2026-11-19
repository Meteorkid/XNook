import AVFoundation
import Foundation
import Speech

/// 流式语音识别证据提供者（证据等级 1，兜底来源）。
///
/// 契约要点（对应权 1 第二段）：
/// - `prefetchRequired = false`：不需要播放前沿之后的音频，因此音源不可预取时它仍然可用；
/// - `allowsAsync = true`：结果可以晚于首帧时限到达，由调度器写入未读后续区间；
/// - `isSlow = false`：不参与播放前的前移执行。
///
/// 识别引擎用系统内置的本地识别（`requiresOnDeviceRecognition`），不联网、无模型下载。
/// 单次识别请求有约一分钟的时长上限，这里按 50 s 主动换会话，并把新会话的音频起点作为新的时间原点——
/// 时间原点一换，旧会话的迟到分段就会被代次标识过滤掉（对应权 6 的迟到结果丢弃）。
final class SpeechEvidenceProvider: NSObject, SpeechEvidenceProviding, @unchecked Sendable {

    // MARK: - 契约字段

    let providerID = "speech.streaming"
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
    /// 识别链路自身的问题（权限、引擎不可用），交给上层提示，不影响调度器。
    var onFailure: ((Error) -> Void)?
    /// 引擎模式与实测延迟。识别走本地还是 Apple 服务器、究竟慢多少，只有这里能给出真值。
    var onDiagnostics: ((String) -> Void)?

    // MARK: - 内部状态

    enum SpeechError: LocalizedError {
        case notAuthorized
        case localeUnsupported
        case engineUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return L10n.localized(zh: "未获得「语音识别」权限，实时字幕无法工作。",
                                      en: "Speech Recognition permission is required for live captions.")
            case .localeUnsupported:
                return L10n.localized(zh: "当前语言的本地语音识别不可用。",
                                      en: "On-device speech recognition is unavailable for the current language.")
            case .engineUnavailable(let message):
                return message
            }
        }
    }

    private let queue = DispatchQueue(label: "com.meteorkid.xnook.caption.speech", qos: .userInitiated)
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var isRunning = false

    /// 当前会话第一帧音频的宿主时刻，作为该会话分段相对时间戳的原点。
    private var sessionOriginHost: TimeInterval = 0
    private var sessionStartedAt: TimeInterval = 0
    /// 单会话时长上限（秒）。
    private let sessionLimit: TimeInterval = 50
    /// 上一次已产出的分段指纹，用于抑制累计结果里的重复分段。
    private var lastEmitted: Set<String> = []
    /// 会话编号。换会话后旧任务的迟到回调必须被丢弃，否则会用新会话的原点去解释旧时间戳。
    private var sessionID: Int = 0
    /// 端到端延迟样本：从「这段音频说完」到「识别结果送达」的秒数。
    private var latencySamples: [TimeInterval] = []
    private var lastLatencyReport: TimeInterval = 0
    /// 管线标识：语言 + 引擎版本。变化即缓存键失效。
    private(set) var pipelineKey: String = "speech.v1"

    private let clock: SourceClock
    private let generation: () -> Int

    /// 内容语种线索（当前歌词或刚出的字幕行）。由主线程写入、识别队列读取，用锁隔开。
    private let hintLock = NSLock()
    private var contentHintText = ""
    /// 上次检查语言是否变化的时刻，避免每帧都解析一次。
    private var lastLanguageCheck: TimeInterval = 0
    /// 换语言的滞后判据，防止语种线索抖动导致会话反复重建。
    private var languageGuard = CaptionLanguageSwitchGuard()

    /// 供上层（主线程）更新语种线索。
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

    init(clock: SourceClock, generation: @escaping () -> Int) {
        self.clock = clock
        self.generation = generation
        super.init()
    }

    // MARK: - 生命周期

    func start() {
        guard !isRunning else { return }
        isRunning = true
        queue.async { [weak self] in
            self?.beginAfterAuthorization()
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        queue.async { [weak self] in
            self?.teardownSession()
        }
    }

    /// 权限申请 + 建立首个会话。整个流程在私有队列上串行执行，避免与音频帧回调竞争。
    private func beginAfterAuthorization() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            guard let self else { return }
            guard status == .authorized else {
                self.isRunning = false
                self.onFailure?(SpeechError.notAuthorized)
                return
            }
            self.queue.async { self.beginSession() }
        }
    }

    private func currentLocale() -> Locale {
        CaptionLanguageResolver.resolve(
            preference: CaptionRecognitionLanguage.current,
            contentHint: contentHintSnapshot,
            systemLanguage: Locale.preferredLanguages.first ?? "en-US"
        )
    }

    /// 语言选项或内容语种变化时是否要换会话。每 2 秒最多解析一次。
    ///
    /// 换语言要过 `CaptionLanguageSwitchGuard`：同一目标连续成立才换。
    /// 这里曾经直接比较 locale，结果 OCR 读到的桌面中文与歌词里的西文交替喂进线索，
    /// 识别会话每 2–4 秒重建一次，识别结果永远追不上音频。
    private func shouldRestartForLanguageChange() -> Bool {
        let now = SourceClock.hostNow()
        guard now - lastLanguageCheck > 2 else { return false }
        lastLanguageCheck = now
        guard let recognizer else { return false }
        return languageGuard.shouldSwitch(
            to: currentLocale().identifier,
            from: recognizer.locale.identifier,
            now: now
        )
    }

    private func beginSession() {
        guard isRunning else { return }

        teardownSession()

        let locale = currentLocale()
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            isRunning = false
            onFailure?(SpeechError.localeUnsupported)
            return
        }
        self.recognizer = recognizer
        lastLanguageCheck = SourceClock.hostNow()

        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.shouldReportPartialResults = true
        // 本地识别优先：不联网、延迟稳定，且不把用户音频送出本机。
        if recognizer.supportsOnDeviceRecognition {
            newRequest.requiresOnDeviceRecognition = true
        }
        if #available(macOS 13.0, *) {
            newRequest.addsPunctuation = true
        }
        request = newRequest
        sessionOriginHost = 0
        sessionStartedAt = SourceClock.hostNow()
        languageGuard.sessionStarted(at: sessionStartedAt)
        lastEmitted.removeAll(keepingCapacity: true)
        pipelineKey = "speech.v1.\(locale.identifier).\(recognizer.supportsOnDeviceRecognition ? "ondevice" : "server")"
        let currentSession = sessionID

        // 这条日志是「要不要联网」的唯一可信答案：ondevice=true 表示音频不出本机。
        onDiagnostics?(
            "session locale=\(locale.identifier) ondevice=\(recognizer.supportsOnDeviceRecognition) "
            + "available=\(recognizer.isAvailable)"
        )

        task = recognizer.recognitionTask(with: newRequest) { [weak self] result, error in
            guard let self else { return }
            // 识别回调不保证落在哪个队列，而下面的状态（会话原点、去重集合、请求对象）
            // 全部由 queue 独占，因此统一回到 queue 上再处理，避免数据竞争。
            self.queue.async { self.handle(result: result, error: error, session: currentSession) }
        }
    }

    private func teardownSession() {
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        sessionOriginHost = 0
        // 递增会话编号：已取消任务的回调可能仍在路上，编号不一致即丢弃。
        sessionID &+= 1
    }

    // MARK: - 音频入口

    /// 送入一帧音频。由 `SystemAudioTap` 在音频队列上调用。
    func append(buffer: AVAudioPCMBuffer, hostTime: TimeInterval) {
        queue.async { [weak self] in
            guard let self, self.isRunning else { return }

            if self.sessionOriginHost == 0 {
                self.sessionOriginHost = hostTime
            }

            // 单会话超过上限即换会话：旧会话的音频已经送完，新会话以当前帧为新原点。
            if SourceClock.hostNow() - self.sessionStartedAt > self.sessionLimit {
                self.beginSession()
                if self.sessionOriginHost == 0 { self.sessionOriginHost = hostTime }
            } else if self.shouldRestartForLanguageChange() {
                // 用户改了语言选项，或内容语种变了：立刻换会话，不必等 50 秒会话到期。
                self.beginSession()
                if self.sessionOriginHost == 0 { self.sessionOriginHost = hostTime }
            }

            self.request?.append(buffer)
        }
    }

    // MARK: - 识别结果

    private func handle(result: SFSpeechRecognitionResult?, error: Error?, session: Int) {
        // 换会话后旧任务的回调：时间戳属于旧原点，直接丢弃。
        guard session == sessionID else { return }
        if let error {
            // 1110：无语音；203/216：会话到期或被取消。这些都不是致命错误，换会话继续。
            let code = (error as NSError).code
            if ![1110, 203, 216, 1101].contains(code) {
                onFailure?(SpeechError.engineUnavailable(error.localizedDescription))
            }
            queue.async { [weak self] in
                guard let self, self.isRunning else { return }
                self.beginSession()
            }
            return
        }

        guard let result else { return }
        let origin = sessionOriginHost
        guard origin > 0 else { return }

        let currentGeneration = generation()
        let isFinal = result.isFinal
        var produced: [CaptionCandidate] = []

        for segment in result.bestTranscription.segments {
            let text = segment.substring.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let start = originToSource(origin: origin, offset: segment.timestamp)
            let end = start + max(0.12, segment.duration)
            let fingerprint = "\(Int((start * 10).rounded()))|\(Int((end * 10).rounded()))|\(text)"
            if lastEmitted.contains(fingerprint) { continue }
            lastEmitted.insert(fingerprint)

            produced.append(
                CaptionCandidate(
                    providerID: providerID,
                    level: level,
                    weight: weight,
                    start: start,
                    end: end,
                    text: text,
                    generation: currentGeneration,
                    pipelineKey: pipelineKey,
                    state: isFinal ? .stable : .volatile
                )
            )
        }

        guard !produced.isEmpty else { return }
        onCandidates?(produced)

        recordLatency(arrival: SourceClock.hostNow(), origin: origin, segments: result.bestTranscription.segments)
    }

    /// 记录「音频说完 → 结果到手」的延迟。这是用户真正体感的那一段，与调度器无关。
    /// 每 5 秒汇总一次，避免日志被逐条结果刷爆。
    private func recordLatency(arrival: TimeInterval, origin: TimeInterval, segments: [SFTranscriptionSegment]) {
        guard let last = segments.last else { return }
        let segmentEndHost = origin + last.timestamp + max(0.12, last.duration)
        let latency = arrival - segmentEndHost
        guard latency.isFinite, latency >= 0, latency < 30 else { return }

        latencySamples.append(latency)
        if latencySamples.count > 200 { latencySamples.removeFirst(latencySamples.count - 200) }

        let now = SourceClock.hostNow()
        guard lastLatencyReport == 0 || now - lastLatencyReport > 5 else { return }
        lastLatencyReport = now

        let average = latencySamples.reduce(0, +) / Double(latencySamples.count)
        let worst = latencySamples.max() ?? 0
        onDiagnostics?(
            String(format: "latency avg=%.2fs max=%.2fs n=%d", average, worst, latencySamples.count)
        )
    }

    /// 把识别器给出的「相对会话起点」时间戳换算为绝对源时间戳。
    /// 这里不做任何以当前窗口为原点的换算——原点固定在会话首帧，因此同一分段即使被反复上报，
    /// 其绝对源时间戳也保持不变，晚到证据才能被正确判定为「写入未读区间」而不是「整体右移」。
    private func originToSource(origin: TimeInterval, offset: TimeInterval) -> TimeInterval {
        clock.sourceTime(atHost: origin + offset)
    }
}
