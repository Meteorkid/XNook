import XCTest
@testable import XNook

@MainActor
final class MediaManagerTests: XCTestCase {
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
}
