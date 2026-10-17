import XCTest
import Observation
@testable import XNook

@MainActor
final class MediaPlaybackPipelineTests: XCTestCase {
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
        let fixture = PlaybackFixture()
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
    var snapshot: [String: Any]?
    var loadInfo: (@MainActor () async -> [String: Any])?
    var loadArtwork: (@MainActor ([String: Any]) async -> Data?)?
    var online = true
    var cachedLyrics = true
    var lyricRequests = 0
    static let lrc = "[00:00.00]Early\n[00:04.00]Middle\n[00:10.00]Late"

    lazy var lyrics = LyricsManager(defaults: defaults, loadRequest: { [unowned self] request in
        lyricRequests += 1
        guard online else { throw URLError(.notConnectedToInternet) }
        let payload = ["trackName": "Song", "artistName": "Artist", "syncedLyrics": Self.lrc]
        return (try JSONSerialization.data(withJSONObject: payload),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }, readCache: { [unowned self] _, _, _ in
        cachedLyrics ? LyricsCache.Entry(type: .synced, payload: Self.lrc, fetchedAt: date, key: "test") : nil
    }, writeCache: { _, _, _, _, _ in }, sleep: { _ in }, now: { [unowned self] in date })

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
        ["title": "Song", "artist": "Artist", "album": "Album", "source": "Music",
         "duration": 180.0, "playbackRate": 1.0, "playerPosition": 2.0, "positionTimestamp": date]
    }

    deinit { defaults.removePersistentDomain(forName: suite) }
}
