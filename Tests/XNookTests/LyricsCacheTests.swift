import XCTest
@testable import XNook

@MainActor
final class LyricsCacheTests: XCTestCase {

    // MARK: - cacheKey 归一化

    func testCacheKeyNormalizesCaseAndPunctuation() {
        let keyA = LyricsCache.cacheKey(title: "Hello!", artist: "World", duration: 180)
        let keyB = LyricsCache.cacheKey(title: "hello", artist: "WORLD", duration: 180)
        XCTAssertEqual(keyA, keyB, "大小写和标点差异应归一化为同一 key")
    }

    func testCacheKeyIncludesDuration() {
        let keyA = LyricsCache.cacheKey(title: "Song", artist: "Artist", duration: 180)
        let keyB = LyricsCache.cacheKey(title: "Song", artist: "Artist", duration: 200)
        XCTAssertNotEqual(keyA, keyB, "时长不同的同名曲应区分缓存")
    }

    func testCacheKeyIncludesAlbum() {
        let keyDeluxe = LyricsCache.cacheKey(title: "Song", artist: "Artist", album: "Deluxe", duration: 180)
        let keyOriginal = LyricsCache.cacheKey(title: "Song", artist: "Artist", album: "Original", duration: 180)
        XCTAssertNotEqual(keyDeluxe, keyOriginal, "同曲不同专辑应区分缓存")
    }

    func testCacheKeyIgnoresEmptyAlbum() {
        let keyA = LyricsCache.cacheKey(title: "Song", artist: "Artist", album: "", duration: 180)
        let keyB = LyricsCache.cacheKey(title: "Song", artist: "Artist", album: nil, duration: 180)
        let keyC = LyricsCache.cacheKey(title: "Song", artist: "Artist", duration: 180)
        XCTAssertEqual(keyA, keyB, "空字符串 album 应与 nil 等价")
        XCTAssertEqual(keyB, keyC, "nil album 应与不传 album 等价")
    }

    func testCacheKeyNilDurationMatches() {
        let keyA = LyricsCache.cacheKey(title: "Song", artist: "Artist", duration: nil)
        let keyB = LyricsCache.cacheKey(title: "Song", artist: "Artist", duration: nil)
        XCTAssertEqual(keyA, keyB)
    }

    // MARK: - 写入 / 读取往返

    func testWriteThenReadReturnsSyncedEntry() {
        let title = "CacheTestSync_\(UUID().uuidString)"
        LyricsCache.write(
            title: title,
            artist: "Tester",
            duration: 100,
            type: .synced,
            payload: "[00:01.00]Hello"
        )
        // 等待异步写入
        let exp = expectation(description: "wait write")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { exp.fulfill() }
        wait(for: [exp], timeout: 2.0)

        let entry = LyricsCache.read(title: title, artist: "Tester", duration: 100)
        XCTAssertEqual(entry?.type, .synced)
        XCTAssertEqual(entry?.payload, "[00:01.00]Hello")
    }

    func testWriteThenReadReturnsPlainEntry() {
        let title = "CacheTestPlain_\(UUID().uuidString)"
        LyricsCache.write(
            title: title,
            artist: "Tester",
            duration: nil,
            type: .plain,
            payload: "Plain lyrics here"
        )
        let exp = expectation(description: "wait write")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { exp.fulfill() }
        wait(for: [exp], timeout: 2.0)

        let entry = LyricsCache.read(title: title, artist: "Tester", duration: nil)
        XCTAssertEqual(entry?.type, .plain)
        XCTAssertEqual(entry?.payload, "Plain lyrics here")
    }

    func testReadMissingReturnsNil() {
        let entry = LyricsCache.read(
            title: "DefinitelyNotExists_\(UUID().uuidString)",
            artist: "Nobody",
            duration: 999
        )
        XCTAssertNil(entry)
    }

    // MARK: - EntryType 编解码

    func testEntryTypeRoundTrip() throws {
        let entry = LyricsCache.Entry(
            type: .synced,
            payload: "[00:00.00]Test",
            fetchedAt: Date(timeIntervalSince1970: 1000)
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(LyricsCache.Entry.self, from: data)
        XCTAssertEqual(decoded.type, .synced)
        XCTAssertEqual(decoded.payload, "[00:00.00]Test")
        XCTAssertEqual(decoded.fetchedAt.timeIntervalSince1970, 1000, accuracy: 0.01)
    }
}
