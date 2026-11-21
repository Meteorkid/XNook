import AVFoundation
import Foundation
import Observation
import Speech

/// 实时字幕的装配层：把系统音频捕获、证据提供者、调度器与 UI 串起来。
///
/// 这一层只做三件事：启停、每 60 ms 驱动一次调度周期、把当前字幕行暴露给 UI。
/// 所有判定逻辑都在 `CaptionScheduler` 里，便于单元测试与后续替换识别引擎。
@Observable
@MainActor
final class CaptionManager {

    enum State: Equatable {
        case idle
        case starting
        case running
        case failed(String)

        var isRunning: Bool { self == .running }
    }

    /// 系统音频捕获是进程级独占资源：多处同时持有会重复建立 SCStream 并争抢同一路音频。
    /// 因此这里用共享实例，UI、设置页与生命周期钩子都指向同一份。
    static let shared = CaptionManager()

    // MARK: - 对外状态

    private(set) var state: State = .idle
    /// 当前应显示的字幕行。
    private(set) var line: String = ""
    /// 当前行的证据等级（低等级来源可用更淡的样式呈现）。
    private(set) var level: EvidenceLevel?
    /// 调度器诊断量，设置页用于排查。
    private(set) var chainLength: Int = 0
    private(set) var establishedCertificates: Int = 0
    /// 画面文字来源实际执行的区间数与因证书成立而跳过的区间数。
    /// 跳过的数字就是「什么时候可以不算了」省下来的真实推理次数。
    var frameExecutedIntervals: Int { frameProvider?.executedIntervals ?? 0 }
    var frameSkippedIntervals: Int { frameProvider?.skippedIntervals ?? 0 }

    /// 语音引擎的换路说明。非空表示「用户选了多语言并行，但实际跑的是稳定引擎」。
    /// 必须让用户看见：否则他以为在对比新引擎的延迟，其实量的是旧引擎。
    private(set) var speechEngineNote: String?

    // MARK: - 内部组件

    let clock = SourceClock()
    /// 首帧预算从设置读取。它是「承诺」而不是常数：调小会把更贵的来源裁出链外，
    /// 延迟上界随之收紧；调大则允许多个来源同时跑。
    let scheduler = CaptionScheduler(
        config: .init(deadlineBudget: CaptionManager.configuredBudget())
    )
    private var tap: SystemAudioTap?
    private var speech: (any SpeechEvidenceProviding)?
    private var lyricProvider: LyricEvidenceProvider?
    private var frameProvider: FrameTextEvidenceProvider?
    private var preTranscriptProvider: PreTranscriptProvider?
    private var tickTimer: Timer?
    private var logHandle: FileHandle?
    private var lastLoggedLine: String = ""
    /// 端到端延迟采样：音频区间右端 → 文字上屏的墙钟差。
    private var displayLagSamples: [TimeInterval] = []
    private var displayLagTotal = 0

    /// 启动前就已加载好的歌词：等捕获真正跑起来再灌入，避免白算一遍。
    private var pendingLyrics: [LyricsManager.LrcLine] = []
    private var pendingLyricsSignature: String = ""

    /// 播放器时间轴对齐的最小间隔。识别与调度都在主线程，没必要 20 Hz 去抢锁。
    private var lastAlignAt: TimeInterval = 0
    private static let minimumAlignInterval: TimeInterval = 0.5

    /// 播放是否处于暂停（时间轴已冻结）。反复收到同一状态时直接返回。
    private(set) var isPlaybackPaused = false

    /// 上一次记进日志的歌词条数，用来只在变化时记一行。
    private var lastLyricsCount = -1

    /// 判定为跳变（seek / 切源）的时刻，用于识别「播放器位置不可信」。
    private var jumpTimestamps: [TimeInterval] = []
    /// 播放器自报位置连续多次剧烈跳变时，放弃对齐、退回捕获时钟，
    /// 否则每次跳变都会清空调度器，字幕会反复消失。
    private(set) var usesPlayerTimeline = true

    /// 调度周期：60 ms。远小于 L_budget(300 ms)，保证「到点即取」不会因为轮询粒度而迟到。
    private let tickInterval: TimeInterval = 0.06
    /// 语种线索用的最近一行字幕。排除本地预转写自己的输出——它一旦用错语言，
    /// 产生的拉丁乱码会让线索自证成英文，然后一直错下去。
    private var languageHintLine = ""
    /// 音乐场景下歌词与元数据不需要音频前瞻，可预取度按高值处理；
    /// 系统音频捕获场景读不到播放前沿之后的音频，恒为 0。
    private var prefetchability: Double = 0

    var isRunning: Bool { state.isRunning }

    // MARK: - 生命周期

    func start() async {
        guard !state.isRunning, state != .starting else { return }
        state = .starting
        openLogIfNeeded()
        log("start requested")

        // 每次开捕都把时间轴零点归位，避免上一次会话残留的锚点让首帧时间戳落在过去。
        clock.resetToZero()
        scheduler.reset()
        usesPlayerTimeline = true
        jumpTimestamps.removeAll()
        lastAlignAt = 0

        let speechProvider = Self.makeSpeechProvider(clock: clock) { [weak clock] in
            clock?.generation ?? 1
        }
        speechEngineNote = nil
        if let router = speechProvider as? SpeechEngineRouter {
            router.onEngineChanged = { [weak self] note in
                Task { @MainActor in self?.speechEngineNote = note }
            }
        }
        speechProvider.onFailure = { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.log("speech failure: \(error.localizedDescription)")
                // 识别链路失败不一定意味着捕获失败，保留运行态但把原因抛给 UI。
                if case .failed = self.state { return }
                self.state = .failed(error.localizedDescription)
            }
        }

        speechProvider.onDiagnostics = { [weak self] message in
            Task { @MainActor in self?.log(message) }
        }

        let newTap = SystemAudioTap()
        newTap.onBuffer = { [weak speechProvider] buffer, host in
            speechProvider?.append(buffer: buffer, hostTime: host)
        }
        newTap.onDiagnostics = { [weak self] message in
            Task { @MainActor in self?.log(message) }
        }
        newTap.onError = { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.log("tap error: \(error.localizedDescription)")
                self.state = .failed(error.localizedDescription)
            }
        }

        let lyricEvidence = LyricEvidenceProvider { [weak clock] in
            clock?.generation ?? 1
        }

        let frameEvidence = FrameTextEvidenceProvider(clock: clock)
        frameEvidence.onDiagnostics = { [weak self] message in
            Task { @MainActor in self?.log(message) }
        }
        // 画面文字是链里唯一「按区间执行且可跳过」的来源：
        // 该区间已被不低于画面等级的候选覆盖时，连截图与 OCR 都不发生。
        frameEvidence.runGate = { [weak self, weak frameEvidence] index in
            guard let self, let frameEvidence else { return false }
            if self.scheduler.hasCoverage(unitIndex: index, atLeast: frameEvidence.level) { return false }
            // 回看历史区间时证书已成立，同样不再执行。
            if self.scheduler.isShortCircuited(frameEvidence, unitIndex: index) { return false }
            return self.scheduler.shouldExecute(
                frameEvidence,
                unitIndex: index,
                prefetchability: self.prefetchability
            )
        }

        scheduler.attach(clock: clock)
        scheduler.onLineChange = { [weak self] text, level in
            guard let self else { return }
            self.line = text
            self.level = level
            // 语种线索只认歌词（等级 5）。画面文字与语音自己的输出都不能当线索：
            // OCR 读的是用户桌面上的中文，语音输出本身又是由当前语言决定的——
            // 拿它们当线索会让「自动」在中英之间来回跳，识别会话随之反复重建。
            if !text.isEmpty, level == .alignedFullText,
               CaptionRecognitionLanguage.current == .automatic {
                self.speech?.updateContentHint(text)
            }
            if !text.isEmpty, text != self.lastLoggedLine {
                self.lastLoggedLine = text
                self.log("line[\(level?.rawValue ?? 0)] \(text)")
            }
            if let level, level != .localCache, !text.isEmpty {
                self.languageHintLine = text
            }
            self.recordDisplayLag()
        }

        let quickTimeLocator = QuickTimeMediaLocator()
        quickTimeLocator.onDiagnostics = { [weak self] message in
            Task { @MainActor in self?.log(message) }
        }
        let preTranscriptEvidence: PreTranscriptProvider? = PreTranscriptSettings.isEnabled
            ? PreTranscriptProvider(
                locator: quickTimeLocator,
                generation: { [weak clock] in clock?.generation ?? 1 },
                locale: { [weak self] in
                    // 先用实时的字幕内容判定语种：本地预转写在第一块之前拿不到内容，
                    // 只靠系统语言会在「中文系统看英文片」时整段听成乱码。
                    CaptionLanguageResolver.resolve(
                        preference: CaptionRecognitionLanguage.current,
                        contentHint: self?.languageHintLine,
                        systemLanguage: Locale.preferredLanguages.first ?? "en-US"
                    )
                },
                sourceNow: { [weak clock] in clock?.sourceNow() ?? 0 }
            )
            : nil
        preTranscriptEvidence?.onDiagnostics = { [weak self] message in
            Task { @MainActor in self?.log(message) }
        }

        speechProvider.start()
        do {
            try await newTap.start()
        } catch {
            speechProvider.stop()
            scheduler.reset()
            state = .failed(error.localizedDescription)
            log("tap start failed: \(error.localizedDescription)")
            return
        }

        tap = newTap
        speech = speechProvider
        lyricProvider = lyricEvidence
        frameProvider = frameEvidence
        preTranscriptProvider = preTranscriptEvidence
        preTranscriptEvidence?.start()
        state = .running
        // 注册顺序无关：调度器按证据等级自行排序（歌词 5、画面 3、流式 1）。
        // 具体注册哪几路由「字幕来源」偏好决定，可在运行中切换。
        applySourcePreference()
        startTicking()

        // 启动前已就位的歌词补灌一次，否则用户「先放歌、后开字幕」时链路里只有识别。
        if !pendingLyrics.isEmpty {
            lyricEvidence.submit(pendingLyrics, signature: pendingLyricsSignature)
        } else {
            setPrefetchability(0)
        }
        applyAdmissionGate()
    }

    func stop() async {
        tickTimer?.invalidate()
        tickTimer = nil
        speech?.stop()
        speech = nil
        lyricProvider?.clear()
        lyricProvider = nil
        frameProvider?.stop()
        frameProvider = nil
        preTranscriptProvider?.stop()
        preTranscriptProvider = nil
        await tap?.stop()
        tap = nil
        scheduler.reset()
        line = ""
        level = nil
        isPlaybackPaused = false
        state = .idle
        log("stopped")
    }

    /// 开关变化后整链重建：预转写来源是在 `start()` 里装配的，
    /// 只在运行中改偏好不会把它建出来。
    func restartForPreferenceChange() {
        guard state.isRunning else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.stop()
            await self.start()
        }
    }

    /// 非 async 的入口，供 SwiftUI 生命周期回调（onAppear / onChange）直接调用。
    func startIfNeeded() {
        guard !state.isRunning, state != .starting else { return }
        Task { await self.start() }
    }

    // MARK: - 时间轴同步

    /// 由 UI 在播放位置变化时调用，把调度器的时间轴对齐到播放器自报的位置。
    ///
    /// 注意：字幕本身只要求「同一时钟下的先后次序」，捕获时钟已经满足。
    /// 对齐播放器位置的唯一目的，是让后续以媒体时间为时间戳的来源（歌词、缓存转写）能并行进入同一条链。
    /// 因此当播放器位置明显不可信时，宁可退回捕获时钟，也不能让每次跳变都清空已建立的证书。
    func syncPlayback(position: TimeInterval, rate: Double, signature: String) {
        guard state.isRunning, usesPlayerTimeline, position > 0, position.isFinite else { return }

        // 速率为 0 就是暂停：位置不再回调，这里必须把时钟钉住，否则它会按 1× 继续外推。
        if !(rate > 0) {
            setPlaybackPaused(true, position: position)
            return
        }
        if isPlaybackPaused {
            setPlaybackPaused(false, position: position)
        }

        let host = SourceClock.hostNow()
        guard host - lastAlignAt >= Self.minimumAlignInterval else { return }
        lastAlignAt = host

        let jumped = clock.align(sourceTime: position, rate: rate, signature: signature)
        guard jumped else { return }

        jumpTimestamps.append(host)
        jumpTimestamps.removeAll { host - $0 > 10 }

        // 10 秒内四次跳变 = 播放器位置与音源不同步（例如浏览器视频、会议软件）。
        // 此时继续跟随只会让字幕周期性消失，直接退回捕获时钟并重建零点。
        if jumpTimestamps.count >= 4 {
            usesPlayerTimeline = false
            clock.resetToZero()
            scheduler.reset()
            // 代次已变，已灌入的歌词条目全部作废，必须按新代次重灌。
            lyricProvider?.resubmit()
            preTranscriptProvider?.resubmit()
            frameProvider?.reset()
            log("player timeline unstable → fall back to capture clock")
            return
        }

        scheduler.reset()
        lyricProvider?.resubmit()
        preTranscriptProvider?.resubmit()
        frameProvider?.reset()
        log("timeline jump → generation \(clock.generation) at \(String(format: "%.2f", position))")
    }

    /// 播放暂停 / 恢复时冻结或恢复字幕时间轴。
    ///
    /// 暂停后 `elapsedTime` 不再变化，`syncPlayback` 也就不会再被调用；只靠对齐
    /// 无法让时钟停下来。这里显式冻结，暂停期间调度器不会推进下一条字幕，
    /// 已上屏的那一行也不会因为时钟前移而到期消失。
    ///
    /// 冻结用「此刻的值」、恢复用「上报的位置」：前者保证暂停那一帧歌词不跳行，
    /// 后者保证暂停期间拖过进度条也能从新位置接上。
    func setPlaybackPaused(_ paused: Bool, position: TimeInterval) {
        // 位置 0 也要接：新歌一开头就暂停，恢复时若被挡掉，时钟会一直冻着。
        guard state.isRunning, usesPlayerTimeline,
              position.isFinite, position >= 0 else { return }
        guard paused != isPlaybackPaused else { return }
        isPlaybackPaused = paused
        if paused {
            clock.freeze()
        } else {
            clock.thaw(at: position)
            // 恢复后允许立刻重新对齐（否则会被 0.5s 节流挡掉一拍）。
            lastAlignAt = 0
        }
        log(paused
            ? String(format: "playback paused → clock frozen at %.2f (reported %.2f)",
                     clock.sourceNow(), position)
            : "playback resumed → clock unfrozen")
    }

    /// 音源重新可信时（例如切到音乐播放器）重新启用播放器时间轴。
    func resetTimelinePreference() {
        usesPlayerTimeline = true
        jumpTimestamps.removeAll()
        lastAlignAt = 0
    }

    /// 音乐场景（有元数据与既有歌词）可放行要求可预取的来源；纯系统捕获保持 0。
    func setPrefetchability(_ value: Double) {
        prefetchability = max(0, min(1, value))
    }

    // MARK: - 歌词来源

    /// 把当前曲目的已对齐歌词交给链路。空数组表示这一首没有同步歌词。
    ///
    /// `signature` 由曲目身份与时间轴形状共同决定：同一首歌反复回调不会重复灌入，
    /// 换歌或重新解析出不同时间轴才会重灌。
    func updateLyrics(_ lines: [LyricsManager.LrcLine], signature: String) {
        pendingLyrics = lines
        pendingLyricsSignature = lines.isEmpty ? "" : signature

        // 「暂停后字幕还在动」这类问题，第一现场就是歌词到底有没有灌进来。
        // 只在条数变化时记一行，正常播放不会刷屏。
        if lines.count != lastLyricsCount {
            lastLyricsCount = lines.count
            log("lyrics count=\(lines.count) sig=\(signature)")
        }

        // 选了「优先视频画面」就完全不采信歌词：既不灌入，也把已有条目撤掉，
        // 否则暂停中的那首歌会一直占着 5 级证据，视频的声音永远抢不过它。
        guard CaptionSourcePreference.current.includesLyrics else {
            lyricProvider?.clear()
            return
        }

        // 歌词是最可靠的语种线索：中文歌配英文标题、英文歌配中文界面都很常见。
        // 只在「自动」模式下用它，用户显式选了语言就不要被内容带偏。
        if CaptionRecognitionLanguage.current == .automatic {
            let sample = lines.prefix(4).map(\.text).joined(separator: " ")
            if !sample.isEmpty { speech?.updateContentHint(sample) }
        }

        // 有全文歌词意味着该音源可预取（播放前沿之后的内容已知），
        // 这正是权 1 里 P 的物理含义；视频/会议没有全文，保持 0。
        setPrefetchability(lines.isEmpty ? 0 : 0.9)

        guard state.isRunning, let lyricProvider else { return }
        if lines.isEmpty {
            lyricProvider.clear()
        } else {
            lyricProvider.submit(lines, signature: signature)
        }
        applyAdmissionGate()
    }

    /// 按「字幕来源」偏好重新组装证据链。
    ///
    /// 只改变「哪几路参与」，不改变等级次序——等级是可信度，偏好是用户意图。
    /// 运行中切换也安全：`register` 会覆盖旧链并重挂回调。
    func applySourcePreference() {
        guard state.isRunning else { return }
        let preference = CaptionSourcePreference.current
        var providers: [any CaptionEvidenceProvider] = []
        if let speech { providers.append(speech) }
        if preference.includesLyrics, let lyricProvider { providers.append(lyricProvider) }
        if preference.includesFrameText, let frameProvider { providers.append(frameProvider) }
        if let preTranscriptProvider { providers.append(preTranscriptProvider) }
        scheduler.register(providers)
        if preference.includesLyrics {
            // 从「优先视频画面」切回来时补灌一次：歌词内容一直留在 pending 里，
            // 但重新注册不会自动提交，不补的话要等到下一次播放状态变化才出现。
            if !pendingLyrics.isEmpty {
                lyricProvider?.submit(pendingLyrics, signature: pendingLyricsSignature)
            }
        } else {
            lyricProvider?.clear()
            setPrefetchability(0)
        }
        applyAdmissionGate()
        log("source preference=\(preference.rawValue) providers=\(providers.map(\.providerID))")
    }

    // MARK: - 来源准入

    /// 权 1「只让前 k 个来源执行」的落地形式。
    ///
    /// 注意闸门放在**来源**粒度而不是逐帧：流式识别一旦断了音频就再也接不上，
    /// 不能按区间开关。因此这里决定的是「这一轮哪些来源值得启动」，
    /// 而不是每一帧要不要送。
    private func applyAdmissionGate() {
        guard state.isRunning, !scheduler.chain.isEmpty else { return }
        let index = CaptionInterval.index(for: clock.sourceNow(), unit: scheduler.config.unit)
        var admitted: [String] = []
        var rejected: [String] = []

        for provider in scheduler.chain {
            if scheduler.shouldExecute(provider, unitIndex: index, prefetchability: prefetchability) {
                provider.start()
                admitted.append(provider.providerID)
            } else {
                // 「不占预算」不等于「停掉」：靠轮询攒内容的来源必须继续跑，
                // 否则它永远变不成可用，闸门也就永远把它挡在外面。
                if !provider.survivesRejection { provider.stop() }
                rejected.append(provider.providerID)
            }
        }

        log("admission k=\(scheduler.chainLength(for: index, prefetchability: prefetchability)) "
            + "in=[\(admitted.joined(separator: ","))] out=[\(rejected.joined(separator: ","))]")
    }

    // MARK: - 调度驱动

    /// 一行字幕过了自己的结束时间就清掉。
    ///
    /// `line` 原来只在 `stop()` 时清空，于是音频停了、播放器关了，最后一句仍挂在
    /// 顶部信息条上，看起来像「明明没播放，字幕还在识别」。判定用候选自带的结束时间，
    /// 比「多久没新行」更准：连续语音里句子之间本来就有停顿。
    private func expireCaptionLineIfNeeded() {
        guard !line.isEmpty, let end = scheduler.currentLineEnd else { return }
        let now = clock.sourceNow()
        guard now > end + 2.5 else { return }
        line = ""
        level = nil
        log(String(format: "caption line expired (now=%.1f end=%.1f)", now, end))
    }

    private func startTicking() {
        tickTimer?.invalidate()
        let timer = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state.isRunning else { return }
                self.scheduler.tick(prefetchability: self.prefetchability)
                // 预转写的轮询搭在这条已确认工作的 60 ms 定时器上：
                // 它内部按 1.5 秒节流，实际开销可以忽略。
                self.preTranscriptProvider?.pump()
                self.expireCaptionLineIfNeeded()
                self.frameProvider?.advance(
                    now: self.clock.sourceNow(),
                    unit: self.scheduler.config.unit
                )
                self.chainLength = self.scheduler.diagnostics.chainLength
                self.establishedCertificates = self.scheduler.diagnostics.certificatesEstablished
                // 无播放位置可对齐的音源，时间轴由捕获起点起算；这里不再回写。
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    // MARK: - 权限

    /// 读取用户设定的首帧预算，夹到合理区间：太小会让链长为 0，太大就失去约束意义。
    static func configuredBudget() -> TimeInterval {
        let stored = UserDefaults.standard.object(forKey: "captionBudget") as? Double
        return max(0.3, min(2.0, stored ?? 0.9))
    }

    /// 选择语音识别引擎。
    ///
    /// 不走「多语言并行」时直接用稳定引擎；走了则交给 `SpeechEngineRouter`——
    /// 它在分析器起不来时自动回落，用户不会因为换引擎而彻底失去字幕。
    static func makeSpeechProvider(
        clock: SourceClock,
        generation: @escaping () -> Int
    ) -> any SpeechEvidenceProviding {
        guard CaptionSpeechEngine.current == .multilingual else {
            return SpeechEvidenceProvider(clock: clock, generation: generation)
        }
        return SpeechEngineRouter(
            clock: clock,
            generation: generation,
            locales: analyzerLocales()
        )
    }

    /// 分析器要挂的语言模块。
    ///
    /// 显式选了语言就只挂一路（省一半算力）；「自动」同时挂中英，由合并层按脚本归属择优——
    /// 这才是多语言并行真正解决的问题：不必事先猜对内容语种。
    static func analyzerLocales() -> [Locale] {
        switch CaptionRecognitionLanguage.current {
        case .chinese: [Locale(identifier: "zh-CN")]
        case .english: [Locale(identifier: "en-US")]
        case .automatic: [Locale(identifier: "zh-CN"), Locale(identifier: "en-US")]
        }
    }

    /// 屏幕录制权限（ScreenCaptureKit 抓系统音频走的就是这条 TCC 授权）。
    static func hasAudioPermission() async -> Bool {
        await SystemAudioTap.hasPermission()
    }

    /// 语音识别授权状态。`.notDetermined` 会在首次 start 时弹窗。
    static func speechAuthorization() -> SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

    /// 把两处权限状态压成一句可直接展示的说明。
    ///
    /// 这里刻意不再调用 `SCShareableContent` 做探测：那会真的去请求屏幕内容，
    /// 既可能触发系统弹窗，也只能回答「现在能不能抓」，答不出「授权了但需要重启」。
    /// 状态统一由 PermissionCenter 判断，界面与权限页永远一致。
    @MainActor
    static func permissionSummary() -> String {
        let center = PermissionCenter.shared
        center.refreshCaptionStatuses()
        var parts: [String] = []
        switch center.status(for: .screenRecording) {
        case .allowed: parts.append(L10n.captionScreenPermissionGranted)
        case .needsRestart: parts.append(L10n.captionScreenPermissionNeedsRestart)
        default: parts.append(L10n.captionScreenPermissionMissing)
        }
        switch center.status(for: .speechRecognition) {
        case .allowed: parts.append(L10n.captionSpeechPermissionGranted)
        case .denied, .restricted: parts.append(L10n.captionSpeechPermissionMissing)
        default: parts.append(L10n.captionSpeechPermissionUndetermined)
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - 诊断日志

    private func openLogIfNeeded() {
        guard logHandle == nil else { return }
        let directory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/XNook", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("caption.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        logHandle = try? FileHandle(forWritingTo: url)
        logHandle?.seekToEndOfFile()
    }

    private func log(_ message: String) {
        guard let handle = logHandle else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = "[\(stamp)] \(message)\n"
        if let data = text.data(using: .utf8) {
            handle.write(data)
        }
    }

    /// 真实端到端延迟：这段音频「说完」到文字真正上屏，中间隔了多久。
    ///
    /// 与 `analyzer latency` 口径不同——后者只算识别器自身的处理时间，
    /// 看不到采集侧缓冲与调度排队。这里用源时钟把候选区间右端换算回宿主时刻，
    /// 差值才是用户实际看到的落后量。
    private func recordDisplayLag() {
        guard let end = scheduler.currentLineEnd else { return }
        let lag = SourceClock.hostNow() - clock.hostTime(atSource: end)
        guard lag.isFinite, lag >= 0, lag < 30 else { return }
        displayLagSamples.append(lag)
        displayLagTotal += 1
        guard displayLagTotal % 20 == 0, !displayLagSamples.isEmpty else { return }
        let average = displayLagSamples.reduce(0, +) / Double(displayLagSamples.count)
        let worst = displayLagSamples.max() ?? 0
        log(String(format: "display lag avg=%.2fs max=%.2fs n=%d", average, worst, displayLagTotal))
        displayLagSamples.removeAll(keepingCapacity: true)
    }
}
