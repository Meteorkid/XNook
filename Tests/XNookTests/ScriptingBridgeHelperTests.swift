import AppKit
import XCTest
@testable import XNook

final class ScriptingBridgeHelperTests: XCTestCase {
    private func snapshot(
        title: String = "Song",
        duration: Double = 210,
        rate: Double = 1,
        position: NSAppleEventDescriptor = NSAppleEventDescriptor(double: 42.5)
    ) -> NSAppleEventDescriptor {
        let descriptor = NSAppleEventDescriptor.list()
        let values = [
            NSAppleEventDescriptor(string: title),
            NSAppleEventDescriptor(string: "Artist"),
            NSAppleEventDescriptor(string: "Album"),
            NSAppleEventDescriptor(double: duration),
            NSAppleEventDescriptor(double: rate),
            position,
        ]
        for (index, value) in values.enumerated() {
            descriptor.insert(value, at: index + 1)
        }
        return descriptor
    }

    func testSnapshotParsesSecondsAndSamplesPositionAtCompletion() {
        let sampleTime = Date(timeIntervalSince1970: 1_000)
        let info = ScriptingBridgeHelper.parseSnapshot(snapshot(), from: .music, sampledAt: sampleTime)
        XCTAssertEqual(info?["title"] as? String, "Song")
        XCTAssertEqual(info?["duration"] as? Double, 210)
        XCTAssertEqual(info?["playbackRate"] as? Double, 1)
        XCTAssertEqual(info?["playerPosition"] as? Double, 42.5)
        XCTAssertEqual(info?["positionTimestamp"] as? Date, sampleTime)
    }

    func testSpotifySnapshotConvertsDurationFromMilliseconds() {
        let info = ScriptingBridgeHelper.parseSnapshot(snapshot(duration: 210_000), from: .spotify)
        XCTAssertEqual(info?["duration"] as? Double, 210)
        XCTAssertEqual(info?["playerPosition"] as? Double, 42.5)
    }

    func testSnapshotDoesNotCoerceMissingOrInvalidPositionIntoZero() {
        for position in [
            NSAppleEventDescriptor.null(),
            NSAppleEventDescriptor(string: "unavailable"),
            NSAppleEventDescriptor(double: -.infinity),
            NSAppleEventDescriptor(double: -1),
        ] {
            let info = ScriptingBridgeHelper.parseSnapshot(snapshot(position: position), from: .music)
            XCTAssertNotNil(info)
            XCTAssertNil(info?["playerPosition"])
            XCTAssertNil(info?["positionTimestamp"])
        }
        let zero = ScriptingBridgeHelper.parseSnapshot(
            snapshot(position: NSAppleEventDescriptor(double: 0)), from: .music
        )
        XCTAssertEqual(zero?["playerPosition"] as? Double, 0)
    }

    func testSnapshotRejectsMalformedReplyButAcceptsStoppedPlayer() {
        XCTAssertNil(ScriptingBridgeHelper.parseSnapshot(NSAppleEventDescriptor.null(), from: .music))
        XCTAssertNil(ScriptingBridgeHelper.parseSnapshot(NSAppleEventDescriptor.list(), from: .music))
        let stopped = ScriptingBridgeHelper.parseSnapshot(
            snapshot(title: "", rate: 0, position: NSAppleEventDescriptor.null()), from: .music
        )
        XCTAssertEqual(stopped?["playbackRate"] as? Double, 0)
    }

    func testSnapshotScriptsHaveBoundedEventsAndDoNotFetchArtwork() {
        for app in [ScriptingBridgeHelper.SupportedApp.music, .spotify] {
            let script = ScriptingBridgeHelper.snapshotScript(for: app)
            XCTAssertTrue(script.contains("with timeout of 2 seconds"))
            XCTAssertTrue(script.contains("is not running"))
            XCTAssertFalse(script.contains("raw data"))
            let position = script.range(of: "set snapshotPosition to player position")!
            XCTAssertFalse(script[position.upperBound...].contains(" of snapshotTrack"))
        }
        XCTAssertTrue(ScriptingBridgeHelper.musicArtworkScript.contains("with timeout of 2 seconds"))
        XCTAssertTrue(ScriptingBridgeHelper.musicArtworkScript.contains("is not running"))
        for command in [ScriptingBridgeHelper.PlaybackCommand.play, .pause, .nextTrack, .previousTrack] {
            for app in [ScriptingBridgeHelper.SupportedApp.music, .spotify] {
                let source = ScriptingBridgeHelper.commandScript(command, for: app)
                XCTAssertTrue(source.contains("with timeout of 2 seconds"))
                XCTAssertTrue(source.contains("is not running"))
            }
        }
    }

    func testMusicMetadataCompletesWhileArtworkIsStillPending() async {
        let metadataReturned = expectation(description: "Metadata is independent from pending artwork")
        let artworkStarted = expectation(description: "Artwork started")
        let gate = ArtworkGate()
        let cache = ScriptingBridgeHelper.ArtworkCache()
        let info: [String: Any] = ["source": "Music", "title": "Song", "artist": "Artist", "album": "Album", "playbackRate": 1.0]
        let artworkTask = Task {
            await ScriptingBridgeHelper.getArtwork(for: info, cache: cache, isRunning: { _ in true }) { _, _ in
                artworkStarted.fulfill()
                await gate.wait()
                return nil
            }
        }
        await fulfillment(of: [artworkStarted], timeout: 1)
        let expected = snapshot()
        let metadataTask = Task {
            let result = await ScriptingBridgeHelper.getNowPlayingFromMusic(isRunning: { _ in true }) { source, _ in
                XCTAssertFalse(source.contains("raw data"))
                return expected
            }
            XCTAssertEqual(result?["playerPosition"] as? Double, 42.5)
            metadataReturned.fulfill()
        }
        await fulfillment(of: [metadataReturned], timeout: 1)
        await gate.release()
        _ = await artworkTask.value
        await metadataTask.value
    }

    func testRunningPlayerReadFailureIsDifferentFromAllPlayersClosed() async {
        let failed = await ScriptingBridgeHelper.getNowPlayingInfo(isRunning: { $0 == .music }) { _, _ in nil }
        XCTAssertEqual(failed["fetchFailed"] as? Bool, true)
        let closed = await ScriptingBridgeHelper.getNowPlayingInfo(isRunning: { _ in false }) { _, _ in
            XCTFail("Closed players must not receive events")
            return nil
        }
        XCTAssertTrue(closed.isEmpty)
    }

    func testClosedMusicIsNeverQueriedByDirectSnapshotMethod() async {
        let result = await ScriptingBridgeHelper.getNowPlayingFromMusic(isRunning: { _ in false }) { _, _ in
            XCTFail("Snapshot must not launch Music")
            return nil
        }
        XCTAssertNil(result)
    }

    func testArtworkCacheKeepsSuccessfulDataWhenPlaybackIsPaused() async {
        let cache = ScriptingBridgeHelper.ArtworkCache()
        let expected = Data([1, 2, 3])
        _ = await cache.data(for: "song") { expected }
        let result = await cache.data(for: "song", allowLoading: false) {
            XCTFail("Paused playback should use its cached artwork")
            return nil
        }
        XCTAssertEqual(result, expected)
        let uncached = await cache.data(for: "other", allowLoading: false) {
            XCTFail("Paused playback should not load uncached artwork")
            return nil
        }
        XCTAssertNil(uncached)
    }

    func testArtworkFailureBacksOffAndConcurrentReadsAreDeduplicated() async {
        let cache = ScriptingBridgeHelper.ArtworkCache(retryDelay: 30)
        let gate = ArtworkGate()
        let started = expectation(description: "First artwork request")
        let now = Date(timeIntervalSince1970: 100)
        let first = Task {
            await cache.data(for: "song", now: now) {
                started.fulfill()
                await gate.wait()
                return nil
            }
        }
        await fulfillment(of: [started], timeout: 1)
        let second = Task {
            await cache.data(for: "song", now: now) {
                XCTFail("Concurrent artwork requests should be coalesced")
                return nil
            }
        }
        await gate.release()
        _ = await first.value
        _ = await second.value
        _ = await cache.data(for: "song", now: now.addingTimeInterval(29)) {
            XCTFail("A failed artwork request should back off")
            return nil
        }
        let retried = await cache.data(for: "song", now: now.addingTimeInterval(31)) {
            Data([1, 2, 3])
        }
        XCTAssertEqual(retried, Data([1, 2, 3]))
    }

    func testArtworkIsRejectedWhenTrackChangesDuringRead() throws {
        let descriptor = NSAppleEventDescriptor.list()
        let bytes = try XCTUnwrap(NSAppleEventDescriptor(descriptorType: typeData, data: Data([1, 2, 3])))
        let values = [
            NSAppleEventDescriptor(string: "Song"), NSAppleEventDescriptor(string: "Artist"),
            NSAppleEventDescriptor(string: "Album"), bytes,
            NSAppleEventDescriptor(string: "Other"), NSAppleEventDescriptor(string: "Artist"),
            NSAppleEventDescriptor(string: "Album"),
        ]
        for (index, value) in values.enumerated() { descriptor.insert(value, at: index + 1) }
        let key = ScriptingBridgeHelper.artworkCacheKey(title: "Song", artist: "Artist", album: "Album")
        XCTAssertNil(ScriptingBridgeHelper.parseArtwork(descriptor, expectedTrackKey: key))
        // AppleEvent 的 insert 实际会替换已有位置，先 remove 会让后续字段左移。
        descriptor.insert(NSAppleEventDescriptor(string: "Song"), at: 5)
        XCTAssertEqual(descriptor.numberOfItems, 7)
        XCTAssertEqual(ScriptingBridgeHelper.parseArtwork(descriptor, expectedTrackKey: key), Data([1, 2, 3]))
    }
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

    func testSelectedSourceIdentifiesMusicAndSpotify() {
        XCTAssertEqual(
            ScriptingBridgeHelper.supportedApp(from: ["source": "Music"]),
            .music
        )
        XCTAssertEqual(
            ScriptingBridgeHelper.supportedApp(from: ["source": "Spotify"]),
            .spotify
        )
        XCTAssertNil(ScriptingBridgeHelper.supportedApp(from: [:]))
    }
}

private actor ArtworkGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}
