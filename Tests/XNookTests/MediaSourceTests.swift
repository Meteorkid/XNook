import XCTest
@testable import XNook

@MainActor
final class MediaSourceTests: XCTestCase {
    func testKnownChineseAppsAreIdentifiedByBundleIdentifier() {
        let qq = MediaSource.from(info: ["sourceBundleID": "com.tencent.QQMusicMac"])
        XCTAssertEqual(qq?.displayName, "QQ音乐")
        XCTAssertEqual(qq?.kind, .music)

        let netease = MediaSource.from(info: ["sourceBundleID": "com.netease.163music"])
        XCTAssertEqual(netease?.displayName, "网易云音乐")
        XCTAssertEqual(netease?.kind, .music)

        let bilibili = MediaSource.from(info: ["sourceBundleID": "com.bilibili.bilibiliPC"])
        XCTAssertEqual(bilibili?.displayName, "哔哩哔哩")
        XCTAssertEqual(bilibili?.kind, .video)
    }

    func testUnknownAppUsesSystemDisplayName() {
        let source = MediaSource.from(info: [
            "sourceBundleID": "com.example.player",
            "sourceName": "随便一个播放器",
        ])
        XCTAssertEqual(source?.bundleIdentifier, "com.example.player")
        XCTAssertEqual(source?.displayName, "随便一个播放器")
        XCTAssertEqual(source?.kind, .other)
    }

    func testAppleScriptSourceStillResolvesMusicAndSpotify() {
        XCTAssertEqual(MediaSource.from(info: ["source": "Music"]), .appleMusic)
        XCTAssertEqual(MediaSource.from(info: ["source": "Spotify"]), .spotify)
        XCTAssertNil(MediaSource.from(info: [:]))
    }

    func testOnlyMusicAndSpotifyHaveScriptingApp() {
        XCTAssertEqual(MediaSource.appleMusic.scriptingApp, .music)
        XCTAssertEqual(MediaSource.spotify.scriptingApp, .spotify)
        XCTAssertNil(MediaSource.from(info: ["sourceBundleID": "com.tencent.QQMusicMac"])?.scriptingApp)
        XCTAssertNil(MediaSource.from(info: ["sourceBundleID": "com.bilibili.bilibiliPC"])?.scriptingApp)
    }

    func testNormalizeMapsSystemKeysIntoPlaybackFields() {
        let now = Date(timeIntervalSince1970: 1000)
        let raw: [String: Any] = [
            MediaRemoteBridge.InfoKey.title: "稻香",
            MediaRemoteBridge.InfoKey.artist: "周杰伦",
            MediaRemoteBridge.InfoKey.album: "魔杰座",
            MediaRemoteBridge.InfoKey.duration: NSNumber(value: 223.5),
            MediaRemoteBridge.InfoKey.playbackRate: NSNumber(value: 1),
            MediaRemoteBridge.InfoKey.elapsedTime: NSNumber(value: 42.5),
            MediaRemoteBridge.InfoKey.artworkData: Data([1, 2, 3]),
        ]
        let info = MediaRemoteBridge.normalize(raw, pid: 0, now: now)

        XCTAssertEqual(info["title"] as? String, "稻香")
        XCTAssertEqual(info["artist"] as? String, "周杰伦")
        XCTAssertEqual(info["album"] as? String, "魔杰座")
        XCTAssertEqual(info["duration"] as? Double, 223.5)
        XCTAssertEqual(info["playbackRate"] as? Double, 1)
        XCTAssertEqual(info["playerPosition"] as? Double, 42.5)
        XCTAssertEqual(info["positionTimestamp"] as? Date, now)
        XCTAssertEqual(info["artworkData"] as? Data, Data([1, 2, 3]))
    }

    func testNormalizeRejectsEmptyTitleAndInvalidNumbers() {
        XCTAssertTrue(MediaRemoteBridge.normalize([:], pid: 0).isEmpty)
        XCTAssertTrue(MediaRemoteBridge.normalize([MediaRemoteBridge.InfoKey.title: ""], pid: 0).isEmpty)

        let info = MediaRemoteBridge.normalize([
            MediaRemoteBridge.InfoKey.title: "视频",
            MediaRemoteBridge.InfoKey.duration: NSNumber(value: -1),
            MediaRemoteBridge.InfoKey.playbackRate: NSNumber(value: Double.nan),
            MediaRemoteBridge.InfoKey.elapsedTime: "not a number",
        ], pid: 0)
        XCTAssertNil(info["duration"])
        XCTAssertNil(info["playbackRate"])
        XCTAssertNil(info["playerPosition"])
        XCTAssertNil(info["positionTimestamp"])
    }
}
