import Foundation
import Observation

enum LyricsStatus: Equatable {
    case idle, loading, synced, plainText, notFound, failed, disabled
}

enum LyricsRefreshNotice: Equatable {
    case failedKeepingCurrent, noMatchKeepingCurrent
}

/// 歌词管理器 — 从 LRCLIB 获取同步歌词，解析 LRC 格式
@Observable @MainActor
final class LyricsManager {
    typealias RequestLoader = @MainActor (URLRequest) async throws -> (Data, URLResponse)
    typealias CacheReader = @MainActor (String, String, String) async -> LyricsCache.Entry?
    typealias CacheWriter = @MainActor (String, String, String, LyricsCache.EntryType, String, LyricsCache.MatchMetadata?) -> Void

    private let defaults: UserDefaults
    private let loadRequest: RequestLoader
    private let readCache: CacheReader
    private let writeCache: CacheWriter
    private let sleep: @MainActor (Duration) async throws -> Void
    private let now: () -> Date

    init(
        defaults: UserDefaults = .standard,
        loadRequest: @escaping RequestLoader = { try await URLSession.shared.data(for: $0) },
        readCache: @escaping CacheReader = { await LyricsCache.readAsync(title: $0, artist: $1, album: $2) },
        writeCache: @escaping CacheWriter = { LyricsCache.write(title: $0, artist: $1, album: $2, type: $3, payload: $4, match: $5) },
        sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.loadRequest = loadRequest
        self.readCache = readCache
        self.writeCache = writeCache
        self.sleep = sleep
        self.now = now
        self.storedLyricsOffset = Self.normalizedOffset(defaults.double(forKey: "lyricsOffset"))
        self.status = defaults.bool(forKey: "showLyrics") ? .idle : .disabled
    }

    private var retryAfter: Date?
    private var manualRetryAfter: Date?
    private var consecutiveFailures = 0

    var shouldRetryCurrentTrack: Bool {
        guard !isFetching, !isCoolingDown else { return false }
        return (durationRevalidationPending && !hasRevalidatedDuration) || (status == .failed && retryAfter != nil)
    }
    var currentLine: String = ""
    var isFetching = false
    private(set) var status: LyricsStatus = .idle
    private(set) var refreshNotice: LyricsRefreshNotice?

    var canRetryCurrentTrack: Bool {
        guard defaults.bool(forKey: "showLyrics"), !currentTitle.isEmpty,
              !isFetching, [.notFound, .failed, .synced, .plainText].contains(status) else { return false }
        return !isCoolingDown
    }

    /// 详情只需在冷却结束时刷新按钮，无需常驻轮询。
    var retryAvailableAt: Date? {
        [retryAfter, manualRetryAfter].compactMap { $0 }.max()
    }

    private var isCoolingDown: Bool { retryAvailableAt.map { now() < $0 } ?? false }

    @discardableResult
    func retryCurrentTrack() -> Bool {
        guard canRetryCurrentTrack else { return false }
        manualRetryAfter = now().addingTimeInterval(5)
        fetchLyrics(title: currentTitle, artist: currentArtist, album: currentAlbum,
                    duration: currentDuration, isManualRetry: true)
        return true
    }

    private var storedLyricsOffset: TimeInterval

    /// 正值延后歌词，负值提前；只影响歌词定位，不修改播放进度或缓存时间轴。
    var lyricsOffset: TimeInterval {
        get { storedLyricsOffset }
        set {
            let offset = Self.normalizedOffset(newValue)
            let changed = storedLyricsOffset != offset
            storedLyricsOffset = offset
            if defaults.object(forKey: "lyricsOffset") == nil || defaults.double(forKey: "lyricsOffset") != offset {
                defaults.set(offset, forKey: "lyricsOffset")
            }
            if changed { notifyStateChanged() }
        }
    }

    /// 同步设置页通过 AppStorage 写入的值，让当前歌词立即重新定位。
    func refreshPreferences() {
        lyricsOffset = defaults.double(forKey: "lyricsOffset")
    }

    private static func normalizedOffset(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return 0 }
        return (min(5, max(-5, value)) * 10).rounded() / 10
    }

    /// 当前是否有同步歌词可供推进 — timer 启动条件之一
    var hasLyrics: Bool { !lyrics.isEmpty }
    /// 仅有纯歌词、无同步时间轴 — 由 UI 兜底显示
    private(set) var plainLyricsText: String = ""

    /// 纯歌词的预览首句：取第一段非空、非元数据的行，截断到 80 字符
    /// 仅用于"有歌词内容但无时间轴"时的兜底显示
    var plainLyricPreview: String {
        Self.previewLine(from: plainLyricsText)
    }

    /// 从纯歌词全文中提取预览首句（纯函数，便于测试）
    static func previewLine(from plainText: String) -> String {
        guard !plainText.isEmpty else { return "" }
        for raw in plainText.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            // 跳过空行
            if line.isEmpty { continue }
            // 跳过 LRC 元数据行（[ti:..] / [ar:..] / 时间标签残留）
            if line.hasPrefix("[") { continue }
            // 跳过纯音乐/间奏标记：LRCLIB 这类内容显示出来无意义
            if isInstrumentalOrPlaceholder(line) { continue }
            // 截断过长行
            if line.count > 80 {
                return String(line.prefix(80)) + "…"
            }
            return line
        }
        return ""
    }

    /// 判断是否为纯音乐/间奏/占位符等无意义标记（大小写不敏感）
    private static func isInstrumentalOrPlaceholder(_ line: String) -> Bool {
        let lower = line.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "[](){}.,!?"))
            .trimmingCharacters(in: .whitespaces)
        let placeholders: Set<String> = [
            "instrumental",
            "inst.",
            "music",
            "interlude",
            "intro",
            "outro",
            "solo",
            "piano solo",
            "guitar solo",
            "♪",
            "·"
        ]
        // 注意：这里不列 "[music]" 之类带括号的写法 —— 比较前括号已被 trim 掉，
        // 那种条目永远匹配不到（何况 previewLine 更早就跳过了 "[" 开头的行）。
        if placeholders.contains(lower) { return true }
        // 只认"整行以该标记开头且很短"的间奏标注（如 "Instrumental Break"）。
        // 用 contains 做全文匹配会误杀正文里恰好含该词的真实歌词行。
        return lower.hasPrefix("instrumental") && lower.count <= 20
    }

    private var lyrics: [LrcLine] = []
    private var currentTitle = ""
    private var currentArtist = ""
    private var currentAlbum = ""
    /// 最新可信时长供手动重试使用；另存查找时长，避免浮点抖动取消慢请求。
    private var currentDuration: TimeInterval?
    private var lookupDuration: TimeInterval?
    private var currentMatch: LyricsCache.MatchMetadata?
    private var durationRevalidationPending = false
    private var hasRevalidatedDuration = false
    /// 代际标识：每次切歌递增，防止旧异步请求覆盖新状态
    private var fetchGeneration: Int = 0
    /// 当前歌词请求任务，用于取消旧请求
    private var fetchTask: Task<Void, Never>?

    /// 歌词状态变化回调：歌词加载完成、缓存命中、或 reset 后触发。
    /// MediaManager 用它来重新评估 progressTimer 是否需要启动，
    /// 避免歌词加载完成后 timer 仍未启动导致歌词卡住不滚动。
    var onLyricsStateChanged: (() -> Void)?

    /// 在状态可能影响 timer 决策的变化点统一触发回调
    private func notifyStateChanged() {
        onLyricsStateChanged?()
    }

    // MARK: - LRC 解析

    struct LrcLine {
        let time: TimeInterval  // 秒
        let text: String
    }

    /// 解析 LRC 格式歌词
    /// [00:12.34] 歌词内容
    static func parseLrc(_ lrc: String) -> [LrcLine] {
        var lines: [LrcLine] = []
        for raw in lrc.components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            // 一行可能对应多个时间点，例如 [00:12.00][00:30.00]副歌
            let matches = trimmed.matches(of: #/\[(\d+):(\d+\.?\d*)\]/#)
            guard let lastMatch = matches.last else { continue }
            let text = String(trimmed[lastMatch.range.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            for match in matches {
                let min = Double(match.1) ?? 0
                let sec = Double(match.2) ?? 0
                lines.append(LrcLine(time: min * 60 + sec, text: text))
            }
        }
        return lines.sorted { $0.time < $1.time }
    }

    // MARK: - 获取歌词

    func fetchLyrics(
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval? = nil
    ) {
        fetchLyrics(title: title, artist: artist, album: album, duration: duration, isManualRetry: false)
    }

    private func fetchLyrics(
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval?,
        isManualRetry: Bool
    ) {
        // 检查歌词功能是否开启（默认开启，可在设置中关闭）
        let lyricsEnabled = defaults.bool(forKey: "showLyrics")
        guard lyricsEnabled else {
            reset()
            return
        }

        guard !title.isEmpty else { return }
        let identityChanged = title != currentTitle || artist != currentArtist || album != currentAlbum
        let usableDuration = Self.validDuration(duration)
        if identityChanged {
            currentDuration = usableDuration
            lookupDuration = nil
            currentMatch = nil
            hasRevalidatedDuration = false
            durationRevalidationPending = false
            consecutiveFailures = 0
            manualRetryAfter = nil
            retryAfter = nil
        } else {
            if let usableDuration { currentDuration = usableDuration }
            if !hasRevalidatedDuration {
                durationRevalidationPending = currentDuration.map {
                    lookupDuration == nil || abs($0 - (lookupDuration ?? 0)) >= 1
                } ?? false
            }
            discardIncompatibleCurrentLyrics()
        }
        let revalidatingDuration = durationRevalidationPending && !hasRevalidatedDuration && (isManualRetry || !isCoolingDown)
        guard identityChanged || revalidatingDuration || shouldRetryCurrentTrack || isManualRetry else { return }
        if revalidatingDuration {
            hasRevalidatedDuration = true
            durationRevalidationPending = false
        }
        let bypassCache = isManualRetry || revalidatingDuration
        let requestedDuration = currentDuration
        lookupDuration = requestedDuration
        retryAfter = nil
        refreshNotice = nil
        currentTitle = title
        currentArtist = artist
        currentAlbum = album
        if identityChanged {
            lyrics = []
            plainLyricsText = ""
            currentLine = ""
        }
        isFetching = true
        if lyrics.isEmpty && plainLyricsText.isEmpty { status = .loading }
        fetchGeneration += 1  // 递增代际标识
        let generation = fetchGeneration  // 捕获当前代际

        // 取消旧的歌词请求
        fetchTask?.cancel()
        notifyStateChanged()

        fetchTask = Task {
            // 先尝试磁盘缓存：命中即出，避免网络往返。
            // 读取放到后台队列 —— JSON 解码与 mtime 刷新都是阻塞 syscall，
            // 在 MainActor 上执行会在磁盘繁忙时卡掉 UI 帧。
            let cached = bypassCache ? nil : await self.readCache(title, artist, album)
            guard generation == self.fetchGeneration else { return }
            // 内容无效或候选元数据冲突时继续联网，不能永久卡在旧缓存上。
            if let cached, self.apply(entry: cached) {
                self.isFetching = false
                self.consecutiveFailures = 0
                // 缓存命中后立刻通知 MediaManager 评估 timer：歌词已就位，可以推进
                self.notifyStateChanged()
                // 命中缓存后即返回：网络刷新作为可选优化留给后台，避免重复请求
                // （LRCLIB 数据稳定，没必要每次都刷新）
                return
            }

            // 网络偶发失败时有限重试：切歌瞬间网络抖动不应让整首歌没歌词。
            // 404/无数据 不重试（确无歌词）；仅对可恢复错误（超时、连接失败）重试。
            let maxAttempts = 2
            var decoded: LrcResponse?
            var lastError: Error?
            for attempt in 1...maxAttempts {
                do {
                    decoded = try await Self.fetchResponse(
                        title: title,
                        artist: artist,
                        album: album,
                        duration: requestedDuration,
                        loadRequest: self.loadRequest,
                        matchingDuration: { self.currentDuration },
                        onPlainLyrics: { candidate in
                            guard generation == self.fetchGeneration,
                                  Self.isEligibleCandidate(candidate, title: title, artist: artist, duration: self.currentDuration),
                                  self.lyrics.isEmpty else { return }
                            self.plainLyricsText = candidate.plainLyrics ?? ""
                            self.currentMatch = Self.matchMetadata(candidate)
                            self.status = .plainText
                            self.notifyStateChanged()
                        }
                    )
                    lastError = nil
                    break
                } catch {
                    // 切歌或取消：立即退出不重试
                    if generation != self.fetchGeneration || Task.isCancelled { break }
                    lastError = error
                    // 最后一次失败、或错误本身不可恢复（解码失败、HTTP 语义错误）都不重试
                    guard attempt < maxAttempts, Self.isRetryable(error) else { break }
                    // 退避 1s 后重试
                    try? await self.sleep(.seconds(1))
                    if generation != self.fetchGeneration { break }
                }
            }

            // 代际检查：如果切歌了，丢弃本次结果
            guard generation == self.fetchGeneration else { return }

            if let decoded, Self.isEligibleCandidate(decoded, title: title, artist: artist, duration: self.currentDuration) {
                self.currentMatch = Self.matchMetadata(decoded)
                let parsed = Self.parseLrc(decoded.syncedLyrics ?? "")
                if let synced = decoded.syncedLyrics, !parsed.isEmpty {
                    self.lyrics = parsed
                    self.plainLyricsText = ""
                    self.status = .synced
                    self.writeCache(title, artist, album, .synced, synced, self.currentMatch)
                } else if let plain = decoded.plainLyrics, !plain.isEmpty {
                    // 无同步时间轴：保留纯歌词全文供 UI 兜底显示
                    self.lyrics = []
                    self.plainLyricsText = plain
                    self.status = .plainText
                    self.writeCache(title, artist, album, .plain, plain, self.currentMatch)
                } else {
                    self.lyrics = []
                    self.plainLyricsText = ""
                    self.status = .notFound
                }
                self.consecutiveFailures = 0
                self.isFetching = false
                // 网络加载完成：歌词就位（或确认无歌词），通知 MediaManager 评估 timer
                self.notifyStateChanged()
            } else {
                // 全部重试失败：不影响功能（ticker 回退到标题显示）。
                // 但要留下痕迹，否则线上"没歌词"完全无从判断是网络问题还是确无歌词。
                // 只打印错误本身，不打印曲目信息，避免把用户的听歌记录写进日志。
                if let lastError, Self.isRetryable(lastError) {
                    self.consecutiveFailures += 1
                    let delay = 15.0 * Double(1 << min(self.consecutiveFailures - 1, 3))
                    self.retryAfter = self.now().addingTimeInterval(delay)
                }
                if self.hasLyrics || !self.plainLyricsText.isEmpty {
                    if lastError == nil { self.consecutiveFailures = 0 }
                    self.status = self.hasLyrics ? .synced : .plainText
                    self.refreshNotice = lastError == nil ? .noMatchKeepingCurrent : .failedKeepingCurrent
                } else if let lastError {
                    self.status = .failed
                    print("[Lyrics] 歌词获取失败: \(lastError.localizedDescription)")
                } else {
                    self.status = .notFound
                    self.consecutiveFailures = 0
                }
                self.isFetching = false
                // 加载失败也要通知：让 timer 评估在没有歌词时是否应停止
                self.notifyStateChanged()
            }
        }
    }

    /// 仅对可恢复的网络错误重试。超时、连接失败重试有意义；
    /// 解码失败、HTTP 语义错误这类确定性结果重试只是白白多打一次请求。
    static func isRetryable(_ error: Error) -> Bool {
        if case LookupError.httpStatus(let status) = error {
            return status == 429 || (500...599).contains(status)
        }
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut,
             .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed,
             .networkConnectionLost,
             .notConnectedToInternet:
            return true
        default:
            return false
        }
    }

    /// 把缓存项应用到当前状态（同步歌词解析时间轴；纯歌词保留全文）
    /// - Returns: 缓存内容是否可用。解析后为空说明缓存已损坏，调用方应落回网络。
    @discardableResult
    private func apply(entry: LyricsCache.Entry) -> Bool {
        let candidate = LrcResponse(trackName: entry.match?.trackName, artistName: entry.match?.artistName,
            duration: entry.match?.duration, syncedLyrics: entry.type == .synced ? entry.payload : nil,
            plainLyrics: entry.type == .plain ? entry.payload : nil)
        guard Self.isEligibleCandidate(candidate, title: currentTitle, artist: currentArtist, duration: currentDuration) else { return false }
        switch entry.type {
        case .synced:
            let parsed = Self.parseLrc(entry.payload)
            guard !parsed.isEmpty else { return false }
            lyrics = parsed
            plainLyricsText = ""
            status = .synced
        case .plain:
            guard !entry.payload.isEmpty else { return false }
            lyrics = []
            plainLyricsText = entry.payload
            status = .plainText
        }
        currentMatch = entry.match
        currentLine = ""
        return true
    }

    private static func validDuration(_ duration: TimeInterval?) -> TimeInterval? {
        guard let duration, duration.isFinite, duration > 0, duration < Double(Int.max) else { return nil }
        return duration
    }

    private static func matchMetadata(_ candidate: LrcResponse) -> LyricsCache.MatchMetadata {
        LyricsCache.MatchMetadata(trackName: candidate.trackName, artistName: candidate.artistName,
                                 duration: validDuration(candidate.duration))
    }

    private func discardIncompatibleCurrentLyrics() {
        guard let currentMatch else { return }
        let candidate = LrcResponse(trackName: currentMatch.trackName, artistName: currentMatch.artistName,
            duration: currentMatch.duration, syncedLyrics: nil, plainLyrics: nil)
        guard !Self.hasCompatibleMetadata(candidate, title: currentTitle, artist: currentArtist, duration: currentDuration) else { return }
        lyrics = []
        plainLyricsText = ""
        currentLine = ""
        self.currentMatch = nil
        refreshNotice = nil
        status = isFetching ? .loading : .notFound
        notifyStateChanged()
    }

    static func bestSearchResult(
        from candidates: [LrcResponse],
        title: String,
        artist: String,
        duration: TimeInterval?
    ) -> LrcResponse? {
        // 元数据或空白内容不能阻断后续候选与 q= 兜底搜索。
        let usableCandidates = candidates.filter {
            isEligibleCandidate($0, title: title, artist: artist, duration: duration)
        }
        let normalizedTitle = normalize(title)
        let normalizedArtist = normalize(artist)
        // 注意：coreTitle 必须从原始标题提取。normalize 会剥掉括号，
        // 先 normalize 再找括号永远找不到，第二/三轮会退化成第一轮的重复。
        let coreTitle = Self.coreTitle(title)

        // 第一轮：严格匹配（完整 normalize 字符串双向 contains）
        let strict = usableCandidates.filter { candidate in
            matches(candidate, normalizedTitle: normalizedTitle, normalizedArtist: normalizedArtist)
        }
        if let best = strict.max(by: { searchScore($0, duration: duration) < searchScore($1, duration: duration) }) {
            return best
        }

        // 第二轮：核心歌名匹配（去括号后比较）—— 解决括号内版本/来源标注不匹配
        // 例：Music "光亮 (大型纪录片...主题歌)" vs LRCLIB "光亮 (大型紀錄片...主題歌)"
        guard !coreTitle.isEmpty else { return nil }
        let core = usableCandidates.filter { candidate in
            guard candidate.hasLyrics else { return false }
            let candidateCore = Self.coreTitle(candidate.trackName ?? "")
            guard !candidateCore.isEmpty else { return false }
            let titleMatches = Self.titleMatches(candidateCore, coreTitle)
            let candidateArtist = normalize(candidate.artistName ?? "")
            let artistMatches = normalizedArtist.isEmpty
                || candidateArtist.contains(normalizedArtist)
                || normalizedArtist.contains(candidateArtist)
            return titleMatches && artistMatches
        }
        if let best = core.max(by: { searchScore($0, duration: duration) < searchScore($1, duration: duration) }) {
            return best
        }

        // 第三轮：核心歌名完全相等 + duration 接近时忽略 artist —— 解决翻唱/cover 问题
        // 例：Music "心墙" by 林俊杰（翻唱） vs LRCLIB "心墙" by 郭静（原唱）
        //
        // duration 是本轮唯一的安全阀：一旦缺失就只剩歌名相等，会把同名不同曲
        // （Adele "Hello" vs Lionel Richie "Hello"）整首显示成错误歌词。
        // 切歌初期 duration 为 0、部分播放源不提供时长都会命中这种情况，
        // 代价远大于"翻唱匹配不上"，因此 duration 未知时直接放弃本轮。
        guard let duration else { return nil }
        let coverMatch = usableCandidates.filter { candidate in
            guard candidate.hasLyrics else { return false }
            guard let candidateDuration = candidate.duration else { return false }
            guard Self.coreTitle(candidate.trackName ?? "") == coreTitle else { return false }
            // duration 容差 ±15s，避免同名不同歌
            return abs(candidateDuration - duration) <= 15
        }
        return coverMatch.max(by: { searchScore($0, duration: duration) < searchScore($1, duration: duration) })
    }

    /// 精确和搜索结果共用资格检查；缺字段不是冲突，也不能据此认定版本已校准。
    static func isEligibleCandidate(_ candidate: LrcResponse, title: String, artist: String,
                                    duration: TimeInterval?) -> Bool {
        guard !parseLrc(candidate.syncedLyrics ?? "").isEmpty
            || candidate.plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return false }
        return hasCompatibleMetadata(candidate, title: title, artist: artist, duration: duration)
    }

    private static func hasCompatibleMetadata(_ candidate: LrcResponse, title: String, artist: String,
                                              duration: TimeInterval?) -> Bool {
        let candidateTitle = normalize(candidate.trackName ?? "")
        let requestedTitle = normalize(title)
        let candidateCore = coreTitle(candidate.trackName ?? "")
        let requestedCore = coreTitle(title)
        if !candidateTitle.isEmpty, !requestedTitle.isEmpty {
            guard titleMatches(candidateTitle, requestedTitle)
                || titleMatches(candidateCore, requestedCore) else { return false }
        }
        let candidateArtist = normalize(candidate.artistName ?? "")
        let requestedArtist = normalize(artist)
        if candidateArtist.isEmpty || requestedArtist.isEmpty
            || candidateArtist.contains(requestedArtist) || requestedArtist.contains(candidateArtist) { return true }

        // 歌手明确不同时，仅沿用现有翻唱回退；不对同歌手新增统一时长门槛。
        guard !candidateCore.isEmpty, candidateCore == requestedCore,
              let duration, let candidateDuration = candidate.duration,
              duration.isFinite, duration > 0, candidateDuration.isFinite, candidateDuration > 0 else { return false }
        return abs(candidateDuration - duration) <= 15
    }

    /// 判断候选是否严格匹配（完整 normalize 字符串）
    private static func matches(
        _ candidate: LrcResponse,
        normalizedTitle: String,
        normalizedArtist: String
    ) -> Bool {
        guard candidate.hasLyrics else { return false }
        let candidateTitle = normalize(candidate.trackName ?? "")
        let candidateArtist = normalize(candidate.artistName ?? "")
        let titleMatches = Self.titleMatches(candidateTitle, normalizedTitle)
        let artistMatches = normalizedArtist.isEmpty
            || candidateArtist.contains(normalizedArtist)
            || normalizedArtist.contains(candidateArtist)
        return titleMatches && artistMatches
    }

    /// 判断两个归一化后的标题是否匹配。
    /// 完全相等总是匹配；短标题（≤2 字符）要求完全相等，避免"光"误匹配"光年"；
    /// 长标题允许双向 contains，覆盖"歌名 (Live)"等带后缀变体。
    private static func titleMatches(_ candidateTitle: String, _ targetTitle: String) -> Bool {
        if candidateTitle == targetTitle { return true }
        if candidateTitle.count <= 2 || targetTitle.count <= 2 { return false }
        return candidateTitle.contains(targetTitle) || targetTitle.contains(candidateTitle)
    }

    /// 截断括号及其后内容，保留原始字符（含空格、大小写）
    /// "光亮 (大型纪录片《紫禁城》主题歌)" → "光亮"
    /// "Shape of You (Remix)" → "Shape of You"
    /// 整个标题都在括号里时保留原串，避免产生空查询
    static func strippedTitle(_ raw: String) -> String {
        let openers: Set<Character> = ["(", "[", "（", "【"]
        let head = raw.firstIndex(where: { openers.contains($0) })
            .map { String(raw[..<$0]) } ?? raw
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? raw.trimmingCharacters(in: .whitespacesAndNewlines) : trimmed
    }

    /// 去掉版本/来源标注后再归一化的核心歌名，用于候选比较。
    /// 必须传入原始标题：normalize 会剥掉括号，先归一化就再也切不出核心歌名了。
    static func coreTitle(_ raw: String) -> String {
        normalize(strippedTitle(raw))
    }

    private static func fetchResponse(
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval?,
        loadRequest: RequestLoader,
        matchingDuration: @escaping @MainActor () -> TimeInterval?,
        onPlainLyrics: @MainActor (LrcResponse) -> Void
    ) async throws -> LrcResponse? {
        try Task.checkCancellation()
        var exactFallback: LrcResponse?
        var exactFailure: Error?
        let currentExactFallback = { () -> LrcResponse? in
            guard let result = exactFallback,
                  isEligibleCandidate(result, title: title, artist: artist, duration: matchingDuration()) else { return nil }
            return result
        }

        if let duration,
           shouldUseExactLookup(album: album, duration: duration),
           let exactURL = exactLyricsURL(title: title, artist: artist, album: album, duration: duration) {
            do {
                let (exactData, exactResponse) = try await loadRequest(request(for: exactURL))
                try Task.checkCancellation()
                let status = try responseStatus(exactResponse)
                if status == 200 {
                    let exactResult = try JSONDecoder().decode(LrcResponse.self, from: exactData)
                    if isEligibleCandidate(exactResult, title: title, artist: artist, duration: matchingDuration()) {
                        if !parseLrc(exactResult.syncedLyrics ?? "").isEmpty {
                            return exactResult
                        }
                        if let plain = exactResult.plainLyrics,
                           !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            exactFallback = exactResult
                            onPlainLyrics(exactResult)
                        }
                    }
                } else if status != 404 {
                    throw LookupError.httpStatus(status)
                }
            } catch {
                try Task.checkCancellation()
                // 整个网络不可用时不再请求同一主机；单个端点超时仍可尝试搜索。
                if let urlError = error as? URLError,
                   [.notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed].contains(urlError.code) {
                    throw error
                }
                exactFailure = error
            }
        }

        guard let searchURL = searchLyricsURL(title: title, artist: artist) else {
            return currentExactFallback()
        }

        do {
            try Task.checkCancellation()
            let (searchData, searchResponse) = try await loadRequest(request(for: searchURL))
            try Task.checkCancellation()
            let status = try responseStatus(searchResponse)
            guard status == 200 else { throw LookupError.httpStatus(status) }
            let candidates = try JSONDecoder().decode([LrcResponse].self, from: searchData)
            var best = bestSearchResult(
                from: candidates,
                title: title,
                artist: artist,
                duration: matchingDuration()
            )

            // 兜底：track_name+artist_name 搜索无匹配结果时，用 q= 全文搜索重试
            // LRCLIB 两个端点索引不同，q= 能命中更多中文/跨语言变体
            if best == nil, let fallbackURL = fallbackSearchURL(title: title, artist: artist) {
                try Task.checkCancellation()
                let (fbData, fbResponse) = try await loadRequest(request(for: fallbackURL))
                try Task.checkCancellation()
                let fallbackStatus = try responseStatus(fbResponse)
                if fallbackStatus == 200 {
                    let fbCandidates = try JSONDecoder().decode([LrcResponse].self, from: fbData)
                    best = bestSearchResult(
                        from: fbCandidates,
                        title: title,
                        artist: artist,
                        duration: matchingDuration()
                    )
                } else {
                    throw LookupError.httpStatus(fallbackStatus)
                }
            }

            if let best, !parseLrc(best.syncedLyrics ?? "").isEmpty { return best }
            if let result = currentExactFallback() ?? best { return result }
            if let exactFailure { throw exactFailure }
            return nil
        } catch {
            try Task.checkCancellation()
            // 搜索只是尝试补充同步时间轴，失败不能抹掉精确查询已取得的歌词。
            if let fallback = currentExactFallback() { return fallback }
            throw error
        }
    }

    private enum LookupError: LocalizedError {
        case httpStatus(Int)

        var errorDescription: String? {
            switch self {
            case .httpStatus(let status): return "歌词服务返回 HTTP \(status)"
            }
        }
    }

    private static func responseStatus(_ response: URLResponse) throws -> Int {
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return http.statusCode
    }

    private static let lyricsAPIBaseURL = "https://lrclib.net/api"

    static func shouldUseExactLookup(album: String, duration: TimeInterval?) -> Bool {
        !album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && validDuration(duration) != nil
    }

    private static func exactLyricsURL(
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval
    ) -> URL? {
        var components = URLComponents(string: "\(lyricsAPIBaseURL)/get")
        components?.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "album_name", value: album),
            URLQueryItem(name: "duration", value: String(Int(duration.rounded()))),
        ]
        return components?.url
    }

    private static func searchLyricsURL(title: String, artist: String) -> URL? {
        var components = URLComponents(string: "\(lyricsAPIBaseURL)/search")
        components?.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
        ]
        return components?.url
    }

    /// q= 全文搜索兜底：LRCLIB 的 track_name+artist_name 与 q= 索引不同，
    /// 前者无果时用核心歌名做 q= 搜索能命中更多变体。
    ///
    /// 这里必须用去括号后的**原始**标题，不能用 normalize 的结果：
    /// q= 是分词全文检索，"Shape of You" 被归一化成 "shapeofyou" 这种粘连串后
    /// 几乎不可能命中。artist 一并带上以缩小结果集。
    static func fallbackSearchURL(title: String, artist: String) -> URL? {
        let core = strippedTitle(title)
        guard !core.isEmpty else { return nil }
        var query = core
        let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedArtist.isEmpty {
            query += " " + trimmedArtist
        }
        var components = URLComponents(string: "\(lyricsAPIBaseURL)/search")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
        ]
        return components?.url
    }

    private static func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("XNook/1.0 (macOS Dynamic Island tool center)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10
        return request
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased().unicodeScalars
            .filter(CharacterSet.alphanumerics.contains)
            .map(String.init)
            .joined()
    }

    private static func searchScore(
        _ candidate: LrcResponse,
        duration: TimeInterval?
    ) -> Double {
        var score = parseLrc(candidate.syncedLyrics ?? "").isEmpty ? 0.0 : 100.0
        if let duration, let candidateDuration = candidate.duration {
            score += max(0, 60 - abs(candidateDuration - duration))
        }
        return score
    }

    // MARK: - 更新当前行

    func updateCurrentLine(elapsedTime: TimeInterval) {
        guard !lyrics.isEmpty else {
            currentLine = ""
            return
        }

        // 保留负时间，才能让零秒首句也正确延后显示。
        let lyricTime = elapsedTime - lyricsOffset
        // 前奏阶段：早于第一句歌词时不显示
        guard lyricTime >= lyrics[0].time else {
            currentLine = ""
            return
        }

        // 找到当前时间对应的歌词行（二分查找）
        var lo = 0, hi = lyrics.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lyrics[mid].time <= lyricTime {
                lo = mid
            } else {
                hi = mid - 1
            }
        }
        currentLine = lyrics[lo].text
    }

    /// 重置（切歌时调用）
    func reset() {
        fetchTask?.cancel()
        lyrics = []
        plainLyricsText = ""
        currentLine = ""
        currentTitle = ""
        currentArtist = ""
        currentAlbum = ""
        currentDuration = nil
        lookupDuration = nil
        currentMatch = nil
        durationRevalidationPending = false
        hasRevalidatedDuration = false
        refreshNotice = nil
        retryAfter = nil
        manualRetryAfter = nil
        consecutiveFailures = 0
        isFetching = false
        status = defaults.bool(forKey: "showLyrics") ? .idle : .disabled
        fetchGeneration += 1  // 使旧的异步请求失效
        // reset 后 hasLyrics 变 false，通知 MediaManager 停止 timer（避免空转）
        notifyStateChanged()
    }
}

// MARK: - LRCLIB API Response

struct LrcResponse: Codable {
    let trackName: String?
    let artistName: String?
    let duration: TimeInterval?
    let syncedLyrics: String?
    let plainLyrics: String?

    var hasLyrics: Bool {
        syncedLyrics?.isEmpty == false || plainLyrics?.isEmpty == false
    }

    var hasSyncedLyrics: Bool {
        syncedLyrics?.isEmpty == false
    }
}
