import Foundation

/// 歌词管理器 — 从 LRCLIB 获取同步歌词，解析 LRC 格式
@MainActor
final class LyricsManager: ObservableObject {
    @Published var currentLine: String = ""
    @Published var isFetching = false

    private var lyrics: [LrcLine] = []
    private var currentTitle = ""
    private var currentArtist = ""

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

    func fetchLyrics(title: String, artist: String) {
        guard !title.isEmpty, title != currentTitle || artist != currentArtist else { return }
        currentTitle = title
        currentArtist = artist
        lyrics = []
        currentLine = ""
        isFetching = true

        // 使用 URLComponents 构建请求（Foundation 会正确处理 URL 编码）
        var components = URLComponents(string: "https://lrclib.net/api/get")!
        components.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist)
        ]
        guard let url = components.url else {
            isFetching = false
            return
        }

        var request = URLRequest(url: url)
        request.setValue("XNook/1.0 (macOS Dynamic Island tool center)", forHTTPHeaderField: "User-Agent")

        Task {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    await MainActor.run { self.isFetching = false }
                    return
                }

                let decoded = try JSONDecoder().decode(LrcResponse.self, from: data)
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
                await MainActor.run { self.isFetching = false }
            }
        }
    }

    // MARK: - 更新当前行

    func updateCurrentLine(elapsedTime: TimeInterval) {
        guard !lyrics.isEmpty else {
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
        lyrics = []
        currentLine = ""
        currentTitle = ""
        currentArtist = ""
    }
}

// MARK: - LRCLIB API Response

private struct LrcResponse: Codable {
    let syncedLyrics: String?
    let plainLyrics: String?
}
