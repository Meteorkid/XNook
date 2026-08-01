import Foundation

/// LRC 磁盘缓存 — 切回已放过的歌秒出歌词，避免每次都走网络。
///
/// 设计要点：
/// - 缓存 key 用归一化后的 title/artist/duration 组合，对空格/大小写/标点鲁棒
/// - 写入是异步的，不阻塞 UI；读取是同步的（命中即出）
/// - 失败容错：任何 IO 错误都不影响功能，仅记录缺失
/// - 缓存目录大小有上限（默认 5MB），LRU 清理避免无限增长
enum LyricsCache {
    /// 同步 + 纯歌词都缓存，区分类型
    enum EntryType: String, Codable {
        case synced
        case plain
    }

    struct Entry: Codable {
        let type: EntryType
        let payload: String  // LRC 全文或纯歌词全文
        let fetchedAt: Date
    }

    private static let maxCacheBytes: Int = 5 * 1024 * 1024
    private static let cacheDirName = "XNook/lyrics-cache"

    // MARK: - Public API

    /// 读取缓存：命中返回 Entry，未命中或失败返回 nil
    /// album 可选：传入则参与 key 区分跨专辑版本，nil 则忽略
    static func read(
        title: String,
        artist: String,
        album: String? = nil,
        duration: TimeInterval?
    ) -> Entry? {
        guard let url = fileURL(for: title, artist: artist, album: album, duration: duration) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let entry = try? JSONDecoder().decode(Entry.self, from: data)
        // 命中即更新访问时间（mtime），LRU 清理时优先删旧文件
        if entry != nil {
            try? FileManager.default.setAttributes(
                [.modificationDate: Date()],
                ofItemAtPath: url.path
            )
        }
        return entry
    }

    /// 写入缓存：异步执行，调用方无需 await
    static func write(
        title: String,
        artist: String,
        album: String? = nil,
        duration: TimeInterval?,
        type: EntryType,
        payload: String
    ) {
        guard let url = fileURL(for: title, artist: artist, album: album, duration: duration) else { return }
        let entry = Entry(type: type, payload: payload, fetchedAt: Date())
        DispatchQueue.global(qos: .utility).async {
            guard let data = try? JSONEncoder().encode(entry) else { return }
            // 目录不存在则创建
            let dir = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true
            )
            try? data.write(to: url, options: .atomic)
            evictIfNeeded()
        }
    }

    // MARK: - Key 生成

    /// 归一化键：小写 + 仅保留字母数字 + 拼接 album（若有） + duration 整数秒
    /// 对 "G.E.M. 邓紫棋" vs "邓紫棋" 这种 LRCLIB 别名场景不试图归并，
    /// 因为该归并由 LRCLIB 服务端负责；客户端只对"完全相同的查询"做缓存
    static func cacheKey(
        title: String,
        artist: String,
        album: String? = nil,
        duration: TimeInterval?
    ) -> String {
        var key = normalize(title) + "|" + normalize(artist)
        if let album, !album.trimmingCharacters(in: .whitespaces).isEmpty {
            key += "|" + normalize(album)
        }
        if let duration {
            key += "|" + String(Int(duration.rounded()))
        }
        return key
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased().unicodeScalars
            .filter(CharacterSet.alphanumerics.contains)
            .map(String.init)
            .joined()
    }

    /// 文件名：key 的哈希，避免特殊字符在文件系统中出问题
    private static func fileURL(
        for title: String,
        artist: String,
        album: String? = nil,
        duration: TimeInterval?
    ) -> URL? {
        guard let cacheRoot = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else { return nil }

        let key = cacheKey(title: title, artist: artist, album: album, duration: duration)
        // 简单稳定的哈希：用 Foundation 的 djb2 变种，避免引入 CryptoKit 仅为此一处
        var hash: UInt64 = 5381
        for byte in key.utf8 {
            hash = (hash &* 33) ^ UInt64(byte)
        }
        let fileName = String(hash, radix: 16) + ".json"
        return cacheRoot
            .appendingPathComponent(cacheDirName, isDirectory: true)
            .appendingPathComponent(fileName)
    }

    // MARK: - LRU 清理

    /// 缓存目录超过上限时，按修改时间从旧到新删除，直到低于上限
    private static func evictIfNeeded() {
        guard let cacheRoot = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else { return }
        let dir = cacheRoot.appendingPathComponent(cacheDirName, isDirectory: true)

        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return  // 目录不存在等
        }

        let entries: [(url: URL, mtime: Date, size: Int)] = urls.compactMap { url in
            guard let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey]
            ) else { return nil }
            return (
                url,
                values.contentModificationDate ?? .distantPast,
                values.fileSize ?? 0
            )
        }

        let total = entries.reduce(0) { $0 + $1.size }
        guard total > maxCacheBytes else { return }

        // 按 mtime 升序（最旧优先删）
        let sorted = entries.sorted { $0.mtime < $1.mtime }
        var remaining = total
        for entry in sorted {
            guard remaining > maxCacheBytes else { break }
            try? FileManager.default.removeItem(at: entry.url)
            remaining -= entry.size
        }
    }
}
