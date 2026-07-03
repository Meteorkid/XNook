import Foundation

/// 歌词管理器 — 从 LRCLIB 获取同步歌词，解析 LRC 格式
@MainActor
final class LyricsManager: ObservableObject {
    @Published var currentLine: String = ""
    @Published var isFetching = false

    private var lyrics: [LrcLine] = []
    private var currentTitle = ""
    private var currentArtist = ""
    /// 代际标识：每次切歌递增，防止旧异步请求覆盖新状态
    private var fetchGeneration: Int = 0
    /// 当前歌词请求任务，用于取消旧请求
    private var fetchTask: Task<Void, Never>?

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
            // 匹配 [mm:ss.xx] 或 [mm:ss.xxx] 或 [mm:ss]
            guard let match = trimmed.firstMatch(of: #/\[(\d+):(\d+\.?\d*)\](.*)/#) else { continue }
            let min = Double(match.1) ?? 0
            let sec = Double(match.2) ?? 0
            let text = String(match.3).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            lines.append(LrcLine(time: min * 60 + sec, text: text))
        }
        return lines.sorted { $0.time < $1.time }
    }

    // MARK: - 获取歌词

    func fetchLyrics(title: String, artist: String, duration: TimeInterval? = nil) {
        // 检查歌词功能是否开启（默认关闭，保护隐私）
        let lyricsEnabled = UserDefaults.standard.bool(forKey: "showLyrics")
        guard lyricsEnabled else {
            lyrics = []
            currentLine = ""
            return
        }

        guard !title.isEmpty, title != currentTitle || artist != currentArtist else { return }
        currentTitle = title
        currentArtist = artist
        lyrics = []
        currentLine = ""
        isFetching = true
        fetchGeneration += 1  // 递增代际标识
        let generation = fetchGeneration  // 捕获当前代际

        // 取消旧的歌词请求
        fetchTask?.cancel()

        fetchTask = Task {
            do {
                guard let decoded = try await Self.fetchResponse(
                    title: title,
                    artist: artist,
                    duration: duration
                ) else {
                    // 代际不匹配时不要修改状态
                    if generation == self.fetchGeneration {
                        self.isFetching = false
                    }
                    return
                }

                // 代际检查：如果切歌了，丢弃本次结果
                guard generation == self.fetchGeneration else { return }
                if let synced = decoded.syncedLyrics, !synced.isEmpty {
                    self.lyrics = Self.parseLrc(synced)
                } else if let plain = decoded.plainLyrics, !plain.isEmpty {
                    // 无时间轴歌词，用纯文本逐行显示
                    self.lyrics = plain.components(separatedBy: .newlines).enumerated().map { i, line in
                        LrcLine(time: TimeInterval(i) * 4, text: line)
                    }
                }
                self.isFetching = false
            } catch {
                if generation == self.fetchGeneration {
                    self.isFetching = false
                }
            }
        }
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
        duration: TimeInterval?
    ) async throws -> LrcResponse? {
        try Task.checkCancellation()

        guard let exactURL = lyricsURL(path: "get", title: title, artist: artist) else {
            return nil
        }
        let (exactData, exactResponse) = try await URLSession.shared.data(for: request(for: exactURL))
        try Task.checkCancellation()
        guard let exactHTTP = exactResponse as? HTTPURLResponse else { return nil }

        if exactHTTP.statusCode == 200 {
            return try JSONDecoder().decode(LrcResponse.self, from: exactData)
        }
        guard exactHTTP.statusCode == 404,
              let searchURL = lyricsURL(path: "search", title: title, artist: artist) else {
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

    private static func lyricsURL(path: String, title: String, artist: String) -> URL? {
        var components = URLComponents(string: "https://lrclib.net/api/\(path)")
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
        currentLine = ""
        currentTitle = ""
        currentArtist = ""
        isFetching = false
        fetchGeneration += 1  // 使旧的异步请求失效
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
}
