import Foundation
import Observation

/// 歌词管理器 — 从 LRCLIB 获取同步歌词，解析 LRC 格式
@Observable @MainActor
final class LyricsManager {
    var currentLine: String = ""
    var isFetching = false

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
            "[music]",
            "♪",
            "·"
        ]
        return placeholders.contains(lower) || lower.contains("instrumental")
    }

    private var lyrics: [LrcLine] = []
    private var currentTitle = ""
    private var currentArtist = ""
    private var currentAlbum = ""
    /// 上次请求所用的 duration，用于判断"duration 迟到"是否值得重试一次
    private var currentDuration: TimeInterval?
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
        // 检查歌词功能是否开启（默认开启，可在设置中关闭）
        let lyricsEnabled = UserDefaults.standard.bool(forKey: "showLyrics")
        guard lyricsEnabled else {
            lyrics = []
            plainLyricsText = ""
            currentLine = ""
            return
        }

        let identityChanged = title != currentTitle
            || artist != currentArtist
            || album != currentAlbum
        // duration 常常比曲目信息晚一拍到达，缺 duration 时 LRCLIB 的精确匹配用不上。
        // 因此仅在"还没拿到任何歌词"时允许 duration 到位后重试一次；
        // 已有歌词就不必为 duration 变化重复请求。
        let shouldRetryWithDuration = duration != currentDuration
            && lyrics.isEmpty
            && plainLyricsText.isEmpty
        guard !title.isEmpty, identityChanged || shouldRetryWithDuration else { return }
        currentTitle = title
        currentArtist = artist
        currentAlbum = album
        currentDuration = duration
        lyrics = []
        plainLyricsText = ""
        currentLine = ""
        isFetching = true
        fetchGeneration += 1  // 递增代际标识
        let generation = fetchGeneration  // 捕获当前代际

        // 取消旧的歌词请求
        fetchTask?.cancel()

        fetchTask = Task {
            // 先尝试磁盘缓存：命中即出，避免网络往返。
            // 读取放到后台队列 —— JSON 解码与 mtime 刷新都是阻塞 syscall，
            // 在 MainActor 上执行会在磁盘繁忙时卡掉 UI 帧。
            let cached = await LyricsCache.readAsync(title: title, artist: artist, album: album)
            guard generation == self.fetchGeneration else { return }
            // apply 返回 false 表示缓存内容解析后为空（数据损坏/曾写入坏数据），
            // 此时不能直接返回，否则该曲目会永远卡在坏缓存上，落回网络重新获取。
            if let cached, self.apply(entry: cached) {
                self.isFetching = false
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
                        duration: duration
                    )
                    break
                } catch {
                    // 切歌或取消：立即退出不重试
                    if generation != self.fetchGeneration || Task.isCancelled { break }
                    lastError = error
                    // 最后一次失败、或错误本身不可恢复（解码失败、HTTP 语义错误）都不重试
                    guard attempt < maxAttempts, Self.isRetryable(error) else { break }
                    // 退避 1s 后重试
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if generation != self.fetchGeneration { break }
                }
            }

            // 代际检查：如果切歌了，丢弃本次结果
            guard generation == self.fetchGeneration else { return }

            if let decoded {
                if let synced = decoded.syncedLyrics, !synced.isEmpty {
                    self.lyrics = Self.parseLrc(synced)
                    self.plainLyricsText = ""
                    LyricsCache.write(
                        title: title,
                        artist: artist,
                        album: album,
                        type: .synced,
                        payload: synced
                    )
                } else if let plain = decoded.plainLyrics, !plain.isEmpty {
                    // 无同步时间轴：保留纯歌词全文供 UI 兜底显示
                    self.lyrics = []
                    self.plainLyricsText = plain
                    LyricsCache.write(
                        title: title,
                        artist: artist,
                        album: album,
                        type: .plain,
                        payload: plain
                    )
                } else {
                    self.lyrics = []
                    self.plainLyricsText = ""
                }
                self.isFetching = false
                // 网络加载完成：歌词就位（或确认无歌词），通知 MediaManager 评估 timer
                self.notifyStateChanged()
            } else {
                // 全部重试失败：不影响功能（ticker 回退到标题显示）。
                // 但要留下痕迹，否则线上"没歌词"完全无从判断是网络问题还是确无歌词。
                // 只打印错误本身，不打印曲目信息，避免把用户的听歌记录写进日志。
                if let lastError {
                    print("[Lyrics] 歌词获取失败: \(lastError.localizedDescription)")
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
        switch entry.type {
        case .synced:
            let parsed = Self.parseLrc(entry.payload)
            guard !parsed.isEmpty else { return false }
            lyrics = parsed
            plainLyricsText = ""
        case .plain:
            guard !entry.payload.isEmpty else { return false }
            lyrics = []
            plainLyricsText = entry.payload
        }
        currentLine = ""
        return true
    }

    static func bestSearchResult(
        from candidates: [LrcResponse],
        title: String,
        artist: String,
        duration: TimeInterval?
    ) -> LrcResponse? {
        let normalizedTitle = normalize(title)
        let normalizedArtist = normalize(artist)
        // 注意：coreTitle 必须从原始标题提取。normalize 会剥掉括号，
        // 先 normalize 再找括号永远找不到，第二/三轮会退化成第一轮的重复。
        let coreTitle = Self.coreTitle(title)

        // 第一轮：严格匹配（完整 normalize 字符串双向 contains）
        let strict = candidates.filter { candidate in
            matches(candidate, normalizedTitle: normalizedTitle, normalizedArtist: normalizedArtist)
        }
        if let best = strict.max(by: { searchScore($0, duration: duration) < searchScore($1, duration: duration) }) {
            return best
        }

        // 第二轮：核心歌名匹配（去括号后比较）—— 解决括号内版本/来源标注不匹配
        // 例：Music "光亮 (大型纪录片...主题歌)" vs LRCLIB "光亮 (大型紀錄片...主題歌)"
        guard !coreTitle.isEmpty else { return nil }
        let core = candidates.filter { candidate in
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
        let coverMatch = candidates.filter { candidate in
            guard candidate.hasLyrics else { return false }
            guard let candidateDuration = candidate.duration else { return false }
            guard Self.coreTitle(candidate.trackName ?? "") == coreTitle else { return false }
            // duration 容差 ±15s，避免同名不同歌
            return abs(candidateDuration - duration) <= 15
        }
        return coverMatch.max(by: { searchScore($0, duration: duration) < searchScore($1, duration: duration) })
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
        duration: TimeInterval?
    ) async throws -> LrcResponse? {
        try Task.checkCancellation()

        if let duration,
           shouldUseExactLookup(album: album, duration: duration),
           let exactURL = exactLyricsURL(title: title, artist: artist, album: album, duration: duration) {
            let (exactData, exactResponse) = try await URLSession.shared.data(for: request(for: exactURL))
            try Task.checkCancellation()
            if let exactHTTP = exactResponse as? HTTPURLResponse, exactHTTP.statusCode == 200 {
                let exactResult = try JSONDecoder().decode(LrcResponse.self, from: exactData)
                if exactResult.hasSyncedLyrics {
                    return exactResult
                }
            }
        }

        guard let searchURL = searchLyricsURL(title: title, artist: artist) else {
            return nil
        }

        try Task.checkCancellation()
        let (searchData, searchResponse) = try await URLSession.shared.data(for: request(for: searchURL))
        try Task.checkCancellation()
        guard let searchHTTP = searchResponse as? HTTPURLResponse,
              searchHTTP.statusCode == 200 else {
            return nil
        }
        let candidates = try JSONDecoder().decode([LrcResponse].self, from: searchData)
        var best = bestSearchResult(
            from: candidates,
            title: title,
            artist: artist,
            duration: duration
        )

        // 兜底：track_name+artist_name 搜索无匹配结果时，用 q= 全文搜索重试
        // LRCLIB 两个端点索引不同，q= 能命中更多中文/跨语言变体
        if best == nil, let fallbackURL = fallbackSearchURL(title: title, artist: artist) {
            try Task.checkCancellation()
            let (fbData, fbResponse) = try await URLSession.shared.data(for: request(for: fallbackURL))
            try Task.checkCancellation()
            if let fbHTTP = fbResponse as? HTTPURLResponse, fbHTTP.statusCode == 200 {
                let fbCandidates = try JSONDecoder().decode([LrcResponse].self, from: fbData)
                best = bestSearchResult(
                    from: fbCandidates,
                    title: title,
                    artist: artist,
                    duration: duration
                )
            }
        }

        return best
    }

    private static let lyricsAPIBaseURL = "https://lrclib.net/api"

    static func shouldUseExactLookup(album: String, duration: TimeInterval?) -> Bool {
        !album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (duration ?? 0) > 0
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
        var score = candidate.syncedLyrics?.isEmpty == false ? 100.0 : 0.0
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

        // 前奏阶段：早于第一句歌词时不显示
        guard elapsedTime >= lyrics[0].time else {
            currentLine = ""
            return
        }

        // 找到当前时间对应的歌词行（二分查找）
        var lo = 0, hi = lyrics.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lyrics[mid].time <= elapsedTime {
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
        isFetching = false
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
