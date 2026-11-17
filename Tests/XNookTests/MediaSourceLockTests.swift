import XCTest
@testable import XNook

@MainActor
final class MediaSourceLockTests: XCTestCase {
    private let musicID = ScriptingBridgeHelper.SupportedApp.music.bundleIdentifier
    private let spotifyID = ScriptingBridgeHelper.SupportedApp.spotify.bundleIdentifier

    // MARK: - 偏好解析

    func testAutoModeResolvesToNoLock() {
        let defaults = suite(name: "auto")
        XCTAssertNil(MediaSourcePreference.resolvedBundleID(defaults: defaults))
    }

    func testPresetModeResolvesToBundleID() {
        let defaults = suite(name: "preset")
        defaults.set("com.tencent.QQMusicMac", forKey: MediaSourcePreference.modeKey)
        XCTAssertEqual(MediaSourcePreference.resolvedBundleID(defaults: defaults), "com.tencent.QQMusicMac")
    }

    func testCustomModeUsesTrimmedBundleID() {
        let defaults = suite(name: "custom")
        defaults.set(MediaSourcePreference.customMode, forKey: MediaSourcePreference.modeKey)
        defaults.set("  com.example.player  ", forKey: MediaSourcePreference.customKey)
        XCTAssertEqual(MediaSourcePreference.resolvedBundleID(defaults: defaults), "com.example.player")
    }

    func testEmptyCustomFallsBackToAuto() {
        let defaults = suite(name: "emptycustom")
        defaults.set(MediaSourcePreference.customMode, forKey: MediaSourcePreference.modeKey)
        defaults.set("   ", forKey: MediaSourcePreference.customKey)
        XCTAssertNil(MediaSourcePreference.resolvedBundleID(defaults: defaults))
    }

    // MARK: - 锁定取值

    func testLockedScriptAppIgnoresSystemNowPlaying() async {
        let musicInfo: [String: Any] = ["source": "Music", "title": "锁定曲目", "playbackRate": 1.0]
        let selected = await NowPlayingProvider.getNowPlayingInfo(
            preferredBundleID: musicID,
            remote: {
                XCTFail("锁定 Apple Music 时不读系统 Now Playing")
                return ["title": "B站视频", "sourceBundleID": "com.bilibili.bilibiliPC"]
            },
            scripted: { XCTFail("锁定模式下不走双播放器选举"); return [:] },
            scriptedMusic: { musicInfo },
            scriptedSpotify: { XCTFail("不应读取 Spotify"); return nil }
        )
        XCTAssertEqual(selected["title"] as? String, "锁定曲目")
        XCTAssertEqual(selected["sourceBundleID"] as? String, musicID)
        XCTAssertNil(selected[NowPlayingProvider.waitingKey] as? Bool)
    }

    func testLockedNonScriptAppAcceptsMatchingRemote() async {
        let remote: [String: Any] = [
            "title": "QQ音乐歌曲", "playbackRate": 1.0,
            "sourceBundleID": "com.tencent.QQMusicMac", "sourceName": "QQ音乐",
        ]
        let selected = await NowPlayingProvider.getNowPlayingInfo(
            preferredBundleID: "com.tencent.QQMusicMac",
            remote: { remote }
        )
        XCTAssertEqual(selected["title"] as? String, "QQ音乐歌曲")
        XCTAssertNil(selected[NowPlayingProvider.waitingKey] as? Bool)
    }

    func testLockedNonScriptAppRejectsOtherPlayer() async {
        let selected = await NowPlayingProvider.getNowPlayingInfo(
            preferredBundleID: "com.tencent.QQMusicMac",
            remote: {
                ["title": "B站视频", "playbackRate": 1.0, "sourceBundleID": "com.bilibili.bilibiliPC"]
            }
        )
        XCTAssertEqual(selected[NowPlayingProvider.waitingKey] as? Bool, true)
        XCTAssertEqual(selected["sourceBundleID"] as? String, "com.tencent.QQMusicMac")
        XCTAssertNil(selected["title"] as? String)
    }

    func testLockedAppWithNoPlaybackReturnsWaiting() async {
        let selected = await NowPlayingProvider.getNowPlayingInfo(
            preferredBundleID: "com.bilibili.bilibiliPC",
            remote: { [:] }
        )
        XCTAssertEqual(selected[NowPlayingProvider.waitingKey] as? Bool, true)
        XCTAssertEqual(selected["sourceName"] as? String, "哔哩哔哩")
    }

    func testLockedScriptAppWithNoTrackReturnsWaiting() async {
        let selected = await NowPlayingProvider.getNowPlayingInfo(
            preferredBundleID: spotifyID,
            scriptedMusic: { XCTFail("不应读取 Music"); return nil },
            scriptedSpotify: { nil }
        )
        XCTAssertEqual(selected[NowPlayingProvider.waitingKey] as? Bool, true)
        XCTAssertEqual(selected["sourceName"] as? String, "Spotify")
    }

    // MARK: - 来源展示名

    func testDisplayNameFallsBackToBundleID() {
        XCTAssertEqual(MediaSourcePreference.displayName(for: "com.example.player"), "com.example.player")
        XCTAssertEqual(MediaSourcePreference.displayName(for: "com.bilibili.bilibiliPC"), "哔哩哔哩")
    }

    private func suite(name: String) -> UserDefaults {
        UserDefaults(suiteName: "XNook.SourceLock.\(name).\(UUID().uuidString)")!
    }
}
