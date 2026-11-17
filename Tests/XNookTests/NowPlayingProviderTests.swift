import XCTest
@testable import XNook

@MainActor
final class NowPlayingProviderTests: XCTestCase {
    func testNonScriptableAppUsesRemoteWithoutTouchingAppleScript() async {
        let remote: [String: Any] = [
            "title": "某期视频", "artist": "UP主", "playbackRate": 1.0,
            "sourceBundleID": "com.bilibili.bilibiliPC", "sourceName": "哔哩哔哩",
        ]
        let selected = await NowPlayingProvider.getNowPlayingInfo(
            remote: { remote },
            scripted: {
                XCTFail("哔哩哔哩没有 AppleScript 词典，不应执行脚本")
                return [:]
            }
        )
        XCTAssertEqual(selected["title"] as? String, "某期视频")
        XCTAssertEqual(MediaSource.from(info: selected)?.displayName, "哔哩哔哩")
    }

    func testRemoteSurvivesScriptReadFailure() async {
        let remote: [String: Any] = [
            "title": "QQ音乐曲目", "playbackRate": 1.0,
            "sourceBundleID": "com.tencent.QQMusicMac", "sourceName": "QQ音乐",
        ]
        let selected = await NowPlayingProvider.getNowPlayingInfo(
            remote: { remote },
            scripted: { ["fetchFailed": true] }
        )
        XCTAssertEqual(selected["title"] as? String, "QQ音乐曲目")
        XCTAssertNil(selected["fetchFailed"] as? Bool)
    }

    func testMusicUsesScriptedPositionAndRemoteArtwork() async {
        let remote: [String: Any] = [
            "title": "Song", "playbackRate": 1.0, "playerPosition": 10.0,
            "artworkData": Data([9]), "sourceBundleID": "com.apple.Music", "sourceName": "音乐",
        ]
        let scripted: [String: Any] = [
            "source": "Music", "title": "Song", "playbackRate": 1.0,
            "playerPosition": 42.5, "positionTimestamp": Date(timeIntervalSince1970: 1000),
        ]
        let selected = await NowPlayingProvider.getNowPlayingInfo(
            remote: { remote },
            scripted: { scripted }
        )
        XCTAssertEqual(selected["playerPosition"] as? Double, 42.5)
        XCTAssertEqual(selected["artworkData"] as? Data, Data([9]))
        XCTAssertEqual(selected["sourceBundleID"] as? String, "com.apple.Music")
    }

    func testMismatchedScriptedSourceIsIgnored() async {
        let remote: [String: Any] = [
            "title": "Music Song", "playbackRate": 1.0,
            "sourceBundleID": "com.apple.Music", "sourceName": "音乐",
        ]
        let selected = await NowPlayingProvider.getNowPlayingInfo(
            remote: { remote },
            scripted: { ["source": "Spotify", "title": "Spotify Song", "playbackRate": 1.0] }
        )
        XCTAssertEqual(selected["title"] as? String, "Music Song")
    }

    func testFallsBackToScriptedWhenSystemHasNoNowPlaying() async {
        let scripted: [String: Any] = ["source": "Spotify", "title": "Fallback", "playbackRate": 1.0]
        let selected = await NowPlayingProvider.getNowPlayingInfo(
            remote: { [:] },
            scripted: { scripted }
        )
        XCTAssertEqual(selected["title"] as? String, "Fallback")
    }

    func testBothSourcesEmptyReturnsEmpty() async {
        let selected = await NowPlayingProvider.getNowPlayingInfo(
            remote: { [:] },
            scripted: { [:] }
        )
        XCTAssertTrue(selected.isEmpty)
    }
}
