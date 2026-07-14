import XCTest
@testable import XNook

@MainActor
final class MediaManagerTests: XCTestCase {

    // MARK: - MediaInfoFetchGate

    func testTimedOutInfoFetchAllowsNextRequestAndRejectsStaleResult() throws {
        var gate = MediaInfoFetchGate()
        let firstRequest = try XCTUnwrap(gate.begin())
        XCTAssertNil(gate.begin())

        gate.timeout(requestID: firstRequest)
        let secondRequest = try XCTUnwrap(gate.begin())

        XCTAssertFalse(gate.finish(requestID: firstRequest))
        XCTAssertTrue(gate.finish(requestID: secondRequest))
        XCTAssertFalse(gate.isInFlight)
    }

    // MARK: - shouldSyncLyrics

    func testEnablingLyricsRefreshesUnchangedTrack() {
        let shouldSync = MediaManager.shouldSyncLyrics(
            title: "Song",
            artist: "Artist",
            album: "Album",
            duration: 180,
            isEnabled: true,
            previousTitle: "Song",
            previousArtist: "Artist",
            previousAlbum: "Album",
            previousDuration: 180,
            wasEnabled: false
        )
        XCTAssertTrue(shouldSync)
    }

    func testDisablingLyricsTriggersSync() {
        let shouldSync = MediaManager.shouldSyncLyrics(
            title: "Song",
            artist: "Artist",
            album: "Album",
            duration: 180,
            isEnabled: false,
            previousTitle: "Song",
            previousArtist: "Artist",
            previousAlbum: "Album",
            previousDuration: 180,
            wasEnabled: true
        )
        XCTAssertTrue(shouldSync)
    }

    func testTitleChangeTriggersSync() {
        let shouldSync = MediaManager.shouldSyncLyrics(
            title: "New Song",
            artist: "Artist",
            album: "Album",
            duration: 180,
            isEnabled: true,
            previousTitle: "Old Song",
            previousArtist: "Artist",
            previousAlbum: "Album",
            previousDuration: 180,
            wasEnabled: true
        )
        XCTAssertTrue(shouldSync)
    }

    func testArtistChangeTriggersSync() {
        let shouldSync = MediaManager.shouldSyncLyrics(
            title: "Song",
            artist: "New Artist",
            album: "Album",
            duration: 180,
            isEnabled: true,
            previousTitle: "Song",
            previousArtist: "Old Artist",
            previousAlbum: "Album",
            previousDuration: 180,
            wasEnabled: true
        )
        XCTAssertTrue(shouldSync)
    }

    func testNoChangeSkipsSync() {
        let shouldSync = MediaManager.shouldSyncLyrics(
            title: "Song",
            artist: "Artist",
            album: "Album",
            duration: 180,
            isEnabled: true,
            previousTitle: "Song",
            previousArtist: "Artist",
            previousAlbum: "Album",
            previousDuration: 180,
            wasEnabled: true
        )
        XCTAssertFalse(shouldSync)
    }

    func testEmptyTitleStillTriggersOnFirstFetch() {
        let shouldSync = MediaManager.shouldSyncLyrics(
            title: "",
            artist: "",
            album: "",
            duration: nil,
            isEnabled: false,
            previousTitle: "Song",
            previousArtist: "Artist",
            previousAlbum: "Album",
            previousDuration: 180,
            wasEnabled: true
        )
        XCTAssertTrue(shouldSync)
    }

    func testAlbumChangeTriggersSync() {
        XCTAssertTrue(
            MediaManager.shouldSyncLyrics(
                title: "Song",
                artist: "Artist",
                album: "Deluxe",
                duration: 180,
                isEnabled: true,
                previousTitle: "Song",
                previousArtist: "Artist",
                previousAlbum: "Original",
                previousDuration: 180,
                wasEnabled: true
            )
        )
    }

    func testDurationArrivalTriggersLyricsRefresh() {
        XCTAssertTrue(
            MediaManager.shouldSyncLyrics(
                title: "Song",
                artist: "Artist",
                album: "Album",
                duration: 180,
                isEnabled: true,
                previousTitle: "Song",
                previousArtist: "Artist",
                previousAlbum: "Album",
                previousDuration: nil,
                wasEnabled: true
            )
        )
    }

    func testAlbumChangeResetsTrackIdentity() {
        XCTAssertTrue(
            MediaManager.hasTrackIdentityChanged(
                title: "Song",
                artist: "Artist",
                album: "Deluxe",
                previousTitle: "Song",
                previousArtist: "Artist",
                previousAlbum: "Original"
            )
        )
    }

    func testLyricTimelineRequiresPlayingStateAndAuthoritativePosition() {
        XCTAssertFalse(
            MediaManager.shouldAdvanceLyricTimeline(
                isPlaying: true,
                lyricsEnabled: true,
                hasAuthoritativePlaybackPosition: false
            )
        )
        XCTAssertTrue(
            MediaManager.shouldAdvanceLyricTimeline(
                isPlaying: true,
                lyricsEnabled: true,
                hasAuthoritativePlaybackPosition: true
            )
        )
    }

    // MARK: - compensatedElapsedTime

    func testCompensatedElapsedTimeAddsFetchLatency() {
        let sampledAt = Date(timeIntervalSince1970: 1000)
        let now = Date(timeIntervalSince1970: 1000.8) // AppleScript 链路耗时 0.8s
        XCTAssertEqual(
            MediaManager.compensatedElapsedTime(
                position: 30,
                sampledAt: sampledAt,
                now: now,
                playbackRate: 1.0
            ),
            30.8,
            accuracy: 0.0001
        )
    }

    func testCompensatedElapsedTimeIgnoresLatencyWhenPaused() {
        let sampledAt = Date(timeIntervalSince1970: 1000)
        let now = Date(timeIntervalSince1970: 1001)
        XCTAssertEqual(
            MediaManager.compensatedElapsedTime(
                position: 30,
                sampledAt: sampledAt,
                now: now,
                playbackRate: 0
            ),
            30
        )
    }

    func testCompensatedElapsedTimeClampsClockSkew() {
        // 时钟回拨等异常导致采样时刻晚于当前时刻时，不允许时间轴倒退
        let sampledAt = Date(timeIntervalSince1970: 1002)
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(
            MediaManager.compensatedElapsedTime(
                position: 30,
                sampledAt: sampledAt,
                now: now,
                playbackRate: 1.0
            ),
            30
        )
    }

    // MARK: - formatTime

    func testFormatTimeZero() {
        let manager = MediaManager()
        XCTAssertEqual(manager.formatTime(0), "0:00")
    }

    func testFormatTimeSeconds() {
        let manager = MediaManager()
        XCTAssertEqual(manager.formatTime(45), "0:45")
    }

    func testFormatTimeMinutes() {
        let manager = MediaManager()
        XCTAssertEqual(manager.formatTime(120), "2:00")
    }

    func testFormatTimeMinutesAndSeconds() {
        let manager = MediaManager()
        XCTAssertEqual(manager.formatTime(125), "2:05")
    }

    func testFormatTimeLargeDuration() {
        let manager = MediaManager()
        XCTAssertEqual(manager.formatTime(3661), "61:01")
    }

    func testFormatTimeFractionalSecondsTruncated() {
        let manager = MediaManager()
        XCTAssertEqual(manager.formatTime(90.7), "1:30")
    }
}
