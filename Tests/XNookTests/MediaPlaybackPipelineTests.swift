import XCTest
import Observation
@testable import XNook

@MainActor
final class MediaPlaybackPipelineTests: XCTestCase {
    func testLateDurationFromMediaPollRevalidatesExistingLyricsOnlyOnce() async {
        let fixture = PlaybackFixture()
        var unknownDuration = fixture.sample()
        unknownDuration["duration"] = 0.0
        fixture.snapshot = unknownDuration
        await initialLoad(fixture)
        XCTAssertTrue(fixture.lyrics.hasLyrics)
        XCTAssertEqual(fixture.lyricRequests, 0)
        fixture.snapshot = fixture.sample()
        await initialLoad(fixture)
        XCTAssertEqual(fixture.lyricRequests, 1)
        XCTAssertEqual(fixture.lyricCacheReads, 1)
        for duration in [181.0, 182, 190] {
            var snapshot = fixture.sample()
            snapshot["duration"] = duration
            fixture.snapshot = snapshot
            await fixture.media.refreshNowPlayingInfo()
        }
        XCTAssertEqual(fixture.lyricRequests, 1)
        XCTAssertEqual(fixture.media.currentLyricLine, "Early")
    }

    func testNormalMediaPollResumesDeferredDurationCheckAfterBackoff() async {
        let fixture = PlaybackFixture()
        var unknownDuration = fixture.sample()
        unknownDuration["duration"] = 0.0
        fixture.snapshot = unknownDuration
        await initialLoad(fixture)
        fixture.online = false
        let failed = expectation(description: "Manual lookup failed with fallback")
        let previous = fixture.lyrics.onLyricsStateChanged
        fixture.lyrics.onLyricsStateChanged = {
            previous?()
            if !fixture.lyrics.isFetching { failed.fulfill() }
        }
        XCTAssertTrue(fixture.lyrics.retryCurrentTrack())
        await fulfillment(of: [failed], timeout: 1)
        fixture.lyrics.onLyricsStateChanged = previous
        fixture.snapshot = fixture.sample()
        await fixture.media.refreshNowPlayingInfo()
        XCTAssertFalse(fixture.lyrics.isFetching)
        XCTAssertEqual(fixture.lyricRequests, 2)
        fixture.date.addTimeInterval(15)
        fixture.online = true
        await initialLoad(fixture)
        XCTAssertEqual(fixture.lyricRequests, 3)
        XCTAssertEqual(fixture.lyricCacheReads, 1)
        XCTAssertFalse(fixture.lyrics.shouldRetryCurrentTrack)
    }

    func testTemporaryReadFailureKeepsLastKnownTrackAndLyrics() async {
        let fixture = PlaybackFixture()
        await initialLoad(fixture)
        fixture.media.refreshLyricLine()
        XCTAssertEqual(fixture.media.currentLyricLine, "Early")

        fixture.snapshot = ["fetchFailed": true]
        await fixture.media.refreshNowPlayingInfo()

        XCTAssertEqual(fixture.media.currentTitle, "Song")
        XCTAssertEqual(fixture.media.currentLyricLine, "Early")
        XCTAssertTrue(fixture.media.lyricsManager.hasLyrics)
    }

    func testNoPlayerClearsPlaybackState() async {
        let fixture = PlaybackFixture()
        await initialLoad(fixture)
        fixture.snapshot = [:]
        await fixture.media.refreshNowPlayingInfo()
        XCTAssertFalse(fixture.media.isPlaying)
        XCTAssertEqual(fixture.media.playbackRate, 0)
        XCTAssertEqual(fixture.media.currentTitle, "")
        XCTAssertFalse(fixture.media.lyricsManager.hasLyrics)
    }

    func testLocalClockDoesNotRunBeyondStalePlayerSample() async {
        let fixture = PlaybackFixture()
        await initialLoad(fixture)
        fixture.date.addTimeInterval(2)
        fixture.media.refreshLyricLine()
        XCTAssertEqual(fixture.media.currentLyricLine, "Middle")
        let elapsed = fixture.media.elapsedTime
        fixture.date.addTimeInterval(10)
        fixture.media.refreshLyricLine()
        XCTAssertEqual(fixture.media.elapsedTime, elapsed)
        XCTAssertEqual(fixture.media.currentLyricLine, "Middle")
    }

    func testPlaybackNotificationUsesSameInFlightGateAsRegularPoll() async {
        let fixture = PlaybackFixture()
        let started = expectation(description: "Initial poll started")
        let duplicate = expectation(description: "Notification must not start a parallel poll")
        duplicate.isInverted = true
        var pending: [CheckedContinuation<[String: Any], Never>] = []
        fixture.loadInfo = {
            await withCheckedContinuation { continuation in
                pending.append(continuation)
                if pending.count == 1 { started.fulfill() } else { duplicate.fulfill() }
            }
        }
        let first = Task { await fixture.media.refreshNowPlayingInfo() }
        await fulfillment(of: [started], timeout: 1)
        fixture.media.fetchPlaybackState()
        await fulfillment(of: [duplicate], timeout: 0.1)
        let count = pending.count
        for continuation in pending { continuation.resume(returning: fixture.sample()) }
        await first.value
        XCTAssertEqual(count, 1)
    }

    func testSameTrackRecoversLyricsViaNormalMediaPoll() async {
        let fixture = PlaybackFixture()
        fixture.cachedLyrics = false
        fixture.online = false
        await initialLoad(fixture)
        XCTAssertFalse(fixture.lyrics.hasLyrics)
        let failedRequests = fixture.lyricRequests

        fixture.online = true
        fixture.date.addTimeInterval(20)
        await initialLoad(fixture)

        XCTAssertGreaterThan(fixture.lyricRequests, failedRequests)
        XCTAssertTrue(fixture.lyrics.hasLyrics)
        fixture.media.refreshLyricLine()
        XCTAssertEqual(fixture.media.currentLyricLine, "Early")
    }

    func testLateArtworkDoesNotBlockMetadataOrReplaceNextTracksCover() async {
        await assertLateArtworkDoesNotReplaceNextTrack(source: "Music")
        await assertLateArtworkDoesNotReplaceNextTrack(source: "Spotify")
    }

    private func assertLateArtworkDoesNotReplaceNextTrack(source: String) async {
        let fixture = PlaybackFixture()
        fixture.source = source
        let artworkStarted = expectation(description: "Slow first artwork started")
        var pending: CheckedContinuation<Data?, Never>?
        fixture.loadArtwork = { info in
            if info["title"] as? String == "Song" {
                return await withCheckedContinuation { continuation in
                    pending = continuation
                    artworkStarted.fulfill()
                }
            }
            return Data([2])
        }
        await initialLoad(fixture)
        await fulfillment(of: [artworkStarted], timeout: 1)
        XCTAssertEqual(fixture.media.currentTitle, "Song")
        XCTAssertNil(fixture.media.currentArtworkData)

        var second = fixture.sample()
        second["title"] = "Next song"
        fixture.snapshot = second
        await initialLoad(fixture)
        XCTAssertEqual(fixture.media.currentTitle, "Next song")
        let deadline = Date().addingTimeInterval(1)
        while fixture.media.currentArtworkData != Data([2]), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(fixture.media.currentArtworkData, Data([2]))
        let lateApplied = expectation(description: "Old artwork must not overwrite current artwork")
        lateApplied.isInverted = true
        withObservationTracking {
            _ = fixture.media.currentArtworkData
        } onChange: {
            lateApplied.fulfill()
        }
        pending?.resume(returning: Data([1]))
        await fulfillment(of: [lateApplied], timeout: 0.1)
        XCTAssertEqual(fixture.media.currentArtworkData, Data([2]))
    }

    func testSpotifyArtworkCompletionAndRepeatedPollDoNotRefetchLyrics() async {
        let fixture = PlaybackFixture()
        fixture.source = "Spotify"
        fixture.cachedLyrics = false
        let started = expectation(description: "Spotify artwork started")
        var pending: CheckedContinuation<Data?, Never>?
        fixture.loadArtwork = { _ in
            await withCheckedContinuation { continuation in
                pending = continuation
                started.fulfill()
            }
        }
        await initialLoad(fixture)
        await fulfillment(of: [started], timeout: 1)
        let requests = fixture.lyricRequests
        let cacheReads = fixture.lyricCacheReads
        let version = fixture.media.artworkVersion
        XCTAssertGreaterThan(requests, 0)
        pending?.resume(returning: Data([2]))
        await waitForArtwork(Data([2]), fixture: fixture)
        await fixture.media.refreshNowPlayingInfo()
        XCTAssertEqual(fixture.media.currentSource, .spotify)
        XCTAssertEqual(fixture.media.artworkVersion, version + 1)
        XCTAssertEqual(fixture.lyricRequests, requests)
        XCTAssertEqual(fixture.lyricCacheReads, cacheReads)
        XCTAssertEqual(fixture.media.currentLyricLine, "Early")
    }

    func testPausedSpotifyDoesNotStartArtworkAndKeepsLoadedCover() async {
        let fixture = PlaybackFixture()
        fixture.source = "Spotify"
        var artworkRequests = 0
        fixture.loadArtwork = { _ in
            artworkRequests += 1
            return Data([2])
        }
        var paused = fixture.sample()
        paused["playbackRate"] = 0.0
        fixture.snapshot = paused
        await initialLoad(fixture)
        XCTAssertEqual(artworkRequests, 0)
        XCTAssertNil(fixture.media.currentArtworkData)

        fixture.snapshot = fixture.sample()
        await fixture.media.refreshNowPlayingInfo()
        await waitForArtwork(Data([2]), fixture: fixture)
        fixture.snapshot = paused
        await fixture.media.refreshNowPlayingInfo()
        XCTAssertFalse(fixture.media.isPlaying)
        XCTAssertEqual(fixture.media.currentArtworkData, Data([2]))
        XCTAssertEqual(artworkRequests, 1)
    }

    func testSpotifyArtworkFailureRetriesOnlyAfterThirtySeconds() async {
        let fixture = PlaybackFixture()
        fixture.source = "Spotify"
        let first = expectation(description: "First Spotify artwork failure")
        let retry = expectation(description: "Retry after the backoff")
        var artworkRequests = 0
        fixture.loadArtwork = { _ in
            artworkRequests += 1
            if artworkRequests == 1 { first.fulfill() } else { retry.fulfill() }
            return nil
        }
        await initialLoad(fixture)
        await fulfillment(of: [first], timeout: 1)
        fixture.date.addTimeInterval(29)
        await fixture.media.refreshNowPlayingInfo()
        XCTAssertEqual(artworkRequests, 1)
        fixture.date.addTimeInterval(2)
        await fixture.media.refreshNowPlayingInfo()
        await fulfillment(of: [retry], timeout: 1)
        XCTAssertEqual(artworkRequests, 2)
        XCTAssertNil(fixture.media.currentArtworkData)
    }

    func testSameNamedTrackFromAnotherSourceRejectsPreviousArtwork() async {
        let fixture = PlaybackFixture()
        let started = expectation(description: "Old source artwork started")
        var pending: CheckedContinuation<Data?, Never>?
        fixture.loadArtwork = { info in
            if info["source"] as? String == "Music" {
                return await withCheckedContinuation { continuation in
                    pending = continuation
                    started.fulfill()
                }
            }
            return Data([2])
        }
        await initialLoad(fixture)
        await fulfillment(of: [started], timeout: 1)
        fixture.source = "Spotify"
        await fixture.media.refreshNowPlayingInfo()
        await waitForArtwork(Data([2]), fixture: fixture)
        let staleApplied = expectation(description: "Old source must not overwrite Spotify artwork")
        staleApplied.isInverted = true
        withObservationTracking {
            _ = fixture.media.currentArtworkData
        } onChange: {
            staleApplied.fulfill()
        }
        pending?.resume(returning: Data([1]))
        await fulfillment(of: [staleApplied], timeout: 0.1)
        XCTAssertEqual(fixture.media.currentSource, .spotify)
        XCTAssertEqual(fixture.media.currentArtworkData, Data([2]))
    }

    private func waitForArtwork(_ data: Data, fixture: PlaybackFixture) async {
        let deadline = Date().addingTimeInterval(1)
        while fixture.media.currentArtworkData != data, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(fixture.media.currentArtworkData, data)
    }

    private func initialLoad(_ fixture: PlaybackFixture) async {
        let loaded = expectation(description: "Lyrics state delivered through media pipeline")
        let previous = fixture.media.lyricsManager.onLyricsStateChanged
        fixture.media.lyricsManager.onLyricsStateChanged = {
            previous?()
            if !fixture.lyrics.isFetching { loaded.fulfill() }
        }
        await fixture.media.refreshNowPlayingInfo()
        await fulfillment(of: [loaded], timeout: 1)
        fixture.media.lyricsManager.onLyricsStateChanged = previous
    }
}

@MainActor
private final class PlaybackFixture {
    let suite = "XNook.PlaybackPipeline.\(UUID().uuidString)"
    let defaults: UserDefaults
    var date = Date(timeIntervalSince1970: 1000)
    var source = "Music"
    var snapshot: [String: Any]?
    var loadInfo: (@MainActor () async -> [String: Any])?
    var loadArtwork: (@MainActor ([String: Any]) async -> Data?)?
    var online = true
    var cachedLyrics = true
    var lyricRequests = 0
    var lyricCacheReads = 0
    static let lrc = "[00:00.00]Early\n[00:04.00]Middle\n[00:10.00]Late"

    lazy var lyrics = LyricsManager(defaults: defaults, loadRequest: { [unowned self] request in
        lyricRequests += 1
        guard online else { throw URLError(.notConnectedToInternet) }
        let payload = ["trackName": "Song", "artistName": "Artist", "syncedLyrics": Self.lrc]
        return (try JSONSerialization.data(withJSONObject: payload),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }, readCache: { [unowned self] _, _, _ in
        lyricCacheReads += 1
        return cachedLyrics ? LyricsCache.Entry(type: .synced, payload: Self.lrc, fetchedAt: date, key: "test") : nil
    }, writeCache: { _, _, _, _, _, _ in }, sleep: { _ in }, now: { [unowned self] in date })

    lazy var media = MediaManager(startMonitoring: false, defaults: defaults, lyricsManager: lyrics,
        infoProvider: { [unowned self] in
            if let loadInfo { return await loadInfo() }
            return snapshot ?? sample()
        }, artworkProvider: { [weak self] info in await self?.loadArtwork?(info) },
        clock: { [weak self] in self?.date ?? .distantPast })

    init() {
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "showLyrics")
    }

    func sample() -> [String: Any] {
        ["title": "Song", "artist": "Artist", "album": "Album", "source": source,
         "duration": 180.0, "playbackRate": 1.0, "playerPosition": 2.0, "positionTimestamp": date]
    }

    deinit { defaults.removePersistentDomain(forName: suite) }
}
