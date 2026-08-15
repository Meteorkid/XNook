import XCTest
@testable import XNook

@MainActor
final class LyricsCacheTests: XCTestCase {

    /// 每个用例独立的临时缓存目录。
    /// 绝不能让测试落到用户真实的 ~/Library/Caches：既会留下垃圾文件，
    /// 写入触发的 LRU 清理还会删掉用户自己的歌词缓存。
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LyricsCacheTests-\(UUID().uuidString)", isDirectory: true)
        LyricsCache.cacheDirectoryOverride = tempDir
    }

    override func tearDown() {
        LyricsCache.cacheDirectoryOverride = nil
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        super.tearDown()
    }

    // MARK: - cacheKey 归一化

    func testCacheKeyNormalizesCaseAndPunctuation() {
        let keyA = LyricsCache.cacheKey(title: "Hello!", artist: "World")
        let keyB = LyricsCache.cacheKey(title: "hello", artist: "WORLD")
        XCTAssertEqual(keyA, keyB, "大小写和标点差异应归一化为同一 key")
    }

    func testCacheKeyIncludesAlbum() {
        let keyDeluxe = LyricsCache.cacheKey(title: "Song", artist: "Artist", album: "Deluxe")
        let keyOriginal = LyricsCache.cacheKey(title: "Song", artist: "Artist", album: "Original")
        XCTAssertNotEqual(keyDeluxe, keyOriginal, "同曲不同专辑应区分缓存")
    }

    func testCacheKeyIgnoresEmptyAlbum() {
        let keyA = LyricsCache.cacheKey(title: "Song", artist: "Artist", album: "")
        let keyB = LyricsCache.cacheKey(title: "Song", artist: "Artist", album: nil)
        let keyC = LyricsCache.cacheKey(title: "Song", artist: "Artist")
        XCTAssertEqual(keyA, keyB, "空字符串 album 应与 nil 等价")
        XCTAssertEqual(keyB, keyC, "nil album 应与不传 album 等价")
    }

    // MARK: - 写入 / 读取往返

    // 写入与读取都排在同一条串行 IO 队列上，readAsync 必然晚于先前的 write 执行，
    // 因此不需要 sleep 等待——那种等法在 CI 负载高时会 flaky。

    func testWriteThenReadReturnsSyncedEntry() async {
        LyricsCache.write(
            title: "Song",
            artist: "Tester",
            type: .synced,
            payload: "[00:01.00]Hello"
        )

        let entry = await LyricsCache.readAsync(title: "Song", artist: "Tester")
        XCTAssertEqual(entry?.type, .synced)
        XCTAssertEqual(entry?.payload, "[00:01.00]Hello")
    }

    func testWriteThenReadReturnsPlainEntry() async {
        LyricsCache.write(
            title: "Song",
            artist: "Tester",
            type: .plain,
            payload: "Plain lyrics here"
        )

        let entry = await LyricsCache.readAsync(title: "Song", artist: "Tester")
        XCTAssertEqual(entry?.type, .plain)
        XCTAssertEqual(entry?.payload, "Plain lyrics here")
    }

    func testReadMissingReturnsNil() async {
        let entry = await LyricsCache.readAsync(title: "DefinitelyNotExists", artist: "Nobody")
        XCTAssertNil(entry)
    }

    func testDurationDoesNotAffectLookup() async {
        // duration 不参与 key：它常常比曲目信息晚一拍到达，
        // 若参与 key 会先后写两份文件，且第二次查询必然未命中。
        LyricsCache.write(
            title: "Song",
            artist: "Tester",
            type: .synced,
            payload: "[00:01.00]Hello"
        )

        let entry = await LyricsCache.readAsync(title: "Song", artist: "Tester")
        XCTAssertNotNil(entry, "duration 到位前后应命中同一条缓存")

        let files = try? FileManager.default.contentsOfDirectory(
            at: tempDir,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(files?.count, 1, "同一首歌不应产生多份缓存文件")
    }

    // MARK: - 哈希碰撞与过期

    func testEntryWithMismatchedKeyIsTreatedAsMiss() async throws {
        LyricsCache.write(
            title: "Song",
            artist: "Tester",
            type: .synced,
            payload: "[00:01.00]Correct"
        )
        _ = await LyricsCache.readAsync(title: "Song", artist: "Tester")

        // 模拟哈希碰撞：文件还在原位，但里面存的是另一首歌的条目。
        // 没有 key 校验的话，"Song" 会永久读到别人的歌词且不会自愈。
        let fileURL = try XCTUnwrap(onlyCachedFile())
        let foreign = LyricsCache.Entry(
            type: .synced,
            payload: "[00:01.00]Someone else",
            fetchedAt: Date(),
            key: LyricsCache.cacheKey(title: "另一首歌", artist: "另一个人")
        )
        try JSONEncoder().encode(foreign).write(to: fileURL)

        let entry = await LyricsCache.readAsync(title: "Song", artist: "Tester")
        XCTAssertNil(entry, "key 不匹配说明发生哈希碰撞，应当作未命中")
    }

    func testExpiredEntryIsTreatedAsMiss() async throws {
        LyricsCache.write(
            title: "Song",
            artist: "Tester",
            type: .synced,
            payload: "[00:01.00]Stale"
        )
        _ = await LyricsCache.readAsync(title: "Song", artist: "Tester")

        let fileURL = try XCTUnwrap(onlyCachedFile())
        let stale = LyricsCache.Entry(
            type: .synced,
            payload: "[00:01.00]Stale",
            fetchedAt: Date(timeIntervalSinceNow: -60 * 24 * 60 * 60),  // 60 天前
            key: LyricsCache.cacheKey(title: "Song", artist: "Tester")
        )
        try JSONEncoder().encode(stale).write(to: fileURL)

        let entry = await LyricsCache.readAsync(title: "Song", artist: "Tester")
        XCTAssertNil(entry, "超过有效期的条目应当作未命中，让网络结果覆盖它")
    }

    private func onlyCachedFile() -> URL? {
        try? FileManager.default.contentsOfDirectory(
            at: tempDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).first
    }

    // MARK: - EntryType 编解码

    func testEntryTypeRoundTrip() throws {
        let entry = LyricsCache.Entry(
            type: .synced,
            payload: "[00:00.00]Test",
            fetchedAt: Date(timeIntervalSince1970: 1000),
            key: "song|artist"
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(LyricsCache.Entry.self, from: data)
        XCTAssertEqual(decoded.type, .synced)
        XCTAssertEqual(decoded.payload, "[00:00.00]Test")
        XCTAssertEqual(decoded.fetchedAt.timeIntervalSince1970, 1000, accuracy: 0.01)
        XCTAssertEqual(decoded.key, "song|artist")
    }
}
