import XCTest
@testable import XNook

@MainActor
final class MediaRemoteRaceTests: XCTestCase {
    func testPIDChangedDuringFetchReturnsFetchFailed() {
        let raw = [MediaRemoteBridge.InfoKey.title: "某期视频"]
        let result = MediaRemoteBridge.resolveSnapshot(
            raw,
            pidBefore: 111,
            pidAfter: 222,
            now: Date(timeIntervalSince1970: 1000)
        )
        XCTAssertEqual(result["fetchFailed"] as? Bool, true)
        XCTAssertNil(result["title"])
    }

    func testStablePIDNormalizesNormally() {
        let now = Date(timeIntervalSince1970: 1000)
        let raw: [String: Any] = [
            MediaRemoteBridge.InfoKey.title: "某期视频",
            MediaRemoteBridge.InfoKey.elapsedTime: NSNumber(value: 12.5),
        ]
        let result = MediaRemoteBridge.resolveSnapshot(
            raw, pidBefore: 0, pidAfter: 0, now: now
        )
        XCTAssertEqual(result["title"] as? String, "某期视频")
        XCTAssertEqual(result["playerPosition"] as? Double, 12.5)
        XCTAssertNil(result["fetchFailed"] as? Bool)
    }

    func testPIDZeroBeforeButNonZeroAfterIsTreatedAsSwitch() {
        let raw = [MediaRemoteBridge.InfoKey.title: "歌曲"]
        let result = MediaRemoteBridge.resolveSnapshot(
            raw, pidBefore: 0, pidAfter: 456
        )
        XCTAssertEqual(result["fetchFailed"] as? Bool, true)
    }

    func testManagerWaitingStateClearsTrackAndBlocksLyrics() async {
        let suiteName = "XNook.WaitingState.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.set(true, forKey: "showLyrics")
        defer { suite.removePersistentDomain(forName: suiteName) }

        let manager = MediaManager(
            startMonitoring: false,
            defaults: suite,
            infoProvider: { [NowPlayingProvider.waitingKey: true, "sourceBundleID": "com.bilibili.bilibiliPC", "sourceName": "哔哩哔哩"] }
        )
        await manager.refreshNowPlayingInfo()

        XCTAssertTrue(manager.isWaitingForPreferredSource)
        XCTAssertEqual(manager.currentSource?.displayName, "哔哩哔哩")
        XCTAssertEqual(manager.currentTitle, "")
        XCTAssertFalse(manager.isPlaying)
        XCTAssertFalse(manager.lyricsManager.hasLyrics)

        // 等待态下控制命令不得改变播放状态
        manager.play()
        manager.togglePlayPause()
        XCTAssertFalse(manager.isPlaying)
    }
}
