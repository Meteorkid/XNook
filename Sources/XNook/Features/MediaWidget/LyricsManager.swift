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

        guard !title.isEmpty,
              (title != currentTitle || artist != currentArtist || album != currentAlbum)
        else { return }
        currentTitle = title
        currentArtist = artist
        currentAlbum = album
        lyrics = []
        plainLyricsText = ""
        currentLine = ""
        isFetching = true
        fetchGeneration += 1  // 递增代际标识
        let generation = fetchGeneration  // 捕获当前代际

        // 取消旧的歌词请求
        fetchTask?.cancel()

        // 先尝试磁盘缓存：命中即出，避免网络往返
        // 缓存命中后仍允许后台刷新（最新版本），但前台体验由缓存主导
        if let cached = LyricsCache.read(title: title, artist: artist, album: album, duration: duration),
           generation == fetchGeneration {
            apply(entry: cached)
            self.isFetching = false
            // 缓存命中后立刻通知 MediaManager 评估 timer：歌词已就位，可以推进
            notifyStateChanged()
            // 命中缓存后即返回：网络刷新作为可选优化留给后台，避免重复请求
            // （LRCLIB 数据稳定，没必要每次都刷新）
            return
        }

        fetchTask = Task {
            // 网络偶发失败时有限重试：切歌瞬间网络抖动不应让整首歌没歌词。
            // 404/无数据 不重试（确无歌词）；仅对可恢复错误（超时、连接失败）重试。
            let maxAttempts = 2
            var lastError: Error?
            var decoded: LrcResponse?
            for attempt in 1...maxAttempts {
                do {
                    decoded = try await Self.fetchResponse(
                        title: title,
                        artist: artist,
                        album: album,
                        duration: duration
                    )
                    lastError = nil
                    break
                } catch {
                    lastError = error
                    // 切歌或取消：立即退出不重试
                    if generation != self.fetchGeneration || Task.isCancelled { break }
                    // 最后一次失败也不重试
                    if attempt == maxAttempts { break }
                    // 指数退避：1s → 2s
                    let delay = UInt64(attempt) * 1_000_000_000
                    try? await Task.sleep(nanoseconds: delay)
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
                        duration: duration,
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
                        duration: duration,
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
                // 全部重试失败：记录但不影响功能（ticker 回退到标题显示）
                _ = lastError
                self.isFetching = false
                // 加载失败也要通知：让 timer 评估在没有歌词时是否应停止
                self.notifyStateChanged()
            }
        }
    }

    /// 把缓存项应用到当前状态（同步歌词解析时间轴；纯歌词保留全文）
    private func apply(entry: LyricsCache.Entry) {
        switch entry.type {
        case .synced:
            lyrics = Self.parseLrc(entry.payload)
            plainLyricsText = ""
        case .plain:
            lyrics = []
            plainLyricsText = entry.payload
        }
        currentLine = ""
    }

    static func bestSearchResult(
        from candidates: [LrcResponse],
        title: String,
        artist: String,
        duration: TimeInterval?
    ) -> LrcResponse? {
        let normalizedTitle = normalize(title)
        let normalizedArtist = normalize(artist)

        return candidates
            .filter { candidate in
                guard candidate.hasLyrics else { return false }
                let candidateTitle = normalize(candidate.trackName ?? "")
                let candidateArtist = normalize(candidate.artistName ?? "")
                let titleMatches = candidateTitle == normalizedTitle
                    || candidateTitle.contains(normalizedTitle)
                    || normalizedTitle.contains(candidateTitle)
                let artistMatches = normalizedArtist.isEmpty
                    || candidateArtist.contains(normalizedArtist)
                    || normalizedArtist.contains(candidateArtist)
                return titleMatches && artistMatches
            }
            .max { lhs, rhs in
                searchScore(lhs, duration: duration) < searchScore(rhs, duration: duration)
            }
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
        return bestSearchResult(
            from: candidates,
            title: title,
            artist: artist,
            duration: duration
        )
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
