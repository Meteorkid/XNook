import XCTest
@testable import XNook

@MainActor
final class LyricsRequestTests: XCTestCase {
    func testExactPlainLyricsSurviveEmptySearchResults() async {
        let fixture = LyricsRequestFixture()
        let manager = fixture.manager { request in
            Self.response(request, json: request.url!.path.hasSuffix("/get")
                ? #"{"trackName":"Song","artistName":"Artist","duration":180,"plainLyrics":"Available plain lyrics"}"#
                : "[]")
        }
        await fetch(manager)
        XCTAssertEqual(manager.plainLyricPreview, "Available plain lyrics")
        XCTAssertEqual(fixture.writes.last?.0, .plain)
    }

    func testExactPlainLyricsSurviveSearchNetworkFailure() async {
        let fixture = LyricsRequestFixture()
        let manager = fixture.manager { request in
            if request.url!.path.hasSuffix("/get") {
                return Self.response(request, json: #"{"plainLyrics":"Available plain lyrics"}"#)
            }
            throw URLError(.timedOut)
        }
        await fetch(manager)
        XCTAssertEqual(manager.plainLyricPreview, "Available plain lyrics")
    }

    func testExactPlainLyricsAreVisibleWhileOptionalSearchIsPending() async {
        let fixture = LyricsRequestFixture()
        let searching = expectation(description: "Optional search is still pending")
        var pending: CheckedContinuation<(Data, URLResponse), Error>?
        var searchRequest: URLRequest?
        let manager = fixture.manager { request in
            if request.url!.path.hasSuffix("/get") {
                return Self.response(request, json: #"{"plainLyrics":"Available immediately"}"#)
            }
            searchRequest = request
            return try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                searching.fulfill()
            }
        }
        manager.fetchLyrics(title: "Song", artist: "Artist", album: "Album", duration: 180)
        await fulfillment(of: [searching], timeout: 1)
        XCTAssertTrue(manager.isFetching)
        XCTAssertEqual(manager.plainLyricPreview, "Available immediately")
        let completed = expectation(description: "Synced search result upgrades plain lyrics")
        manager.onLyricsStateChanged = { if !manager.isFetching { completed.fulfill() } }
        if let pending, let searchRequest {
            pending.resume(returning: Self.response(searchRequest, json: "[\(Self.syncedJSON)]"))
        }
        await fulfillment(of: [completed], timeout: 1)
        manager.updateCurrentLine(elapsedTime: 2)
        XCTAssertEqual(manager.currentLine, "Recovered line")
    }

    func testExactSyncedLyricsWithConflictingTitleContinueToSearch() async {
        let fixture = LyricsRequestFixture()
        var requests = 0
        let manager = fixture.manager { request in
            requests += 1
            return Self.response(request, json: request.url!.path.hasSuffix("/get")
                ? #"{"trackName":"Other","artistName":"Artist","duration":180,"syncedLyrics":"[00:01.00]Wrong lantern"}"#
                : "[\(Self.syncedJSON)]")
        }

        await fetch(manager)
        manager.updateCurrentLine(elapsedTime: 2)

        XCTAssertEqual(requests, 2)
        XCTAssertEqual(manager.currentLine, "Recovered line")
        XCTAssertEqual(fixture.writes.count, 1)
        XCTAssertEqual(fixture.writes.last?.0, .synced)
        XCTAssertEqual(fixture.writes.last?.1, "[00:01.00]Recovered line")
    }

    func testExactPlainLyricsWithConflictingTitleAreNeverDisplayedOrCached() async throws {
        let fixture = LyricsRequestFixture()
        let searching = expectation(description: "Search waits after rejected exact lyrics")
        let completed = expectation(description: "Empty searches finish without lyrics")
        var pending: CheckedContinuation<(Data, URLResponse), Error>?
        var searchRequest: URLRequest?
        var searchRequests = 0
        let manager = fixture.manager { request in
            if request.url!.path.hasSuffix("/get") {
                return Self.response(request, json: #"{"trackName":"Other","artistName":"Artist","duration":180,"plainLyrics":"Wrong paper moon"}"#)
            }
            searchRequests += 1
            guard searchRequests == 1 else { return Self.response(request, json: "[]") }
            searchRequest = request
            return try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                searching.fulfill()
            }
        }
        var displayedPlainLyrics: [String] = []
        manager.onLyricsStateChanged = {
            displayedPlainLyrics.append(manager.plainLyricPreview)
            if !manager.isFetching { completed.fulfill() }
        }
        manager.fetchLyrics(title: "Song", artist: "Artist", album: "Album", duration: 180)
        await fulfillment(of: [searching], timeout: 1)

        XCTAssertTrue(manager.isFetching)
        XCTAssertTrue(manager.plainLyricPreview.isEmpty)
        XCTAssertTrue(fixture.writes.isEmpty)
        try XCTUnwrap(pending).resume(returning: Self.response(try XCTUnwrap(searchRequest), json: "[]"))
        await fulfillment(of: [completed], timeout: 1)
        manager.onLyricsStateChanged = nil

        XCTAssertEqual(searchRequests, 2)
        XCTAssertEqual(manager.status, .notFound)
        XCTAssertFalse(manager.hasLyrics)
        XCTAssertTrue(manager.plainLyricPreview.isEmpty)
        XCTAssertTrue(displayedPlainLyrics.allSatisfy(\.isEmpty))
        XCTAssertTrue(fixture.writes.isEmpty)
    }

    func testExactSyncedLyricsWithConflictingArtistAndDurationContinueToSearch() async {
        let fixture = LyricsRequestFixture()
        var requests = 0
        let manager = fixture.manager { request in
            requests += 1
            return Self.response(request, json: request.url!.path.hasSuffix("/get")
                ? #"{"trackName":"Song","artistName":"Other","duration":300,"syncedLyrics":"[00:01.00]Distant paper moon"}"#
                : "[\(Self.syncedJSON)]")
        }

        await fetch(manager)
        manager.updateCurrentLine(elapsedTime: 2)

        XCTAssertEqual(requests, 2)
        XCTAssertEqual(manager.currentLine, "Recovered line")
        XCTAssertEqual(fixture.writes.count, 1)
        XCTAssertEqual(fixture.writes.last?.1, "[00:01.00]Recovered line")
    }

    func testExactSyncedLyricsWithoutTitleOrArtistRemainAccepted() async {
        let fixture = LyricsRequestFixture()
        var requests = 0
        let manager = fixture.manager { request in
            requests += 1
            return Self.response(request, json: #"{"syncedLyrics":"[00:01.00]Quiet spark"}"#)
        }

        await fetch(manager)
        manager.updateCurrentLine(elapsedTime: 2)

        XCTAssertEqual(requests, 1)
        XCTAssertEqual(manager.status, .synced)
        XCTAssertEqual(manager.currentLine, "Quiet spark")
        XCTAssertEqual(fixture.writes.count, 1)
        XCTAssertEqual(fixture.writes.last?.0, .synced)
        XCTAssertEqual(fixture.writes.last?.1, "[00:01.00]Quiet spark")
    }

    func testConflictingExactAndStructuredResultsAllowQueryFallback() async {
        let fixture = LyricsRequestFixture()
        var requests = 0
        var usedQueryFallback = false
        let conflictingJSON = #"{"trackName":"Other","artistName":"Artist","duration":180,"syncedLyrics":"[00:01.00]Wrong silver cloud"}"#
        let manager = fixture.manager { request in
            requests += 1
            if request.url!.path.hasSuffix("/get") {
                return Self.response(request, json: conflictingJSON)
            }
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            if query?.contains(where: { $0.name == "q" }) == true {
                usedQueryFallback = true
                return Self.response(request, json: "[\(Self.syncedJSON)]")
            }
            return Self.response(request, json: "[\(conflictingJSON)]")
        }

        await fetch(manager)
        manager.updateCurrentLine(elapsedTime: 2)

        XCTAssertEqual(requests, 3)
        XCTAssertTrue(usedQueryFallback)
        XCTAssertEqual(manager.currentLine, "Recovered line")
        XCTAssertEqual(fixture.writes.count, 1)
        XCTAssertEqual(fixture.writes.last?.0, .synced)
        XCTAssertEqual(fixture.writes.last?.1, "[00:01.00]Recovered line")
    }

    func testAcceptedExactPlainLyricsSurviveConflictingSearchCandidates() async {
        let fixture = LyricsRequestFixture()
        var requests = 0
        let manager = fixture.manager { request in
            requests += 1
            return Self.response(request, json: request.url!.path.hasSuffix("/get")
                ? #"{"trackName":"Song","artistName":"Artist","duration":180,"plainLyrics":"Steady lantern"}"#
                : #"[{"trackName":"Other","artistName":"Artist","duration":180,"syncedLyrics":"[00:01.00]Wrong silver cloud"}]"#)
        }

        await fetch(manager)

        XCTAssertEqual(requests, 3)
        XCTAssertEqual(manager.status, .plainText)
        XCTAssertFalse(manager.hasLyrics)
        XCTAssertEqual(manager.plainLyricPreview, "Steady lantern")
        XCTAssertEqual(fixture.writes.count, 1)
        XCTAssertEqual(fixture.writes.last?.0, .plain)
        XCTAssertEqual(fixture.writes.last?.1, "Steady lantern")
    }

    func testTransientFailureCanRecoverForUnchangedSongAfterCooldown() async {
        let fixture = LyricsRequestFixture()
        var online = false
        var requests = 0
        let manager = fixture.manager { request in
            requests += 1
            guard online else { throw URLError(.notConnectedToInternet) }
            return Self.response(request, json: Self.syncedJSON)
        }
        await fetch(manager)
        XCTAssertFalse(manager.hasLyrics)
        XCTAssertEqual(requests, 2)
        XCTAssertFalse(manager.shouldRetryCurrentTrack, "不能在失败后每秒重新请求")

        fixture.date.addTimeInterval(20)
        XCTAssertTrue(manager.shouldRetryCurrentTrack, "网络恢复后同一首歌也必须允许再次获取")
        guard manager.shouldRetryCurrentTrack else { return }
        online = true
        await fetch(manager)
        manager.updateCurrentLine(elapsedTime: 2)
        XCTAssertEqual(manager.currentLine, "Recovered line")
        XCTAssertFalse(manager.shouldRetryCurrentTrack)
    }

    func testServerFailureIsNotRecordedAsPermanentNoLyrics() async {
        let fixture = LyricsRequestFixture()
        let manager = fixture.manager { request in
            Self.response(request, json: "{}", status: 503)
        }
        await fetch(manager)
        fixture.date.addTimeInterval(20)
        XCTAssertTrue(manager.shouldRetryCurrentTrack)
    }

    func testSuccessfulNoMatchAfterRetryClearsPreviousNetworkError() async {
        let fixture = LyricsRequestFixture()
        var requests = 0
        let manager = fixture.manager { request in
            requests += 1
            if requests == 1 { throw URLError(.notConnectedToInternet) }
            let exact = request.url!.path.hasSuffix("/get")
            return Self.response(request, json: exact ? "{}" : "[]", status: exact ? 404 : 200)
        }
        await fetch(manager)
        fixture.date.addTimeInterval(20)
        XCTAssertFalse(manager.shouldRetryCurrentTrack)
        XCTAssertFalse(manager.hasLyrics)
    }

    func testExactTimeoutStillAllowsSuccessfulSearch() async {
        let fixture = LyricsRequestFixture()
        let manager = fixture.manager { request in
            if request.url!.path.hasSuffix("/get") { throw URLError(.timedOut) }
            return Self.response(request, json: "[\(Self.syncedJSON)]")
        }
        await fetch(manager)
        manager.updateCurrentLine(elapsedTime: 2)
        XCTAssertEqual(manager.currentLine, "Recovered line")
    }

    func testSmallDurationChangesDoNotRestartPendingLookup() async {
        let fixture = LyricsRequestFixture()
        let started = expectation(description: "First lookup started")
        let restarted = expectation(description: "Fractional duration change must not restart lookup")
        restarted.isInverted = true
        var pending: [(URLRequest, CheckedContinuation<(Data, URLResponse), Error>)] = []
        let manager = fixture.manager { request in
            try await withCheckedThrowingContinuation { continuation in
                pending.append((request, continuation))
                if pending.count == 1 { started.fulfill() } else { restarted.fulfill() }
            }
        }
        manager.fetchLyrics(title: "Song", artist: "Artist", album: "Album", duration: 180)
        await fulfillment(of: [started], timeout: 1)
        manager.fetchLyrics(title: "Song", artist: "Artist", album: "Album", duration: 180.1)
        await fulfillment(of: [restarted], timeout: 0.1)
        XCTAssertEqual(pending.count, 1)
        let completed = expectation(description: "Original lookup remains usable")
        manager.onLyricsStateChanged = { if !manager.isFetching { completed.fulfill() } }
        for (request, continuation) in pending {
            continuation.resume(returning: Self.response(request, json: Self.syncedJSON))
        }
        await fulfillment(of: [completed], timeout: 1)
        XCTAssertTrue(manager.hasLyrics)
    }

    func testConfirmedNoMatchDoesNotRetryEveryPoll() async {
        let fixture = LyricsRequestFixture()
        let manager = fixture.manager { request in
            Self.response(request, json: request.url!.path.hasSuffix("/get") ? "{}" : "[]",
                          status: request.url!.path.hasSuffix("/get") ? 404 : 200)
        }
        await fetch(manager)
        fixture.date.addTimeInterval(60)
        XCTAssertFalse(manager.shouldRetryCurrentTrack)
        XCTAssertFalse(manager.hasLyrics)
    }

    func testMalformedSyncedPayloadFallsBackToAvailablePlainLyrics() async {
        let fixture = LyricsRequestFixture()
        let manager = fixture.manager { request in
            Self.response(request, json: request.url!.path.hasSuffix("/get")
                ? #"{"syncedLyrics":"[ti:Song]","plainLyrics":"Usable plain line"}"#
                : "[]")
        }
        await fetch(manager)
        XCTAssertFalse(manager.hasLyrics)
        XCTAssertEqual(manager.plainLyricPreview, "Usable plain line")
        XCTAssertEqual(fixture.writes.last?.0, .plain)
    }

    func testSearchSkipsMalformedSyncedCandidateAfterExactMiss() async {
        let fixture = LyricsRequestFixture()
        var requests = 0
        let manager = fixture.manager { request in
            requests += 1
            if request.url!.path.hasSuffix("/get") {
                return Self.response(request, json: "{}", status: 404)
            }
            return Self.response(request, json: #"[{"trackName":"Song","artistName":"Artist","duration":180,"syncedLyrics":"[ti:Song]"},{"trackName":"Song","artistName":"Artist","duration":180,"plainLyrics":"Usable lyrics"}]"#)
        }

        await fetch(manager)

        XCTAssertEqual(requests, 2)
        XCTAssertFalse(manager.hasLyrics)
        XCTAssertEqual(manager.plainLyricPreview, "Usable lyrics")
        XCTAssertEqual(fixture.writes.last?.0, .plain)
        XCTAssertEqual(fixture.writes.last?.1, "Usable lyrics")
    }

    func testUnusableSearchCandidateAllowsQueryFallback() async {
        let fixture = LyricsRequestFixture()
        var usedQueryFallback = false
        let manager = fixture.manager { request in
            if request.url!.path.hasSuffix("/get") {
                return Self.response(request, json: "{}", status: 404)
            }
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            if query?.contains(where: { $0.name == "q" }) == true {
                usedQueryFallback = true
                return Self.response(request, json: "[\(Self.syncedJSON)]")
            }
            return Self.response(request, json: #"[{"trackName":"Song","artistName":"Artist","duration":180,"syncedLyrics":"[ti:Song]","plainLyrics":" \n\t "}]"#)
        }

        await fetch(manager)
        manager.updateCurrentLine(elapsedTime: 2)

        XCTAssertTrue(usedQueryFallback)
        XCTAssertEqual(manager.currentLine, "Recovered line")
        XCTAssertEqual(fixture.writes.last?.0, .synced)
    }

    func testWhitespaceExactPlainLyricsDoNotHideSearchPlainLyrics() async {
        let fixture = LyricsRequestFixture()
        let manager = fixture.manager { request in
            Self.response(request, json: request.url!.path.hasSuffix("/get")
                ? #"{"plainLyrics":" \n\t "}"#
                : #"[{"trackName":"Song","artistName":"Artist","duration":180,"plainLyrics":"Usable lyrics"}]"#)
        }

        await fetch(manager)

        XCTAssertEqual(manager.plainLyricPreview, "Usable lyrics")
        XCTAssertEqual(fixture.writes.last?.1, "Usable lyrics")
    }

    func testDisablingLyricsInvalidatesInFlightResult() async throws {
        let fixture = LyricsRequestFixture()
        let started = expectation(description: "Request started")
        var pending: CheckedContinuation<(Data, URLResponse), Error>?
        var pendingRequest: URLRequest?
        let manager = fixture.manager { request in
            pendingRequest = request
            return try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                started.fulfill()
            }
        }
        manager.fetchLyrics(title: "Song", artist: "Artist", album: "Album", duration: 180)
        await fulfillment(of: [started], timeout: 1)
        fixture.defaults.set(false, forKey: "showLyrics")
        manager.fetchLyrics(title: "Song", artist: "Artist", album: "Album", duration: 180)
        let staleCallback = expectation(description: "Disabled lyrics must reject old response")
        staleCallback.isInverted = true
        manager.onLyricsStateChanged = { staleCallback.fulfill() }
        try XCTUnwrap(pending).resume(returning: Self.response(try XCTUnwrap(pendingRequest), json: Self.syncedJSON))
        await fulfillment(of: [staleCallback], timeout: 0.1)
        XCTAssertFalse(manager.hasLyrics)
        XCTAssertFalse(manager.isFetching)
    }

    private func fetch(_ manager: LyricsManager) async {
        let finished = expectation(description: "Lyrics lookup finished")
        manager.onLyricsStateChanged = {
            if !manager.isFetching { finished.fulfill() }
        }
        manager.fetchLyrics(title: "Song", artist: "Artist", album: "Album", duration: 180)
        await fulfillment(of: [finished], timeout: 1)
        manager.onLyricsStateChanged = nil
    }

    private static let syncedJSON = #"{"trackName":"Song","artistName":"Artist","duration":180,"syncedLyrics":"[00:01.00]Recovered line"}"#

    private static func response(_ request: URLRequest, json: String, status: Int = 200) -> (Data, URLResponse) {
        (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor
private final class LyricsRequestFixture {
    let suite = "XNook.LyricsRequestTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    var date = Date(timeIntervalSince1970: 1000)
    var writes: [(LyricsCache.EntryType, String)] = []

    init() {
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "showLyrics")
    }

    func manager(loadRequest: @escaping LyricsManager.RequestLoader) -> LyricsManager {
        LyricsManager(defaults: defaults, loadRequest: loadRequest,
                      readCache: { _, _, _ in nil },
                      writeCache: { [weak self] _, _, _, type, payload, _ in self?.writes.append((type, payload)) },
                      sleep: { _ in }, now: { [weak self] in self?.date ?? .distantPast })
    }

    deinit { defaults.removePersistentDomain(forName: suite) }
}
