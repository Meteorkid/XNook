import AVFoundation
import Foundation
import Speech

/// 语音识别引擎路由器：默认走「多语言并行」，分析器起不来就自动回落稳定引擎。
///
/// 为什么需要这一层：`SpeechAnalyzer` 失败得很晚。它的语言模型资产首次使用时才下载，
/// 语言模块也可能被系统回收，而这些都要等到 `prepare()` 才会暴露——那时字幕链路已经装配完、
/// 音频也已经在流。把失败直接冒给 `CaptionManager` 只会把整条字幕标成「失败」，
/// 用户丢掉的是本来还能用的识别能力。
///
/// 于是「换一条路」被收进语音来源内部：对外始终是同一个 `SpeechEvidenceProviding`，
/// 对内先试分析器，失败就换成 `SFSpeechRecognizer`，并把换路原因报给 UI 与日志——
/// 否则用户以为自己在试新引擎，实际测到的却是旧引擎的延迟。
final class SpeechEngineRouter: SpeechEvidenceProviding, @unchecked Sendable {

    // MARK: - 契约字段

    /// 两套引擎的契约值完全一致（等级 1、流式、无需预取），因此这里直接给定值，
    /// 换路不会改变调度器眼里的它。
    let providerID = "speech.router"
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
    /// 引擎实际换路时回调，参数是可直接展示给用户的说明。
    var onEngineChanged: ((String) -> Void)?

    // MARK: - 内部状态

    private let lock = NSLock()
    private let clock: SourceClock
    private let generation: () -> Int
    private let locales: [Locale]

    private var active: any SpeechEvidenceProviding
    /// 当前活跃的是否为分析器。为 false 时说明这台机器只能用稳定引擎，
    /// 它的失败要原样上报，不能再「回落」一次。
    private let usesAnalyzer: Bool
    /// 换路时新建稳定引擎的方式。抽成闭包是为了让单测能在没有语音权限的环境里验证换路。
    private let fallbackFactory: (SourceClock, @escaping () -> Int) -> any SpeechEvidenceProviding
    private var isRunning = false
    private var didFallBack = false
    /// 换路后要补交给新引擎的语种线索。
    private var hintText = ""

    /// 分析器「起来了但一直不出结果」的兜底：超过这个时长仍然零候选就换路。
    /// 取 45 s，是因为实测首条结果在 1–3 s 内到达，这么久没动静只可能是真的哑了。
    private static let idleTimeout: TimeInterval = 45
    private var fedSeconds: TimeInterval = 0
    private var hasEmitted = false
    private var idleChecked = false

    private var initialNote: String?

    // MARK: - 构造

    /// - Parameters:
    ///   - primary: 首条通路。传 nil 由系统能力决定（macOS 26 起用分析器）。
    ///     单测可以传入会立刻失败的假实现，用来验证换路。
    ///   - fallbackFactory: 换路时新建稳定引擎的方式。默认就是真正的 `SpeechEvidenceProvider`。
    init(
        clock: SourceClock,
        generation: @escaping () -> Int,
        locales: [Locale],
        primary: (any SpeechEvidenceProviding)? = nil,
        fallbackFactory: ((SourceClock, @escaping () -> Int) -> any SpeechEvidenceProviding)? = nil
    ) {
        self.clock = clock
        self.generation = generation
        self.locales = locales
        self.fallbackFactory = fallbackFactory ?? { SpeechEvidenceProvider(clock: $0, generation: $1) }

        if let primary {
            self.active = primary
            self.usesAnalyzer = true
            self.initialNote = nil
            wire(primary, isPrimary: true)
            return
        }

        var primaryImpl: any SpeechEvidenceProviding
        var analyzer = false
        var note: String?

        if #available(macOS 26.0, *), SpeechTranscriber.isAvailable {
            primaryImpl = SpeechAnalyzerEvidenceProvider(
                clock: clock,
                generation: generation,
                locales: locales
            )
            analyzer = true
        } else {
            primaryImpl = SpeechEvidenceProvider(clock: clock, generation: generation)
            note = L10n.localized(
                zh: "这台 Mac 不支持多语言并行，已使用稳定引擎。",
                en: "Multilingual captions are unavailable on this Mac; using the stable engine."
            )
        }

        self.active = primaryImpl
        self.usesAnalyzer = analyzer
        self.initialNote = note
        wire(primaryImpl, isPrimary: true)
    }

    // MARK: - 生命周期

    func start() {
        lock.lock()
        guard !isRunning else {
            lock.unlock()
            return
        }
        isRunning = true
        fedSeconds = 0
        idleChecked = false
        let current = active
        let note = initialNote
        initialNote = nil
        lock.unlock()

        current.start()

        // 系统根本不支持时也要说一声，否则用户会以为切换生效了。
        if let note {
            onDiagnostics?("speech engine: stable (multilingual unsupported)")
            onEngineChanged?(note)
        }
    }

    func stop() {
        lock.lock()
        guard isRunning else {
            lock.unlock()
            return
        }
        isRunning = false
        let current = active
        lock.unlock()
        current.stop()
    }

    // MARK: - 音频与线索

    func append(buffer: AVAudioPCMBuffer, hostTime: TimeInterval) {
        lock.lock()
        guard isRunning else {
            lock.unlock()
            return
        }
        let current = active
        fedSeconds += Double(buffer.frameLength) / max(1, buffer.format.sampleRate)
        let stalled = !hasEmitted && !idleChecked && fedSeconds >= Self.idleTimeout
        if stalled { idleChecked = true }
        lock.unlock()

        current.append(buffer: buffer, hostTime: hostTime)

        if stalled {
            fallBack(reason: SpeechRouterError.noResultsWithinTimeout(Self.idleTimeout))
        }
    }

    func updateContentHint(_ text: String) {
        lock.lock()
        hintText = text
        let current = active
        lock.unlock()
        current.updateContentHint(text)
    }

    // MARK: - 换路

    private func wire(_ provider: any SpeechEvidenceProviding, isPrimary: Bool) {
        provider.onCandidates = { [weak self] candidates in
            guard let self else { return }
            self.lock.lock()
            self.hasEmitted = true
            self.lock.unlock()
            self.onCandidates?(candidates)
        }
        provider.onCoverageChange = { [weak self] in self?.onCoverageChange?() }
        provider.onDiagnostics = { [weak self] message in self?.onDiagnostics?(message) }
        provider.onFailure = { [weak self] error in
            guard let self else { return }
            // 只有「多语言分析器」的失败可以用换路解决；稳定引擎自己失败就是真失败。
            if isPrimary, self.usesAnalyzer {
                self.fallBack(reason: error)
            } else {
                self.onFailure?(error)
            }
        }
    }

    /// 切换到稳定引擎。只执行一次；之后任何失败都按真实失败上报。
    private func fallBack(reason: Error?) {
        lock.lock()
        guard !didFallBack, usesAnalyzer else {
            lock.unlock()
            return
        }
        didFallBack = true
        let running = isRunning
        let hint = hintText
        let previous = active
        lock.unlock()

        let stable = fallbackFactory(clock, generation)
        wire(stable, isPrimary: false)
        if !hint.isEmpty { stable.updateContentHint(hint) }

        lock.lock()
        active = stable
        hasEmitted = false
        fedSeconds = 0
        lock.unlock()

        // 失败的那一路要停掉，否则它的分析器还在等一个永远不会来的输入。
        previous.stop()

        let detail = reason?.localizedDescription ?? "unknown"
        onDiagnostics?("analyzer fallback -> speech.streaming (\(detail))")
        onEngineChanged?(
            L10n.localized(
                zh: "多语言并行未能启动，已自动切换到稳定引擎。",
                en: "Multilingual captions did not start; switched to the stable engine automatically."
            )
        )
        if running { stable.start() }
    }
}

/// 路由器自己的错误类型。
///
/// 不放进 `SpeechAnalyzerError`：那个类型带 `@available(macOS 26.0, *)`，
/// 而「分析器有动静但不出结果」这条路在旧系统上也要能被描述。
enum SpeechRouterError: LocalizedError {
    case noResultsWithinTimeout(TimeInterval)

    var errorDescription: String? {
        switch self {
        case .noResultsWithinTimeout(let seconds):
            L10n.localized(
                zh: "语音分析器 \(Int(seconds)) 秒内没有产出任何结果。",
                en: "The speech analyzer produced no result within \(Int(seconds)) seconds."
            )
        }
    }
}
