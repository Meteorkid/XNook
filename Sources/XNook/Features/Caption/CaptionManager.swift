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

    // MARK: - 内部组件

    let clock = SourceClock()
    /// 首帧预算从设置读取。它是「承诺」而不是常数：调小会把更贵的来源裁出链外，
    /// 延迟上界随之收紧；调大则允许多个来源同时跑。
    let scheduler = CaptionScheduler(
        config: .init(deadlineBudget: CaptionManager.configuredBudget())
    )
    private var tap: SystemAudioTap?
    private var speech: SpeechEvidenceProvider?
    private var lyricProvider: LyricEvidenceProvider?
    private var frameProvider: FrameTextEvidenceProvider?
    private var tickTimer: Timer?
    private var logHandle: FileHandle?
    private var lastLoggedLine: String = ""

    /// 启动前就已加载好的歌词：等捕获真正跑起来再灌入，避免白算一遍。
    private var pendingLyrics: [LyricsManager.LrcLine] = []
    private var pendingLyricsSignature: String = ""

    /// 播放器时间轴对齐的最小间隔。识别与调度都在主线程，没必要 20 Hz 去抢锁。
    private var lastAlignAt: TimeInterval = 0
    private static let minimumAlignInterval: TimeInterval = 0.5

    /// 判定为跳变（seek / 切源）的时刻，用于识别「播放器位置不可信」。
    private var jumpTimestamps: [TimeInterval] = []
    /// 播放器自报位置连续多次剧烈跳变时，放弃对齐、退回捕获时钟，
    /// 否则每次跳变都会清空调度器，字幕会反复消失。
    private(set) var usesPlayerTimeline = true

    /// 调度周期：60 ms。远小于 L_budget(300 ms)，保证「到点即取」不会因为轮询粒度而迟到。
    private let tickInterval: TimeInterval = 0.06
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

        let speechProvider = SpeechEvidenceProvider(clock: clock) { [weak clock] in
            clock?.generation ?? 1
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
        // 注册顺序无关：调度器按证据等级自行排序（歌词 5、画面 3、流式 1）。
        scheduler.register([frameEvidence, lyricEvidence, speechProvider])
        scheduler.onLineChange = { [weak self] text, level in
            guard let self else { return }
            self.line = text
            self.level = level
            if !text.isEmpty, text != self.lastLoggedLine {
                self.lastLoggedLine = text
                self.log("line[\(level?.rawValue ?? 0)] \(text)")
            }
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
        state = .running
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
        await tap?.stop()
        tap = nil
        scheduler.reset()
        line = ""
        level = nil
        state = .idle
        log("stopped")
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
            frameProvider?.reset()
            log("player timeline unstable → fall back to capture clock")
            return
        }

        scheduler.reset()
        lyricProvider?.resubmit()
        frameProvider?.reset()
        log("timeline jump → generation \(clock.generation) at \(String(format: "%.2f", position))")
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
                provider.stop()
                rejected.append(provider.providerID)
            }
        }

        log("admission k=\(scheduler.chainLength(for: index, prefetchability: prefetchability)) "
            + "in=[\(admitted.joined(separator: ","))] out=[\(rejected.joined(separator: ","))]")
    }

    // MARK: - 调度驱动

    private func startTicking() {
        tickTimer?.invalidate()
        let timer = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state.isRunning else { return }
                self.scheduler.tick(prefetchability: self.prefetchability)
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

    /// 屏幕录制权限（ScreenCaptureKit 抓系统音频走的就是这条 TCC 授权）。
    static func hasAudioPermission() async -> Bool {
        await SystemAudioTap.hasPermission()
    }

    /// 语音识别授权状态。`.notDetermined` 会在首次 start 时弹窗。
    static func speechAuthorization() -> SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

    /// 把两处权限状态压成一句可直接展示的说明。
    static func permissionSummary() async -> String {
        let audio = await hasAudioPermission()
        let speech = speechAuthorization()
        var parts: [String] = []
        parts.append(audio ? L10n.captionScreenPermissionGranted : L10n.captionScreenPermissionMissing)
        switch speech {
        case .authorized: parts.append(L10n.captionSpeechPermissionGranted)
        case .denied, .restricted: parts.append(L10n.captionSpeechPermissionMissing)
        case .notDetermined: parts.append(L10n.captionSpeechPermissionUndetermined)
        @unknown default: parts.append(L10n.captionSpeechPermissionUndetermined)
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
}
