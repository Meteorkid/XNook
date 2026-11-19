import AVFoundation
import Foundation
import Speech

/// 本地媒体预转写来源（证据等级 `localCache`）。
///
/// 这是唯一能让字幕**真正领先于声音**的来源：它读的不是「已经播出来的音频」，
/// 而是磁盘上播放前沿之后的那一段，提前转写成带时间戳的文本。等播放走到该时间点时，
/// 文本早已就位，因此既没有识别延迟，也没有「先出错再改对」的跳字。
///
/// 边界写死在实现里：只对能拿到文件路径的本地播放器有效（当前是 QuickTime）。
/// 浏览器里的流媒体缓冲在对方进程内，取不到，仍走实时识别。
@MainActor
final class PreTranscriptProvider: CaptionEvidenceProvider {

    let providerID = "pretranscript.local"
    /// 「本地已转写缓存」正是这一级的语义，且高于流式识别。
    let level: EvidenceLevel = .localCache
    /// 从调度器的角度看，它执行时不需要「临时等前瞻音频」——预转写在后台滚动推进，
    /// 轮到它时命中的已经是缓存。若申报 true，修正耗时会按 P=0 被罚成 11 秒，
    /// 而预算是 0.88 秒，它就会永远被挤出链外（1.3.50 首次联调的真实故障）。
    let prefetchRequired = false
    let allowsAsync = true
    let isSlow = false
    var weight: Double = 0.86
    /// 命中缓存，取用开销接近零。
    let estimatedLatency: TimeInterval = 0.05
    let timeoutAction: CaptionTimeoutAction = .discard

    var onCandidates: (([CaptionCandidate]) -> Void)?
    var onCoverageChange: (() -> Void)?
    var onDiagnostics: ((String) -> Void)?

    /// 没有已转写内容时不占预算，否则会以等级 2 的身份把流式识别挤出链外。
    var isAvailable: Bool { !segments.isEmpty }
    /// 准入闸门在它「还没内容」时必然拒绝它，但拒绝不能停掉轮询——
    /// 内容只能靠轮询攒出来，停了就永远没有内容。这正是 1.3.49 它一条日志都没有的原因。
    let survivesRejection = true

    private struct Segment {
        var start: TimeInterval
        var end: TimeInterval
        var text: String
    }

    /// 播放前沿之后要留多少秒的成品字幕。
    private let lookAhead: TimeInterval = 20
    /// 每次转写的音频长度。
    private let chunkSeconds: TimeInterval = 30
    private let pollInterval: TimeInterval = 1.5
    private let maxSegments = 6_000
    private let maxChunkDuration: Duration = .seconds(60)

    private let generation: () -> Int
    private let locale: () -> Locale
    private let locator: any LocalMediaLocator
    /// 调度时钟的当前值。预转写拿到的是**媒体时间**，而调度器只认这条时钟，
    /// 两者差值（`mediaOffset`）必须自己算——外部媒体位置可能来自另一个播放器。
    private let sourceNow: () -> TimeInterval

    private var currentFile: URL?
    private var transcribedUntil: TimeInterval = 0
    private var lastPosition: TimeInterval = 0
    private var isTranscribing = false
    private var isRunning = false
    private var isPolling = false
    /// 媒体时间 → 调度时钟的偏移：`mediaOffset = sourceNow - 播放位置`。
    private var mediaOffset: TimeInterval = 0
    private var lastPumpAt: TimeInterval = 0
    private var segments: [Segment] = []
    private var emittedGeneration = 0
    private var didLogFirstChunk = false
    private var lastTickLogAt: TimeInterval = 0

    init(
        locator: any LocalMediaLocator,
        generation: @escaping () -> Int,
        locale: @escaping () -> Locale,
        sourceNow: @escaping () -> TimeInterval
    ) {
        self.locator = locator
        self.generation = generation
        self.locale = locale
        self.sourceNow = sourceNow
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        onDiagnostics?("pretranscript: 轮询启动")
        pump()
    }

    func stop() {
        isRunning = false
        segments = []
        currentFile = nil
        transcribedUntil = 0
        onCoverageChange?()
    }

    /// 时间轴重建（seek / 切源）后按新代次重灌一次，否则旧代次条目会被整体丢弃。
    func resubmit() {
        guard !segments.isEmpty else { return }
        emit()
    }

    // MARK: - 轮询

    /// 由字幕调度周期（60 ms 的 Timer）驱动的轮询入口。
    ///
    /// 这里特意不自建 `Timer` / `Task` 循环：在这个 app 里两者都没有真正跑起来
    /// （Timer 只触发创建时那一次，`Task` 的闭包体根本没执行），而 `startTicking()`
    /// 那条 Timer 是确定工作的——字幕本身就在动。复用它比自己再造一套可靠。
    func pump(now: TimeInterval = Date().timeIntervalSince1970) {
        guard isRunning else { return }
        // 心跳：每 10 秒一条。没有它，「轮询在跑但定位器取不到东西」和
        // 「轮询根本没跑」在日志上是同一副样子，排查会走弯路。
        if now - lastTickLogAt >= 10 {
            lastTickLogAt = now
            onDiagnostics?("pretranscript: tick file=\(currentFile?.lastPathComponent ?? "nil") 已转写至=\(String(format: "%.1f", transcribedUntil))s")
        }
        guard now - lastPumpAt >= pollInterval, !isPolling else { return }
        lastPumpAt = now
        isPolling = true
        Task { @MainActor [weak self] in
            await self?.poll()
            self?.isPolling = false
        }
    }

    private func poll() async {
        guard let playback = await locator.currentPlayback() else { return }
        let now = sourceNow()
        // QuickTime 的 `playing` 在部分文档上恒为 false，位置是否推进是同等可信的信号。
        let advancing = playback.position > lastPosition + 0.2
        let active = playback.isPlaying || advancing

        if currentFile != playback.fileURL {
            currentFile = playback.fileURL
            mediaOffset = now - playback.position
            transcribedUntil = max(0, playback.position)
            lastPosition = playback.position
            segments = []
            didLogFirstChunk = false
            onCoverageChange?()
            if !active {
                // 只有「换了文件且停着」才记一次，避免每秒刷日志。
                onDiagnostics?("pretranscript: 已识别文件但未播放 \(playback.fileURL.lastPathComponent)")
                return
            }
            onDiagnostics?("pretranscript: 开始跟踪 \(playback.fileURL.lastPathComponent)")
        }

        // 媒体时间与调度时钟的偏差超过 3 秒，说明发生了暂停、拖动，
        // 或者调度时钟本身被别的播放器重锚过。重算偏移并把游标拉回当前位置。
        // 暂停期间不校正：此时位置不动而时钟在走，校正只会把偏移越推越远。
        let drift = (now - mediaOffset) - playback.position
        if active, abs(drift) > 3 {
            mediaOffset = now - playback.position
            transcribedUntil = max(0, playback.position)
            onDiagnostics?("pretranscript: 重锚偏移 \(String(format: "%.1f", mediaOffset))s（偏差 \(String(format: "%.1f", drift))s）")
        }
        // 媒体时间内的回退（拖动进度条）：游标也要拉回。
        if playback.position < lastPosition - 3 || playback.position + chunkSeconds < transcribedUntil - 1 {
            transcribedUntil = max(0, playback.position)
        }
        lastPosition = playback.position

        if generation() != emittedGeneration, !segments.isEmpty {
            emit()
        }

        guard active else { return }
        guard !isTranscribing else { return }
        // 已经领先足够多就不再切段；否则继续把前沿往前推。
        guard transcribedUntil - playback.position < lookAhead else { return }
        await transcribeNextChunk(from: transcribedUntil)
    }

    private func transcribeNextChunk(from start: TimeInterval) async {
        guard let file = currentFile else { return }
        isTranscribing = true
        defer { isTranscribing = false }

        let chunkStart = start
        let locale = self.locale()
        let chunk = chunkSeconds

        let wav: (url: URL, duration: TimeInterval)
        do {
            wav = try await Task.detached(priority: .utility) {
                try await MediaAudioChunkExtractor.extractWAV(
                    from: file, start: chunkStart, duration: chunk
                )
            }.value
        } catch {
            // 文件尾、无音轨、DRM 都会走到这里：把游标推到末尾，别原地重试打转。
            transcribedUntil = chunkStart + chunk
            onDiagnostics?("pretranscript: 切段失败 \(error.localizedDescription)")
            return
        }
        defer { try? FileManager.default.removeItem(at: wav.url) }

        let produced: [Segment]
        do {
            produced = try await recognizeWithFallback(url: wav.url, chunkStart: chunkStart, locale: locale)
        } catch {
            transcribedUntil = chunkStart + chunkSeconds
            onDiagnostics?("pretranscript: 转写失败 \(error.localizedDescription)")
            return
        }

        transcribedUntil = chunkStart + max(1, wav.duration)
        guard !produced.isEmpty else { return }

        segments.append(contentsOf: produced)
        if segments.count > maxSegments { segments.removeFirst(segments.count - maxSegments) }
        if !didLogFirstChunk {
            didLogFirstChunk = true
            let lead = (produced.first?.start ?? 0) - lastPosition
            onDiagnostics?(String(format: "pretranscript: 首块就绪 领先=%.1fs 条数=%d", lead, produced.count))
        }
        emit()
    }

    // MARK: - 识别

    /// 结果与所选语种明显不符时，换另一种语言把同一段音频再听一遍。
    ///
    /// 中文识别器听英文歌会给出「全是拉丁字母、却不成词」的碎片
    /// （实测得到 `mom thanthewhatthestockandnote` 这种），反之亦然。
    /// 这类结果一旦进链就是满屏乱码，重听一次的代价远小于让它上屏。
    private func recognizeWithFallback(
        url: URL,
        chunkStart: TimeInterval,
        locale: Locale
    ) async throws -> [Segment] {
        let first = try await recognize(url: url, chunkStart: chunkStart, locale: locale)
        guard shouldRetry(first, from: locale) else { return first }
        let alternate = locale.identifier.hasPrefix("zh")
            ? Locale(identifier: "en-US")
            : Locale(identifier: "zh-CN")
        onDiagnostics?("pretranscript: 结果与 \(locale.identifier) 不符，改用 \(alternate.identifier) 重试")
        return try await recognize(url: url, chunkStart: chunkStart, locale: alternate)
    }

    private func shouldRetry(_ segments: [Segment], from locale: Locale) -> Bool {
        var han = 0
        var latin = 0
        for scalar in segments.map(\.text).joined().unicodeScalars {
            if (0x4E00...0x9FFF).contains(scalar.value) {
                han += 1
            } else if CharacterSet.letters.contains(scalar) {
                latin += 1
            }
        }
        if locale.identifier.hasPrefix("zh") {
            return han == 0 && latin >= 12
        }
        let total = han + latin
        return total >= 12 && Double(han) / Double(total) >= 0.5
    }

    private func recognize(url: URL, chunkStart: TimeInterval, locale: Locale) async throws -> [Segment] {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw NSError(domain: "pretranscript", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "\(locale.identifier) 识别器不可用"])
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        let timeout = maxChunkDuration
        let result = try await withThrowingTaskGroup(of: SFSpeechRecognitionResult.self) { group in
            group.addTask {
                try await Self.run(recognizer: recognizer, request: request)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw NSError(domain: "pretranscript", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "转写超时"])
            }
            guard let first = try await group.next() else {
                throw NSError(domain: "pretranscript", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "无结果"])
            }
            group.cancelAll()
            return first
        }

        return Self.group(result.bestTranscription.segments, chunkStart: chunkStart)
    }

    private static func run(
        recognizer: SFSpeechRecognizer,
        request: SFSpeechURLRecognitionRequest
    ) async throws -> SFSpeechRecognitionResult {
        try await withCheckedThrowingContinuation { continuation in
            let box = ResumeBox()
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    box.resume { continuation.resume(throwing: error) }
                    return
                }
                guard let result, result.isFinal else { return }
                box.resume { continuation.resume(returning: result) }
            }
        }
    }

    /// 把逐词分段并成字幕行：句末标点、长度上限两者任一满足即断行。
    private static func group(_ raw: [SFTranscriptionSegment], chunkStart: TimeInterval) -> [Segment] {
        var output: [Segment] = []
        var buffer: [SFTranscriptionSegment] = []

        func flush() {
            guard let first = buffer.first, let last = buffer.last else { return }
            let text = join(buffer)
            buffer.removeAll(keepingCapacity: true)
            guard !text.isEmpty else { return }
            let start = chunkStart + first.timestamp
            let end = max(start + 0.2, chunkStart + last.timestamp + last.duration)
            output.append(Segment(start: start, end: end, text: text))
        }

        for segment in raw {
            buffer.append(segment)
            let text = segment.substring
            let endsSentence = text.last.map { ".。!！?？…".contains($0) } ?? false
            let long = join(buffer).count >= 28
            if endsSentence || long { flush() }
        }
        flush()

        // 行间去重：识别器在句末常把同一个词重复给出来。
        var deduped: [Segment] = []
        for segment in output where deduped.last?.text != segment.text {
            deduped.append(segment)
        }
        return deduped
    }

    /// 分段之间补回空格。
    ///
    /// `SFTranscriptionSegment.substring` 不保证带尾随空格：英文识别经常给出
    /// `"Text"` `"if"` `"thisworks"` 这样的碎片，直接 `joined()` 会得到
    /// `Textifthisworks`。中日韩文字不加空格，标点前后也不该凭空多出空格。
    private static func join(_ segments: [SFTranscriptionSegment]) -> String {
        let noSpaceBefore: Set<Character> = [".", ",", "!", "?", ";", ":", ")", "]", "}", "%"]
        let noSpaceAfter: Set<Character> = ["(", "[", "{", "-", "—", "/"]
        var text = ""
        for segment in segments {
            let piece = segment.substring
            guard !piece.isEmpty else { continue }
            if let last = text.last, let first = piece.first,
               !last.isWhitespace, !first.isWhitespace,
               last.isASCII, first.isASCII,
               !noSpaceBefore.contains(first), !noSpaceAfter.contains(last) {
                text.append(" ")
            }
            text.append(piece)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 产出

    private func emit() {
        guard !segments.isEmpty else { return }
        let generation = self.generation()
        emittedGeneration = generation
        // 媒体时间 → 调度时钟。`ingest` 只接受「尚未读过」的区间，
        // 若直接灌媒体时间，而时钟被别的播放器锚在别处，整批候选会被当成历史丢掉。
        let offset = mediaOffset
        let candidates = segments.map { segment in
            CaptionCandidate(
                providerID: providerID,
                level: level,
                weight: weight,
                start: segment.start + offset,
                end: segment.end + offset,
                text: segment.text,
                generation: generation,
                pipelineKey: "pretranscript.v1",
                state: .stable
            )
        }
        onCandidates?(candidates)
    }
}

/// 保证 continuation 只被恢复一次：识别回调可能同时送来错误与最终结果。
private final class ResumeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func resume(_ body: () -> Void) {
        lock.lock()
        guard !didResume else { lock.unlock(); return }
        didResume = true
        lock.unlock()
        body()
    }
}

/// 预转写开关。默认关闭：它需要一次「控制 QuickTime」的自动化授权，
/// 且只对本地文件生效，不该在用户没要求时改变默认行为。
enum PreTranscriptSettings {
    static let defaultsKey = "pretranscriptLocalMedia"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }
}
