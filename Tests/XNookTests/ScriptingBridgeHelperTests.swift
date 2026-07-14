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

    func testPlaybackPositionPrefersAppleScriptWhenBridgeReportsZero() {
        XCTAssertEqual(
            ScriptingBridgeHelper.resolvedPlaybackPosition(
                scriptingBridgePosition: 0,
                appleScriptPosition: 42.5
            ),
            42.5
        )
    }

    func testPlaybackPositionUsesBridgeWhenAppleScriptIsUnavailable() {
        XCTAssertEqual(
            ScriptingBridgeHelper.resolvedPlaybackPosition(
                scriptingBridgePosition: 12.5,
                appleScriptPosition: nil
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

    func testArtworkCacheKeyDistinguishesFieldBoundaries() {
        // 字段内容串位不应产生相同的缓存 key
        XCTAssertNotEqual(
            ScriptingBridgeHelper.artworkCacheKey(title: "a|b", artist: "", album: "c"),
            ScriptingBridgeHelper.artworkCacheKey(title: "a", artist: "b", album: "c")
        )
        XCTAssertEqual(
            ScriptingBridgeHelper.artworkCacheKey(title: "Song", artist: "Artist", album: "Album"),
            ScriptingBridgeHelper.artworkCacheKey(title: "Song", artist: "Artist", album: "Album")
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
