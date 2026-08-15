import Foundation

/// LRC 磁盘缓存 — 切回已放过的歌秒出歌词，避免每次都走网络。
///
/// 设计要点：
/// - 缓存 key 用归一化后的 title/artist/album 组合，对空格/大小写/标点鲁棒
/// - 读写都在串行后台队列执行，不阻塞 UI
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
        /// 生成该条目的原始 key。文件名只是 key 的 64 位哈希，碰撞时两首歌会落到
        /// 同一个文件；读取时比对 key 才能发现碰撞，否则表现为"某首歌固定显示
        /// 另一首歌的歌词"且不会自愈。
        let key: String
    }

    private static let maxCacheBytes: Int = 5 * 1024 * 1024
    /// 触发清理后删到该水位（上限的 80%）。留出迟滞，否则缓存写满后每次写入都会
    /// 刚好越过上限、再删到上限，导致每写一次就全目录扫描一轮。
    private static let evictTargetBytes: Int = maxCacheBytes * 8 / 10
    /// 缓存有效期：歌词内容本身稳定，但匹配错误或已损坏的条目不该永久驻留
    private static let maxAge: TimeInterval = 30 * 24 * 60 * 60
    private static let cacheDirName = "XNook/lyrics-cache"
    /// 串行 IO 队列：写入与 LRU 清理排队执行，避免多个 evict 并发互相踩踏
    private static let ioQueue = DispatchQueue(label: "com.xnook.lyrics-cache", qos: .utility)

    /// 缓存根目录覆写入口，仅供测试使用。
    /// 测试若直接写用户真实的 Caches 目录，不但会留下垃圾文件，
    /// 触发的 LRU 清理还会删掉用户自己的歌词缓存。
    static var cacheDirectoryOverride: URL?

    // MARK: - Public API

    /// 后台读取缓存 — 供 MainActor 调用方使用，避免在主线程上做阻塞 IO
    static func readAsync(
        title: String,
        artist: String,
        album: String? = nil
    ) async -> Entry? {
        await withCheckedContinuation { continuation in
            ioQueue.async {
                continuation.resume(returning: read(title: title, artist: artist, album: album))
            }
        }
    }

    /// 读取缓存：命中返回 Entry；未命中、哈希碰撞、已过期或 IO 失败均返回 nil
    /// album 可选：传入则参与 key 区分跨专辑版本，nil 则忽略
    static func read(
        title: String,
        artist: String,
        album: String? = nil
    ) -> Entry? {
        let key = cacheKey(title: title, artist: artist, album: album)
        guard let url = fileURL(for: key) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let entry = try? JSONDecoder().decode(Entry.self, from: data) else { return nil }
        // 哈希碰撞：文件里存的是另一首歌，当作未命中，交给网络重新获取并覆盖
        guard entry.key == key else { return nil }
        // 过期条目同样当作未命中
        guard Date().timeIntervalSince(entry.fetchedAt) < maxAge else { return nil }
        // 命中即刷新访问时间（mtime），LRU 清理时优先删旧文件。
        // 这只是给 LRU 的提示，失败无所谓，因此异步执行、不阻塞返回。
        ioQueue.async {
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
        type: EntryType,
        payload: String
    ) {
        let key = cacheKey(title: title, artist: artist, album: album)
        guard let url = fileURL(for: key) else { return }
        let entry = Entry(type: type, payload: payload, fetchedAt: Date(), key: key)
        ioQueue.async {
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

    /// 归一化键：小写 + 仅保留字母数字 + 拼接 album（若有）
    ///
    /// 不含 duration：duration 往往比曲目信息晚一拍到达，若参与 key，同一首歌会先以
    /// "无 duration"写一份、拿到 duration 后再写一份，既产生重复文件，又让后续查询
    /// 必然未命中。曲目版本的区分交给 album，duration 只用于 LRCLIB 候选打分。
    ///
    /// 对 "G.E.M. 邓紫棋" vs "邓紫棋" 这种 LRCLIB 别名场景不试图归并，
    /// 因为该归并由 LRCLIB 服务端负责；客户端只对"完全相同的查询"做缓存
    static func cacheKey(
        title: String,
        artist: String,
        album: String? = nil
    ) -> String {
        var key = normalize(title) + "|" + normalize(artist)
        if let album, !album.trimmingCharacters(in: .whitespaces).isEmpty {
            key += "|" + normalize(album)
        }
        return key
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased().unicodeScalars
            .filter(CharacterSet.alphanumerics.contains)
            .map(String.init)
            .joined()
    }

    private static func cacheDirectory() -> URL? {
        if let cacheDirectoryOverride { return cacheDirectoryOverride }
        guard let cacheRoot = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else { return nil }
        return cacheRoot.appendingPathComponent(cacheDirName, isDirectory: true)
    }

    /// 文件名：key 的哈希，避免特殊字符在文件系统中出问题
    /// 碰撞由 Entry.key 在读取时兜底校验
    private static func fileURL(for key: String) -> URL? {
        guard let dir = cacheDirectory() else { return nil }
        // 简单稳定的哈希：用 Foundation 的 djb2 变种，避免引入 CryptoKit 仅为此一处
        var hash: UInt64 = 5381
        for byte in key.utf8 {
            hash = (hash &* 33) ^ UInt64(byte)
        }
        let fileName = String(hash, radix: 16) + ".json"
        return dir.appendingPathComponent(fileName)
    }

    // MARK: - LRU 清理

    /// 缓存目录超过上限时，按修改时间从旧到新删除，直到降到 evictTargetBytes
    private static func evictIfNeeded() {
        guard let dir = cacheDirectory() else { return }

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
            guard remaining > evictTargetBytes else { break }
            try? FileManager.default.removeItem(at: entry.url)
            remaining -= entry.size
        }
    }
}
