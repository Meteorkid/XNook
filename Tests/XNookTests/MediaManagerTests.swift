import XCTest
@testable import XNook

@MainActor
final class MediaManagerTests: XCTestCase {

    // MARK: - shouldSyncLyrics

    func testEnablingLyricsRefreshesUnchangedTrack() {
        let shouldSync = MediaManager.shouldSyncLyrics(
            title: "Song",
            artist: "Artist",
            isEnabled: true,
            previousTitle: "Song",
            previousArtist: "Artist",
            wasEnabled: false
        )
        XCTAssertTrue(shouldSync)
    }

    func testDisablingLyricsTriggersSync() {
        let shouldSync = MediaManager.shouldSyncLyrics(
            title: "Song",
            artist: "Artist",
            isEnabled: false,
            previousTitle: "Song",
            previousArtist: "Artist",
            wasEnabled: true
        )
        XCTAssertTrue(shouldSync)
    }

    func testTitleChangeTriggersSync() {
        let shouldSync = MediaManager.shouldSyncLyrics(
            title: "New Song",
            artist: "Artist",
            isEnabled: true,
            previousTitle: "Old Song",
            previousArtist: "Artist",
            wasEnabled: true
        )
        XCTAssertTrue(shouldSync)
    }

    func testArtistChangeTriggersSync() {
        let shouldSync = MediaManager.shouldSyncLyrics(
            title: "Song",
            artist: "New Artist",
            isEnabled: true,
            previousTitle: "Song",
            previousArtist: "Old Artist",
            wasEnabled: true
        )
        XCTAssertTrue(shouldSync)
    }

    func testNoChangeSkipsSync() {
        let shouldSync = MediaManager.shouldSyncLyrics(
            title: "Song",
            artist: "Artist",
            isEnabled: true,
            previousTitle: "Song",
            previousArtist: "Artist",
            wasEnabled: true
        )
        XCTAssertFalse(shouldSync)
    }

    func testEmptyTitleStillTriggersOnFirstFetch() {
        let shouldSync = MediaManager.shouldSyncLyrics(
            title: "",
            artist: "",
            isEnabled: false,
            previousTitle: "Song",
            previousArtist: "Artist",
            wasEnabled: true
        )
        XCTAssertTrue(shouldSync)
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
