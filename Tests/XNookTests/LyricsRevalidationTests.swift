import XCTest
@testable import XNook

@MainActor
final class LyricsRevalidationTests: XCTestCase {
    func testManualRefreshBypassesCacheAndOnlyReplacesItAfterSuccess() async {
        let f = Fixture()
        let manager = f.manager { request in
            Fixture.response(request, json: #"{"trackName":"Song","artistName":"Artist","duration":180,"syncedLyrics":"[00:00]Fresh synthetic line"}"#)
        }
        await start(manager)
        XCTAssertEqual(f.reads, 1)
        XCTAssertTrue(manager.canRetryCurrentTrack)
        guard manager.retryCurrentTrack() else { return XCTFail("已有歌词也必须能重新查找") }
        XCTAssertTrue(manager.hasLyrics, "刷新开始时不能清空可用时间轴")
        await wait(manager)
        manager.updateCurrentLine(elapsedTime: 0)
        XCTAssertEqual(manager.currentLine, "Fresh synthetic line")
        XCTAssertEqual(f.reads, 1)
        XCTAssertEqual(f.requests, 1)
        XCTAssertEqual(f.writes, ["[00:00]Fresh synthetic line"])
        XCTAssertEqual(f.metadata.last ?? nil, LyricsCache.MatchMetadata(trackName: "Song", artistName: "Artist", duration: 180))
        XCTAssertFalse(manager.canRetryCurrentTrack)
    }

    func testFailedManualRefreshKeepsProgressingLyricsAndDoesNotOverwriteCache() async {
        let f = Fixture()
        let manager = f.manager { _ in throw URLError(.notConnectedToInternet) }
        await start(manager)
        guard manager.retryCurrentTrack() else { return XCTFail("已有歌词也必须能重新查找") }
        manager.updateCurrentLine(elapsedTime: 7)
        XCTAssertEqual(manager.currentLine, "Cached later line")
        await wait(manager)
        manager.updateCurrentLine(elapsedTime: 0)
        XCTAssertEqual(manager.currentLine, "Cached first line")
        XCTAssertEqual(manager.status, .synced)
        XCTAssertEqual(manager.refreshNotice, .failedKeepingCurrent)
        XCTAssertEqual(f.reads, 1)
        XCTAssertEqual(f.requests, 2)
        XCTAssertTrue(f.writes.isEmpty)
        f.time.addTimeInterval(5)
        XCTAssertFalse(manager.canRetryCurrentTrack, "人工冷却不能绕过网络退避")
        f.time.addTimeInterval(10)
        XCTAssertTrue(manager.canRetryCurrentTrack)
        XCTAssertFalse(manager.shouldRetryCurrentTrack, "有回退歌词时不自动循环请求")
    }

    func testNoMatchDuringRefreshKeepsPlainTextWithoutRewritingOldCache() async {
        let f = Fixture()
        f.cached = LyricsCache.Entry(type: .plain, payload: "Cached plain line", fetchedAt: f.time, key: "song|artist|album")
        var offline = true
        let manager = f.manager { request in
            guard !offline else { throw URLError(.notConnectedToInternet) }
            return Fixture.noMatch(request)
        }
        await start(manager)
        guard manager.retryCurrentTrack() else { return XCTFail("纯文本也必须能重新查找") }
        await wait(manager)
        f.time.addTimeInterval(15)
        offline = false
        XCTAssertTrue(manager.retryCurrentTrack())
        await wait(manager)
        XCTAssertEqual(manager.plainLyricPreview, "Cached plain line")
        XCTAssertEqual(manager.status, .plainText)
        XCTAssertEqual(manager.refreshNotice, .noMatchKeepingCurrent)
        XCTAssertEqual(f.requests, 5)
        XCTAssertEqual(f.reads, 1)
        XCTAssertTrue(f.writes.isEmpty)
        f.time.addTimeInterval(5)
        offline = true
        XCTAssertTrue(manager.retryCurrentTrack())
        await wait(manager)
        XCTAssertEqual(manager.retryAvailableAt, f.time.addingTimeInterval(15), "成功的无结果查询也应重置连续网络失败计数")
    }

    func testLateDurationRechecksOnlyOnceAndManualRetryUsesNewestDuration() async {
        let f = Fixture()
        var requestedDurations: [String] = []
        let manager = f.manager { request in
            requestedDurations.append(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "duration" })?.value ?? "missing")
            return Fixture.response(request, json: #"{"trackName":"Song","artistName":"Artist","duration":180,"syncedLyrics":"[00:00]Refreshed line"}"#)
        }
        await start(manager, duration: nil)
        manager.fetchLyrics(title: "Song", artist: "Artist", album: "Album", duration: 180)
        guard manager.isFetching else { return XCTFail("缓存命中后时长迟到也应复核一次") }
        XCTAssertTrue(manager.hasLyrics)
        await wait(manager)
        for duration in [180.2, 181, 182, 190] {
            manager.fetchLyrics(title: "Song", artist: "Artist", album: "Album", duration: duration)
            XCTAssertFalse(manager.isFetching)
        }
        XCTAssertEqual(f.requests, 1)
        XCTAssertEqual(f.reads, 1)
        XCTAssertTrue(manager.retryCurrentTrack())
        await wait(manager)
        XCTAssertEqual(requestedDurations, ["180", "190"])
        XCTAssertEqual(f.reads, 1)
    }

    func testDurationChangesCannotBypassNetworkBackoff() async {
        let f = Fixture()
        f.cached = nil
        var online = false
        let manager = f.manager { request in
            guard online else { throw URLError(.notConnectedToInternet) }
            return Fixture.response(request, json: #"{"syncedLyrics":"[00:00]Recovered line"}"#)
        }
        await start(manager)
        XCTAssertEqual(f.requests, 2)
        manager.fetchLyrics(title: "Song", artist: "Artist", album: "Album", duration: 182)
        XCTAssertFalse(manager.isFetching)
        await wait(manager)
        XCTAssertEqual(f.requests, 2)
        f.time.addTimeInterval(15)
        online = true
        XCTAssertTrue(manager.shouldRetryCurrentTrack)
        manager.fetchLyrics(title: "Song", artist: "Artist", album: "Album", duration: 182)
        await wait(manager)
        XCTAssertEqual(f.requests, 3)
        XCTAssertTrue(manager.hasLyrics)
    }

    func testKnownConflictingCacheMetadataFallsBackToNetwork() async {
        let f = Fixture()
        f.cached?.match = LyricsCache.MatchMetadata(trackName: "Other", artistName: "Artist", duration: 180)
        let manager = f.manager { request in
            Fixture.response(request, json: #"{"trackName":"Song","artistName":"Artist","duration":180,"syncedLyrics":"[00:00]Correct candidate"}"#)
        }
        await start(manager)
        manager.updateCurrentLine(elapsedTime: 0)
        XCTAssertEqual(manager.currentLine, "Correct candidate")
        XCTAssertEqual(f.requests, 1)
        XCTAssertEqual(f.writes, ["[00:00]Correct candidate"])
    }

    func testLegacyCacheAndSubsecondDurationChangesStayAvailable() async {
        let f = Fixture()
        let manager = f.manager { _ in XCTFail("未知元数据旧缓存应保持可用"); throw URLError(.unsupportedURL) }
        await start(manager)
        manager.fetchLyrics(title: "Song", artist: "Artist", album: "Album", duration: 180.3)
        XCTAssertFalse(manager.isFetching)
        XCTAssertTrue(manager.hasLyrics)
        XCTAssertEqual(f.requests, 0)
        XCTAssertEqual(f.reads, 1)
        XCTAssertTrue(f.writes.isEmpty)
    }

    func testManualRetryConsumesPendingDurationCheckInsteadOfRepeatingItAfterCooldown() async {
        let f = Fixture()
        var online = false
        let manager = f.manager { request in
            guard online else { throw URLError(.notConnectedToInternet) }
            return Fixture.response(request, json: #"{"syncedLyrics":"[00:00]Updated line"}"#)
        }
        await start(manager, duration: nil)
        XCTAssertTrue(manager.retryCurrentTrack())
        await wait(manager)
        manager.fetchLyrics(title: "Song", artist: "Artist", album: "Album", duration: 180)
        XCTAssertFalse(manager.isFetching)
        f.time.addTimeInterval(15)
        online = true
        XCTAssertTrue(manager.shouldRetryCurrentTrack)
        XCTAssertTrue(manager.retryCurrentTrack())
        await wait(manager)
        f.time.addTimeInterval(5)
        XCTAssertFalse(manager.shouldRetryCurrentTrack)
        manager.fetchLyrics(title: "Song", artist: "Artist", album: "Album", duration: 180)
        XCTAssertFalse(manager.isFetching)
        XCTAssertEqual(f.requests, 3)
    }

    func testIncompatibleKnownFallbackIsNotKeptWhenDurationChanges() async {
        let f = Fixture()
        f.cached?.match = LyricsCache.MatchMetadata(trackName: "Song", artistName: "Other", duration: 180)
        let manager = f.manager { _ in throw URLError(.notConnectedToInternet) }
        await start(manager)
        XCTAssertTrue(manager.hasLyrics)
        manager.fetchLyrics(title: "Song", artist: "Artist", album: "Album", duration: 300)
        XCTAssertFalse(manager.hasLyrics)
        await wait(manager)
        XCTAssertEqual(manager.status, .failed)
        XCTAssertNil(manager.refreshNotice)
        XCTAssertTrue(f.writes.isEmpty)
    }

    func testDiscardingIncompatibleFallbackClearsTheKeptLyricsNotice() async {
        let f = Fixture()
        f.cached?.match = LyricsCache.MatchMetadata(trackName: "Song", artistName: "Other", duration: 180)
        let manager = f.manager { _ in throw URLError(.notConnectedToInternet) }
        await start(manager)
        manager.fetchLyrics(title: "Song", artist: "Artist", album: "Album", duration: 181)
        await wait(manager)
        XCTAssertEqual(manager.refreshNotice, .failedKeepingCurrent)
        manager.fetchLyrics(title: "Song", artist: "Artist", album: "Album", duration: 300)
        XCTAssertFalse(manager.hasLyrics)
        XCTAssertEqual(manager.status, .notFound)
        XCTAssertNil(manager.refreshNotice, "不能在原歌词已无效时还显示保留提示")
        XCTAssertEqual(f.requests, 2)
    }

    func testResultMustMatchNewestDurationWhileRevalidationIsInFlight() async throws {
        let f = Fixture()
        f.cached?.match = LyricsCache.MatchMetadata(trackName: "Song", artistName: "Other", duration: 180)
        let started = expectation(description: "Revalidation request is pending")
        var pending: CheckedContinuation<(Data, URLResponse), Error>?
        var pendingRequest: URLRequest?
        let manager = f.manager { request in
            guard request.url!.path.hasSuffix("/get") else { return Fixture.response(request, json: "[]") }
            pendingRequest = request
            return try await withCheckedThrowingContinuation { pending = $0; started.fulfill() }
        }
        await start(manager)
        manager.fetchLyrics(title: "Song", artist: "Artist", album: "Album", duration: 181)
        await fulfillment(of: [started], timeout: 1)
        manager.fetchLyrics(title: "Song", artist: "Artist", album: "Album", duration: 300)
        XCTAssertFalse(manager.hasLyrics)
        try XCTUnwrap(pending).resume(returning: Fixture.response(try XCTUnwrap(pendingRequest),
            json: #"{"trackName":"Song","artistName":"Other","duration":181,"syncedLyrics":"[00:00]Stale timing line"}"#))
        await wait(manager)
        XCTAssertFalse(manager.hasLyrics)
        XCTAssertEqual(manager.status, .notFound)
        XCTAssertEqual(f.requests, 3, "过时精确结果被拒绝后仍允许两路搜索")
        XCTAssertTrue(f.writes.isEmpty)
    }

    func testTrackSwitchRejectsOldManualRefreshWithoutCacheWrite() async throws {
        let f = Fixture()
        let started = expectation(description: "Manual refresh is pending")
        var pending: CheckedContinuation<(Data, URLResponse), Error>?
        var pendingRequest: URLRequest?
        let manager = f.manager { request in
            let title = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "track_name" }?.value
            if title == "Song" {
                pendingRequest = request
                return try await withCheckedThrowingContinuation { pending = $0; started.fulfill() }
            }
            return Fixture.response(request, json: #"{"syncedLyrics":"[00:00]Other track line"}"#)
        }
        await start(manager)
        XCTAssertTrue(manager.retryCurrentTrack())
        await fulfillment(of: [started], timeout: 1)
        f.cached = nil
        manager.fetchLyrics(title: "Other", artist: "Artist", album: "Album", duration: 200)
        await wait(manager)
        let stale = expectation(description: "Old refresh cannot notify")
        stale.isInverted = true
        manager.onLyricsStateChanged = { stale.fulfill() }
        try XCTUnwrap(pending).resume(returning: Fixture.response(try XCTUnwrap(pendingRequest),
            json: #"{"syncedLyrics":"[00:00]Old manual line"}"#))
        await fulfillment(of: [stale], timeout: 0.1)
        manager.onLyricsStateChanged = nil
        manager.updateCurrentLine(elapsedTime: 0)
        XCTAssertEqual(manager.currentLine, "Other track line")
        XCTAssertEqual(f.writes, ["[00:00]Other track line"])
    }

    func testInvalidDurationsNeverReachIntegerConversionOrCauseRepeatedLookup() async {
        let f = Fixture()
        let manager = f.manager { _ in XCTFail("无效时长不能触发重查"); throw URLError(.unsupportedURL) }
        await start(manager, duration: .infinity)
        for duration in [Double.nan, -Double.infinity, -1, 0, Double.greatestFiniteMagnitude] {
            manager.fetchLyrics(title: "Song", artist: "Artist", album: "Album", duration: duration)
            XCTAssertFalse(manager.isFetching)
            XCTAssertFalse(LyricsManager.shouldUseExactLookup(album: "Album", duration: duration))
        }
        XCTAssertTrue(manager.hasLyrics)
        XCTAssertEqual(f.requests, 0)
    }

    func testTemporaryDurationJitterDuringCooldownDoesNotConsumeRevalidationBudget() async {
        let f = Fixture()
        let manager = f.manager { request in
            Fixture.response(request, json: #"{"syncedLyrics":"[00:00]Current line"}"#)
        }
        await start(manager)
        XCTAssertTrue(manager.retryCurrentTrack())
        await wait(manager)
        manager.fetchLyrics(title: "Song", artist: "Artist", album: "Album", duration: 181)
        manager.fetchLyrics(title: "Song", artist: "Artist", album: "Album", duration: 180)
        f.time.addTimeInterval(5)
        XCTAssertFalse(manager.shouldRetryCurrentTrack, "时长恢复原值后不应保留临时复核意图")
        manager.fetchLyrics(title: "Song", artist: "Artist", album: "Album", duration: 180)
        await wait(manager)
        XCTAssertEqual(f.requests, 1)
        manager.fetchLyrics(title: "Song", artist: "Artist", album: "Album", duration: 190)
        XCTAssertTrue(manager.isFetching, "后来的真实变化仍应保留一次复核机会")
        await wait(manager)
        XCTAssertEqual(f.requests, 2)
    }

    func testSearchResponseSelectsCandidateForLatestDurationWithoutAnotherRequest() async throws {
        let f = Fixture()
        let started = expectation(description: "Search awaiting candidates")
        var pending: CheckedContinuation<(Data, URLResponse), Error>?
        var pendingRequest: URLRequest?
        let manager = f.manager { request in
            if request.url!.path.hasSuffix("/get") { return Fixture.noMatch(request) }
            pendingRequest = request
            return try await withCheckedThrowingContinuation { pending = $0; started.fulfill() }
        }
        await start(manager, duration: nil)
        manager.fetchLyrics(title: "Song", artist: "Artist", album: "Album", duration: 180)
        await fulfillment(of: [started], timeout: 1)
        manager.fetchLyrics(title: "Song", artist: "Artist", album: "Album", duration: 220)
        try XCTUnwrap(pending).resume(returning: Fixture.response(try XCTUnwrap(pendingRequest), json: #"[{"trackName":"Song","artistName":"Other","duration":180,"syncedLyrics":"[00:00]Earlier duration"},{"trackName":"Song","artistName":"Other","duration":220,"syncedLyrics":"[00:00]Latest duration"}]"#))
        await wait(manager)
        manager.updateCurrentLine(elapsedTime: 0)
        XCTAssertEqual(manager.currentLine, "Latest duration")
        XCTAssertEqual(f.writes, ["[00:00]Latest duration"])
        XCTAssertEqual(f.requests, 2)
    }

    func testOutdatedExactPlainFallbackDoesNotDisplaceNewMatchingSearchPlain() async throws {
        let f = Fixture()
        let started = expectation(description: "Search awaiting plain candidate")
        var pending: CheckedContinuation<(Data, URLResponse), Error>?
        var pendingRequest: URLRequest?
        let manager = f.manager { request in
            if request.url!.path.hasSuffix("/get") {
                return Fixture.response(request, json: #"{"trackName":"Song","artistName":"Other","duration":180,"plainLyrics":"Old exact plain"}"#)
            }
            if URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "q" }) == true {
                return Fixture.response(request, json: "[]")
            }
            pendingRequest = request
            return try await withCheckedThrowingContinuation { pending = $0; started.fulfill() }
        }
        await start(manager)
        XCTAssertTrue(manager.retryCurrentTrack())
        await fulfillment(of: [started], timeout: 1)
        manager.fetchLyrics(title: "Song", artist: "Artist", album: "Album", duration: 220)
        try XCTUnwrap(pending).resume(returning: Fixture.response(try XCTUnwrap(pendingRequest), json: #"[{"trackName":"Song","artistName":"Other","duration":220,"plainLyrics":"Current search plain"}]"#))
        await wait(manager)
        XCTAssertEqual(manager.plainLyricPreview, "Current search plain")
        XCTAssertEqual(f.writes, ["Current search plain"])
        XCTAssertEqual(f.requests, 2)
    }

    private func start(_ manager: LyricsManager, duration: Double? = 180) async {
        manager.fetchLyrics(title: "Song", artist: "Artist", album: "Album", duration: duration)
        await wait(manager)
    }

    private func wait(_ manager: LyricsManager) async {
        guard manager.isFetching else { return }
        let done = expectation(description: "Lookup finished")
        manager.onLyricsStateChanged = { if !manager.isFetching { done.fulfill() } }
        await fulfillment(of: [done], timeout: 1)
        manager.onLyricsStateChanged = nil
    }

    @MainActor
    private final class Fixture {
        let suite = "XNook.LyricsRevalidation.\(UUID().uuidString)"
        let defaults: UserDefaults
        var time = Date(timeIntervalSince1970: 1000)
        var cached: LyricsCache.Entry?
        var reads = 0
        var requests = 0
        var writes: [String] = []
        var metadata: [LyricsCache.MatchMetadata?] = []
        init() {
            defaults = UserDefaults(suiteName: suite)!
            defaults.set(true, forKey: "showLyrics")
            cached = LyricsCache.Entry(type: .synced, payload: "[00:00]Cached first line\n[00:05]Cached later line", fetchedAt: time, key: "song|artist|album")
        }
        func manager(load: @escaping LyricsManager.RequestLoader) -> LyricsManager {
            LyricsManager(defaults: defaults, loadRequest: { [unowned self] request in
                requests += 1
                return try await load(request)
            }, readCache: { [unowned self] _, _, _ in reads += 1; return cached },
                writeCache: { [unowned self] _, _, _, _, payload, match in writes.append(payload); metadata.append(match) },
                sleep: { _ in }, now: { [unowned self] in time })
        }
        static func response(_ request: URLRequest, json: String, status: Int = 200) -> (Data, URLResponse) {
            (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        static func noMatch(_ request: URLRequest) -> (Data, URLResponse) {
            let exact = request.url!.path.hasSuffix("/get")
            return response(request, json: exact ? "{}" : "[]", status: exact ? 404 : 200)
        }
        deinit { defaults.removePersistentDomain(forName: suite) }
    }
}
