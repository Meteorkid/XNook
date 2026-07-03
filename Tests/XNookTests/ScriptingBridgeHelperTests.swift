import XCTest
@testable import XNook

final class ScriptingBridgeHelperTests: XCTestCase {
    func testPlayingSpotifyWinsOverPausedMusic() {
        let music: [String: Any] = [
            "title": "Paused Music Track",
            "playbackRate": 0.0,
        ]
        let spotify: [String: Any] = [
            "title": "Playing Spotify Track",
            "playbackRate": 1.0,
        ]

        let selected = ScriptingBridgeHelper.selectNowPlayingInfo(
            music: music,
            spotify: spotify
        )

        XCTAssertEqual(selected["title"] as? String, "Playing Spotify Track")
    }
}
