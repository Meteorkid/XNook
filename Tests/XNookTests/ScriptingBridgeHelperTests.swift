import XCTest
@testable import XNook

final class ScriptingBridgeHelperTests: XCTestCase {
    func testPlaybackPositionFallsBackToAppleScriptWhenBridgeHasNoValue() {
        XCTAssertEqual(
            ScriptingBridgeHelper.resolvedPlaybackPosition(
                scriptingBridgePosition: nil,
                appleScriptPosition: 42.5
            ),
            42.5
        )
    }

    func testPlaybackPositionPrefersValidScriptingBridgeValue() {
        XCTAssertEqual(
            ScriptingBridgeHelper.resolvedPlaybackPosition(
                scriptingBridgePosition: 12.5,
                appleScriptPosition: 42.5
            ),
            12.5
        )
    }

    func testPlaybackPositionRejectsInvalidValues() {
        XCTAssertNil(
            ScriptingBridgeHelper.resolvedPlaybackPosition(
                scriptingBridgePosition: -.infinity,
                appleScriptPosition: .nan
            )
        )
    }

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
