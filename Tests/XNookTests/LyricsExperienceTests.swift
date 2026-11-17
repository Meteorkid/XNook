import XCTest
@testable import XNook

@MainActor
final class LyricsExperienceTests: XCTestCase {
    func testOffsetSurvivesResetAndTrackChange() async {
        let fixture = LyricsExperienceFixture()
        let manager = fixture.manager(cached: fixture.entry(.synced, payload: "[00:00.00]Line"))
        manager.lyricsOffset = 1.2
        await fetch(manager)
        manager.reset()
        XCTAssertEqual(manager.lyricsOffset, 1.2)
        manager.fetchLyrics(title: "Another song", artist: "Artist", album: "Album", duration: 180)
        await waitForLookup(manager)
        XCTAssertEqual(manager.lyricsOffset, 1.2)
        manager.updateCurrentLine(elapsedTime: 1)
        XCTAssertEqual(manager.currentLine, "")
        manager.updateCurrentLine(elapsedTime: 1.2)
        XCTAssertEqual(manager.currentLine, "Line")
    }

    func testReturningToSameTrackRejectsOldStatusAndResponse() async throws {
        let fixture = LyricsExperienceFixture()
        let started = expectation(description: "First A lookup pending")
        var pending: CheckedContinuation<(Data, URLResponse), Error>?
        var initialRequest: URLRequest?
        var requests = 0
        let manager = fixture.manager { request in
            requests += 1
            if requests == 1 {
                initialRequest = request
                return try await withCheckedThrowingContinuation {
                    pending = $0
                    started.fulfill()
                }
            }
            return Self.response(request, json: #"{"syncedLyrics":"[00:00.00]Current line"}"#)
        }
        manager.fetchLyrics(title: "A", artist: "Artist", album: "Album", duration: 180)
        await fulfillment(of: [started], timeout: 1)
        manager.fetchLyrics(title: "B", artist: "Artist", album: "Album", duration: 180)
        await waitForLookup(manager)
        manager.fetchLyrics(title: "A", artist: "Artist", album: "Album", duration: 180)
        await waitForLookup(manager)
        manager.updateCurrentLine(elapsedTime: 1)
        let staleChange = expectation(description: "Old A must not change new A state")
        staleChange.isInverted = true
        manager.onLyricsStateChanged = { staleChange.fulfill() }
        try XCTUnwrap(pending).resume(returning: Self.response(try XCTUnwrap(initialRequest),
            json: #"{"plainLyrics":"Old plain result"}"#))
        await fulfillment(of: [staleChange], timeout: 0.1)
        manager.onLyricsStateChanged = nil
        XCTAssertEqual(manager.status, .synced)
        XCTAssertFalse(manager.isFetching)
        XCTAssertEqual(manager.currentLine, "Current line")
        XCTAssertEqual(manager.plainLyricsText, "")
    }

    func testOffsetDefaultsToZeroAndLoadsPersistedValue() {
        let fixture = LyricsExperienceFixture()
        XCTAssertEqual(fixture.manager().lyricsOffset, 0)

        fixture.defaults.set(1.26, forKey: "lyricsOffset")
        XCTAssertEqual(fixture.manager().lyricsOffset, 1.3, accuracy: 0.0001)
    }

    func testPositiveOffsetDelaysZeroSecondFirstLine() async {
        let fixture = LyricsExperienceFixture()
        let manager = fixture.manager(cached: fixture.entry(.synced, payload: "[00:00.00]First line\n[00:02.00]Second line"))
        await fetch(manager)

        manager.lyricsOffset = 1
        manager.updateCurrentLine(elapsedTime: 0.5)
        XCTAssertEqual(manager.currentLine, "", "正偏移必须能延后零秒首句，不能把歌词时间钳制为零")
        manager.updateCurrentLine(elapsedTime: 1)
        XCTAssertEqual(manager.currentLine, "First line")
        manager.updateCurrentLine(elapsedTime: 2.5)
        XCTAssertEqual(manager.currentLine, "First line")
        manager.updateCurrentLine(elapsedTime: 3)
        XCTAssertEqual(manager.currentLine, "Second line")
    }

    func testZeroAndNegativeOffsetUseOriginalAndEarlierTimestamps() async {
        let fixture = LyricsExperienceFixture()
        let manager = fixture.manager(cached: fixture.entry(.synced, payload: "[00:02.00]First line\n[00:04.00]Second line"))
        await fetch(manager)

        manager.updateCurrentLine(elapsedTime: 1.9)
        XCTAssertEqual(manager.currentLine, "")
        manager.updateCurrentLine(elapsedTime: 2)
        XCTAssertEqual(manager.currentLine, "First line")
        manager.lyricsOffset = -1
        manager.updateCurrentLine(elapsedTime: 1)
        XCTAssertEqual(manager.currentLine, "First line")
        manager.updateCurrentLine(elapsedTime: 3)
        XCTAssertEqual(manager.currentLine, "Second line")
    }

    func testOffsetIsRoundedClampedPersistedAndNotifiesChanges() {
        let fixture = LyricsExperienceFixture()
        let manager = fixture.manager()
        var notifications = 0
        manager.onLyricsStateChanged = { notifications += 1 }

        for (input, expected) in [(1.26, 1.3), (-1.26, -1.3), (5.01, 5), (-5.01, -5)] {
            manager.lyricsOffset = input
            XCTAssertEqual(manager.lyricsOffset, expected, accuracy: 0.0001)
            XCTAssertEqual(fixture.defaults.double(forKey: "lyricsOffset"), expected, accuracy: 0.0001)
        }
        XCTAssertEqual(notifications, 4)
    }

    func testNonFiniteOffsetsResetToZero() {
        let fixture = LyricsExperienceFixture()
        let manager = fixture.manager()
        for input in [Double.nan, .infinity, -.infinity] {
            manager.lyricsOffset = 1
            manager.lyricsOffset = input
            XCTAssertEqual(manager.lyricsOffset, 0)
            XCTAssertEqual(fixture.defaults.double(forKey: "lyricsOffset"), 0)
        }
    }

    func testExternalOffsetChangeRefreshesCurrentLineImmediately() async {
        let fixture = LyricsExperienceFixture()
        let manager = fixture.manager(cached: fixture.entry(.synced, payload: "[00:00.00]First line\n[00:02.00]Second line"))
        await fetch(manager)
        manager.updateCurrentLine(elapsedTime: 2.5)
        XCTAssertEqual(manager.currentLine, "Second line")
        var notifications = 0
        manager.onLyricsStateChanged = {
            notifications += 1
            manager.updateCurrentLine(elapsedTime: 2.5)
        }

        fixture.defaults.set(1, forKey: "lyricsOffset")
        manager.refreshPreferences()

        XCTAssertEqual(manager.lyricsOffset, 1)
        XCTAssertEqual(manager.currentLine, "First line")
        XCTAssertEqual(notifications, 1)
        manager.refreshPreferences()
        XCTAssertEqual(notifications, 1, "设置未变化时不应重复通知")
        manager.onLyricsStateChanged = nil
    }

    func testOffsetDoesNotChangeCachedPayload() async {
        let fixture = LyricsExperienceFixture()
        let payload = "[00:00.00]First line\n[00:02.00]Second line"
        let manager = fixture.manager { request in
            let data = try JSONEncoder().encode(LrcResponse(trackName: "Song", artistName: "Artist", duration: 180,
                                                          syncedLyrics: payload, plainLyrics: nil))
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        manager.lyricsOffset = 1
        await fetch(manager)
        manager.updateCurrentLine(elapsedTime: 0.5)

        XCTAssertEqual(manager.currentLine, "")
        XCTAssertEqual(fixture.writes.count, 1)
        XCTAssertEqual(fixture.writes.first?.0, .synced)
        XCTAssertEqual(fixture.writes.first?.1, payload)
        manager.lyricsOffset = -1
        XCTAssertEqual(fixture.writes.count, 1)
    }

    func testManualRetryImmediatelyRetriesConfirmedNoMatch() async {
        let fixture = LyricsExperienceFixture()
        var lyricsAvailable = false
        let manager = fixture.manager { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            if request.url!.path.hasSuffix("/get") {
                XCTAssertEqual(query?.first(where: { $0.name == "track_name" })?.value, "Song")
                XCTAssertEqual(query?.first(where: { $0.name == "artist_name" })?.value, "Artist")
                XCTAssertEqual(query?.first(where: { $0.name == "album_name" })?.value, "Album")
            }
            if lyricsAvailable {
                return Self.response(request, json: #"{"syncedLyrics":"[00:00.00]Recovered line"}"#)
            }
            return Self.noMatch(request)
        }
        await fetch(manager)
        XCTAssertFalse(manager.shouldRetryCurrentTrack)
        lyricsAvailable = true

        let started = manager.retryCurrentTrack()
        XCTAssertTrue(started, "已确认无结果的同一首歌，第一次人工重试应立即发起")
        guard started else { return }
        await waitForLookup(manager)
        manager.updateCurrentLine(elapsedTime: 0)
        XCTAssertEqual(manager.currentLine, "Recovered line")
    }

    func testStatusReflectsInitialPreferencesAndReset() {
        let fixture = LyricsExperienceFixture()
        let manager = fixture.manager()
        XCTAssertEqual(manager.status, .idle)
        XCTAssertFalse(manager.canRetryCurrentTrack)
        XCTAssertFalse(manager.retryCurrentTrack())

        fixture.defaults.set(false, forKey: "showLyrics")
        XCTAssertEqual(fixture.manager().status, .disabled)
        manager.reset()
        XCTAssertEqual(manager.status, .disabled)
        XCTAssertFalse(manager.canRetryCurrentTrack)
        fixture.defaults.set(true, forKey: "showLyrics")
        manager.lyricsOffset = 1.2
        manager.reset()
        XCTAssertEqual(manager.status, .idle)
        XCTAssertEqual(manager.lyricsOffset, 1.2, "重置歌曲不能清除全局歌词偏移")
    }

    func testStatusDistinguishesSyncedAndPlainCacheHits() async {
        let fixture = LyricsExperienceFixture()
        for (type, payload, expected) in [
            (LyricsCache.EntryType.synced, "[00:00.00]Synced line", LyricsStatus.synced),
            (.plain, "Plain line", .plainText),
        ] {
            let manager = fixture.manager(cached: fixture.entry(type, payload: payload))
            manager.fetchLyrics(title: "Song", artist: "Artist", album: "Album", duration: 180)
            XCTAssertEqual(manager.status, .loading)
            XCTAssertTrue(manager.isFetching)
            await waitForLookup(manager)
            XCTAssertEqual(manager.status, expected)
            XCTAssertFalse(manager.isFetching)
            XCTAssertTrue(manager.canRetryCurrentTrack, "缓存命中后也允许显式绕过缓存重新查找")
        }
        XCTAssertTrue(fixture.writes.isEmpty, "缓存命中不能为了偏移或状态重写原文")
    }

    func testStatusDistinguishesNoMatchAndFailure() async {
        let fixture = LyricsExperienceFixture()
        let noMatch = fixture.manager { Self.noMatch($0) }
        await fetch(noMatch)
        XCTAssertEqual(noMatch.status, .notFound)
        XCTAssertTrue(noMatch.canRetryCurrentTrack)
        fixture.date.addTimeInterval(60)
        XCTAssertFalse(noMatch.shouldRetryCurrentTrack, "无结果不得变成每次轮询自动重试")

        let failed = fixture.manager { _ in throw URLError(.unsupportedURL) }
        await fetch(failed)
        XCTAssertEqual(failed.status, .failed)
        XCTAssertTrue(failed.canRetryCurrentTrack, "确定性失败没有网络退避时允许用户明确重试")
        XCTAssertFalse(failed.shouldRetryCurrentTrack)
    }

    func testPlainTextStatusRemainsUsableWhenOptionalSearchFails() async throws {
        let fixture = LyricsExperienceFixture()
        let searchStarted = expectation(description: "Optional synced search is pending")
        var pending: CheckedContinuation<(Data, URLResponse), Error>?
        let manager = fixture.manager { request in
            if request.url!.path.hasSuffix("/get") {
                return Self.response(request, json: #"{"plainLyrics":"Available plain line"}"#)
            }
            return try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                searchStarted.fulfill()
            }
        }
        manager.fetchLyrics(title: "Song", artist: "Artist", album: "Album", duration: 180)
        await fulfillment(of: [searchStarted], timeout: 1)
        XCTAssertEqual(manager.status, .plainText)
        XCTAssertTrue(manager.isFetching)
        XCTAssertEqual(manager.plainLyricPreview, "Available plain line")
        XCTAssertFalse(manager.canRetryCurrentTrack)

        try XCTUnwrap(pending).resume(throwing: URLError(.timedOut))
        await waitForLookup(manager)

        XCTAssertEqual(manager.status, .plainText)
        XCTAssertFalse(manager.isFetching)
        XCTAssertEqual(manager.plainLyricPreview, "Available plain line")
        XCTAssertFalse(manager.shouldRetryCurrentTrack)
    }

    func testDisablingRejectsOldResponseAndReopeningCanFetchSameSong() async throws {
        let fixture = LyricsExperienceFixture()
        let started = expectation(description: "Initial request started")
        var pending: CheckedContinuation<(Data, URLResponse), Error>?
        var initialRequest: URLRequest?
        var reopened = false
        let manager = fixture.manager { request in
            if reopened { return Self.response(request, json: #"{"syncedLyrics":"[00:00.00]Reopened line"}"#) }
            initialRequest = request
            return try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                started.fulfill()
            }
        }
        manager.fetchLyrics(title: "Song", artist: "Artist", album: "Album", duration: 180)
        await fulfillment(of: [started], timeout: 1)
        fixture.defaults.set(false, forKey: "showLyrics")
        manager.reset()
        XCTAssertEqual(manager.status, .disabled)
        XCTAssertFalse(manager.canRetryCurrentTrack)
        let staleCallback = expectation(description: "Disabled lyrics reject stale response")
        staleCallback.isInverted = true
        manager.onLyricsStateChanged = { staleCallback.fulfill() }
        try XCTUnwrap(pending).resume(returning: Self.response(try XCTUnwrap(initialRequest), json: #"{"syncedLyrics":"[00:00.00]Stale line"}"#))
        await fulfillment(of: [staleCallback], timeout: 0.1)
        manager.onLyricsStateChanged = nil
        XCTAssertEqual(manager.status, .disabled)
        XCTAssertFalse(manager.hasLyrics)
        XCTAssertFalse(manager.isFetching)

        fixture.defaults.set(true, forKey: "showLyrics")
        reopened = true
        await fetch(manager)
        manager.updateCurrentLine(elapsedTime: 0)
        XCTAssertEqual(manager.status, .synced)
        XCTAssertEqual(manager.currentLine, "Reopened line")
    }

    func testManualRetryRejectsRepeatedClicksUntilCooldownAndResetsForNewTrack() async {
        let fixture = LyricsExperienceFixture()
        var requests = 0
        let manager = fixture.manager { request in
            requests += 1
            return Self.noMatch(request)
        }
        await fetch(manager)
        XCTAssertTrue(manager.canRetryCurrentTrack)
        XCTAssertTrue(manager.retryCurrentTrack())
        XCTAssertFalse(manager.retryCurrentTrack(), "同一请求进行中不能连点重试")
        await waitForLookup(manager)
        let requestsAfterRetry = requests
        XCTAssertFalse(manager.canRetryCurrentTrack)
        XCTAssertFalse(manager.retryCurrentTrack())
        XCTAssertEqual(requests, requestsAfterRetry)
        fixture.date.addTimeInterval(4.9)
        XCTAssertFalse(manager.canRetryCurrentTrack)
        fixture.date.addTimeInterval(0.1)
        XCTAssertTrue(manager.canRetryCurrentTrack)
        XCTAssertTrue(manager.retryCurrentTrack())
        await waitForLookup(manager)

        await fetch(manager, title: "Other song")
        XCTAssertTrue(manager.canRetryCurrentTrack, "切歌后不继承上一首的人工重试冷却")
        XCTAssertTrue(manager.retryCurrentTrack())
        await waitForLookup(manager)
    }

    func testManualRetryRespectsAutomaticFailureBackoff() async {
        let fixture = LyricsExperienceFixture()
        var requests = 0
        let manager = fixture.manager { _ in
            requests += 1
            throw URLError(.notConnectedToInternet)
        }
        await fetch(manager)
        XCTAssertEqual(manager.status, .failed)
        XCTAssertEqual(requests, 2)
        XCTAssertFalse(manager.canRetryCurrentTrack)
        XCTAssertFalse(manager.retryCurrentTrack())
        fixture.date.addTimeInterval(15)
        XCTAssertTrue(manager.canRetryCurrentTrack)
        XCTAssertTrue(manager.retryCurrentTrack())
        await waitForLookup(manager)
        XCTAssertEqual(requests, 4)
        fixture.date.addTimeInterval(5)
        XCTAssertFalse(manager.canRetryCurrentTrack, "人工冷却结束也不能绕过尚未结束的网络退避")
        fixture.date.addTimeInterval(25)
        XCTAssertTrue(manager.canRetryCurrentTrack)
    }

    private func fetch(_ manager: LyricsManager, title: String = "Song") async {
        manager.fetchLyrics(title: title, artist: "Artist", album: "Album", duration: 180)
        await waitForLookup(manager)
    }

    private func waitForLookup(_ manager: LyricsManager) async {
        guard manager.isFetching else { return }
        let finished = expectation(description: "Lyrics lookup finished")
        manager.onLyricsStateChanged = {
            if !manager.isFetching { finished.fulfill() }
        }
        await fulfillment(of: [finished], timeout: 1)
        manager.onLyricsStateChanged = nil
    }

    private static func noMatch(_ request: URLRequest) -> (Data, URLResponse) {
        let exact = request.url!.path.hasSuffix("/get")
        return response(request, json: exact ? "{}" : "[]", status: exact ? 404 : 200)
    }

    private static func response(_ request: URLRequest, json: String, status: Int = 200) -> (Data, URLResponse) {
        (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor
private final class LyricsExperienceFixture {
    let suite = "XNook.LyricsExperienceTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    var writes: [(LyricsCache.EntryType, String)] = []
    var date = Date(timeIntervalSince1970: 1000)

    init() {
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "showLyrics")
    }

    func manager(
        cached: LyricsCache.Entry? = nil,
        loadRequest: @escaping LyricsManager.RequestLoader = { _ in
            XCTFail("缓存测试不应请求网络")
            throw URLError(.unsupportedURL)
        }
    ) -> LyricsManager {
        LyricsManager(defaults: defaults,
                      loadRequest: loadRequest,
                      readCache: { _, _, _ in cached },
                      writeCache: { [weak self] _, _, _, type, payload, _ in self?.writes.append((type, payload)) },
                      sleep: { _ in }, now: { [weak self] in self?.date ?? .distantPast })
    }

    func entry(_ type: LyricsCache.EntryType, payload: String) -> LyricsCache.Entry {
        LyricsCache.Entry(type: type, payload: payload, fetchedAt: Date(timeIntervalSince1970: 1000), key: "song|artist")
    }

    deinit { defaults.removePersistentDomain(forName: suite) }
}
