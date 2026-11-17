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
            XCTAssertFalse(script.contains("artwork url"))
            let position = script.range(of: "set snapshotPosition to player position")!
            XCTAssertFalse(script[position.upperBound...].contains(" of snapshotTrack"))
        }
        XCTAssertTrue(ScriptingBridgeHelper.musicArtworkScript.contains("with timeout of 2 seconds"))
        XCTAssertTrue(ScriptingBridgeHelper.musicArtworkScript.contains("is not running"))
        XCTAssertTrue(ScriptingBridgeHelper.spotifyArtworkScript.contains("with timeout of 2 seconds"))
        XCTAssertTrue(ScriptingBridgeHelper.spotifyArtworkScript.contains("is not running"))
        XCTAssertTrue(ScriptingBridgeHelper.spotifyArtworkScript.contains("artwork url of artworkTrack"))
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
            await ScriptingBridgeHelper.getArtwork(for: info, cache: cache, isRunning: { _ in true }, execute: { _, _ in
                artworkStarted.fulfill()
                await gate.wait()
                return nil
            })
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

    func testSpotifyArtworkIsDownloadedAndReusedWhilePaused() async throws {
        let cache = ScriptingBridgeHelper.ArtworkCache()
        let image = try ArtworkTestImage.data()
        let url = URL(string: "https://i.scdn.co/image/cover")!
        let descriptor = artworkDescriptor(value: NSAppleEventDescriptor(string: url.absoluteString))
        let result = await ScriptingBridgeHelper.getArtwork(
            for: spotifyInfo(), cache: cache, isRunning: { $0 == .spotify }, download: { request in
                XCTAssertEqual(request.url, url)
                return (image, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }, execute: { script, app in
                XCTAssertEqual(app, .spotify)
                XCTAssertEqual(script, ScriptingBridgeHelper.spotifyArtworkScript)
                return descriptor
            }
        )
        XCTAssertNotNil(result.flatMap { NSImage(data: $0) })
        let paused = await ScriptingBridgeHelper.getArtwork(
            for: spotifyInfo(rate: 0), cache: cache, isRunning: { _ in true }, download: { _ in
                XCTFail("Paused playback must not download artwork")
                throw URLError(.cancelled)
            }, execute: { _, _ in
                XCTFail("Paused playback must use the cached artwork")
                return nil
            }
        )
        XCTAssertEqual(paused, result)
    }

    func testSpotifyMetadataCompletesWhileArtworkDownloadIsPending() async {
        let started = expectation(description: "Spotify download started")
        let metadataReturned = expectation(description: "Spotify metadata is independent from download")
        let gate = ArtworkGate()
        let descriptor = artworkDescriptor(value: NSAppleEventDescriptor(string: "https://i.scdn.co/image/cover"))
        let artwork = Task {
            await ScriptingBridgeHelper.getArtwork(
                for: spotifyInfo(), cache: ScriptingBridgeHelper.ArtworkCache(), isRunning: { _ in true },
                download: { _ in
                    started.fulfill()
                    await gate.wait()
                    throw URLError(.timedOut)
                }, execute: { _, _ in descriptor }
            )
        }
        await fulfillment(of: [started], timeout: 1)
        let expected = snapshot(duration: 210_000)
        let metadata = Task {
            let info = await ScriptingBridgeHelper.getNowPlayingFromSpotify(isRunning: { _ in true }) { source, app in
                XCTAssertEqual(app, .spotify)
                XCTAssertFalse(source.contains("artwork url"))
                return expected
            }
            XCTAssertEqual(info?["duration"] as? Double, 210)
            metadataReturned.fulfill()
        }
        await fulfillment(of: [metadataReturned], timeout: 1)
        await gate.release()
        _ = await artwork.value
        await metadata.value
    }

    func testSpotifyArtworkRejectsInvalidURLAndTrackChangedDuringRead() async {
        let descriptors = [
            artworkDescriptor(value: NSAppleEventDescriptor(string: "http://example.com/cover.png")),
            artworkDescriptor(value: NSAppleEventDescriptor(string: "file:///tmp/cover.png")),
            artworkDescriptor(value: NSAppleEventDescriptor.null()),
            artworkDescriptor(value: NSAppleEventDescriptor(string: "https://i.scdn.co/image/cover"), afterTitle: "Next song"),
        ]
        for descriptor in descriptors {
            let result = await ScriptingBridgeHelper.getArtwork(
                for: spotifyInfo(), cache: ScriptingBridgeHelper.ArtworkCache(), isRunning: { _ in true },
                download: { _ in
                    XCTFail("An invalid or stale artwork URL must not start a download")
                    throw URLError(.cancelled)
                }, execute: { _, _ in descriptor }
            )
            XCTAssertNil(result)
        }
    }

    func testSpotifyArtworkFailureBacksOffWithoutRepeatingScriptOrDownload() async {
        for responseBody in [Data("not an image".utf8), Data()] {
            let cache = ScriptingBridgeHelper.ArtworkCache()
            let url = URL(string: "https://i.scdn.co/image/cover")!
            let descriptor = artworkDescriptor(value: NSAppleEventDescriptor(string: url.absoluteString))
            var requests = 0
            var scriptReads = 0
            for _ in 0..<2 {
                let result = await ScriptingBridgeHelper.getArtwork(
                    for: spotifyInfo(), cache: cache, isRunning: { _ in true }, download: { _ in
                        requests += 1
                        if responseBody.isEmpty { throw URLError(.notConnectedToInternet) }
                        return (responseBody, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                    }, execute: { _, _ in
                        scriptReads += 1
                        return descriptor
                    }
                )
                XCTAssertNil(result)
            }
            XCTAssertEqual(requests, 1)
            XCTAssertEqual(scriptReads, 1)
        }
    }

    func testMusicAndSpotifyWithSameMetadataDoNotShareArtworkCache() async throws {
        let cache = ScriptingBridgeHelper.ArtworkCache()
        let musicBytes = Data([1, 2, 3])
        let musicDescriptor = artworkDescriptor(value: try XCTUnwrap(NSAppleEventDescriptor(descriptorType: typeData, data: musicBytes)))
        var musicInfo = spotifyInfo()
        musicInfo["source"] = "Music"
        let music = await ScriptingBridgeHelper.getArtwork(for: musicInfo, cache: cache, isRunning: { _ in true }, execute: { _, _ in musicDescriptor })
        XCTAssertEqual(music, musicBytes)
        let url = URL(string: "https://i.scdn.co/image/cover")!
        let spotifyDescriptor = artworkDescriptor(value: NSAppleEventDescriptor(string: url.absoluteString))
        let image = try ArtworkTestImage.data()
        var downloaded = false
        let spotify = await ScriptingBridgeHelper.getArtwork(
            for: spotifyInfo(), cache: cache, isRunning: { _ in true }, download: { _ in
                downloaded = true
                return (image, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }, execute: { _, _ in spotifyDescriptor }
        )
        XCTAssertTrue(downloaded)
        XCTAssertNotEqual(spotify, music)
        XCTAssertNotNil(spotify.flatMap { NSImage(data: $0) })
    }

    func testClosedOrUncachedPausedSpotifyNeverReadsArtwork() async {
        for running in [true, false] {
            let result = await ScriptingBridgeHelper.getArtwork(
                for: spotifyInfo(rate: running ? 0 : 1), cache: ScriptingBridgeHelper.ArtworkCache(),
                isRunning: { _ in running }, execute: { _, _ in
                    XCTFail("Closed or uncached paused Spotify must not receive artwork events")
                    return nil
                }
            )
            XCTAssertNil(result)
        }
    }

    func testLateArtworkCacheResultDoesNotEvictNewTrack() async {
        let cache = ScriptingBridgeHelper.ArtworkCache()
        let started = expectation(description: "Old cache request started")
        let gate = ArtworkGate()
        let old = Task {
            await cache.data(for: "old") {
                started.fulfill()
                await gate.wait()
                return Data([1])
            }
        }
        await fulfillment(of: [started], timeout: 1)
        let new = await cache.data(for: "new") { Data([2]) }
        await gate.release()
        _ = await old.value
        let cached = await cache.data(for: "new") {
            XCTFail("Late artwork must not evict the newer track's cache")
            return nil
        }
        XCTAssertEqual(cached, new)
    }

    func testCancelledArtworkDoesNotPopulateCacheOrStartFailureBackoff() async {
        let cache = ScriptingBridgeHelper.ArtworkCache()
        let started = expectation(description: "Artwork that will be cancelled started")
        let gate = ArtworkGate()
        let task = Task {
            await cache.data(for: "song") {
                started.fulfill()
                await gate.wait()
                XCTAssertTrue(Task.isCancelled)
                return Data([1])
            }
        }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        await gate.release()
        let cancelled = await task.value
        XCTAssertNil(cancelled)
        let replacement = await cache.data(for: "song") { Data([2]) }
        XCTAssertEqual(replacement, Data([2]))
    }

    func testReturningToCancelledTrackStartsFreshArtworkBeforeOldRequestFinishes() async {
        let cache = ScriptingBridgeHelper.ArtworkCache()
        let oldStarted = expectation(description: "First A request started")
        let replacementFinished = expectation(description: "New A finishes while cancelled A is still blocked")
        let oldGate = ArtworkGate()
        let oldA = Task {
            await cache.data(for: "A") {
                oldStarted.fulfill()
                await oldGate.wait()
                return Data([1])
            }
        }
        await fulfillment(of: [oldStarted], timeout: 1)
        oldA.cancel()
        let artworkB = await cache.data(for: "B") { Data([2]) }
        XCTAssertEqual(artworkB, Data([2]))

        let newA = Task {
            let data = await cache.data(for: "A") { Data([3]) }
            replacementFinished.fulfill()
            return data
        }
        await fulfillment(of: [replacementFinished], timeout: 1)
        // 旧请求始终由显式门控制；若新请求错误地加入旧任务，先释放以免测试挂死。
        await oldGate.release()
        let currentArtwork = await newA.value
        let cancelledArtwork = await oldA.value
        XCTAssertEqual(currentArtwork, Data([3]))
        XCTAssertNil(cancelledArtwork)
        let cached = await cache.data(for: "A") {
            XCTFail("Old A must not discard or overwrite the new A cache")
            return nil
        }
        XCTAssertEqual(cached, Data([3]))
    }

    private func spotifyInfo(rate: Double = 1) -> [String: Any] {
        ["source": "Spotify", "title": "Song", "artist": "Artist", "album": "Album", "playbackRate": rate]
    }

    private func artworkDescriptor(value: NSAppleEventDescriptor, afterTitle: String = "Song") -> NSAppleEventDescriptor {
        let descriptor = NSAppleEventDescriptor.list()
        let values = [
            NSAppleEventDescriptor(string: "Song"), NSAppleEventDescriptor(string: "Artist"),
            NSAppleEventDescriptor(string: "Album"), value, NSAppleEventDescriptor(string: afterTitle),
            NSAppleEventDescriptor(string: "Artist"), NSAppleEventDescriptor(string: "Album"),
        ]
        for (index, value) in values.enumerated() { descriptor.insert(value, at: index + 1) }
        return descriptor
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

    func testPausedTrackWinsOverStoppedPlayerInEitherSource() {
        for emptyTitle in ["", " \n\t "] {
            for pausedApp in [ScriptingBridgeHelper.SupportedApp.music, .spotify] {
                let paused: [String: Any] = [
                    "source": pausedApp.rawValue, "title": "Paused Track", "playbackRate": 0.0,
                ]
                let stopped: [String: Any] = [
                    "source": pausedApp == .music ? "Spotify" : "Music",
                    "title": emptyTitle, "playbackRate": 0.0,
                ]
                let selected = ScriptingBridgeHelper.selectNowPlayingInfo(
                    music: pausedApp == .music ? paused : stopped,
                    spotify: pausedApp == .spotify ? paused : stopped
                )

                XCTAssertEqual(selected["title"] as? String, "Paused Track")
                XCTAssertEqual(ScriptingBridgeHelper.supportedApp(from: selected), pausedApp)
            }
        }
    }

    func testSinglePausedOrStoppedSnapshotRemainsAvailable() {
        for app in [ScriptingBridgeHelper.SupportedApp.music, .spotify] {
            for title in ["Paused Track", ""] {
                let snapshot: [String: Any] = ["source": app.rawValue, "title": title, "playbackRate": 0.0]
                let selected = ScriptingBridgeHelper.selectNowPlayingInfo(
                    music: app == .music ? snapshot : nil,
                    spotify: app == .spotify ? snapshot : nil
                )

                XCTAssertEqual(selected["title"] as? String, title)
                XCTAssertEqual(ScriptingBridgeHelper.supportedApp(from: selected), app)
            }
        }
        XCTAssertTrue(ScriptingBridgeHelper.selectNowPlayingInfo(music: nil, spotify: nil).isEmpty)
    }

    func testPlayingMusicKeepsPriorityOverOtherPlayer() {
        let music: [String: Any] = ["source": "Music", "title": "Playing Music", "playbackRate": 1.0]
        for spotifyRate in [0.0, 1.0] {
            let spotify: [String: Any] = ["source": "Spotify", "title": "Spotify Track", "playbackRate": spotifyRate]
            let selected = ScriptingBridgeHelper.selectNowPlayingInfo(music: music, spotify: spotify)

            XCTAssertEqual(ScriptingBridgeHelper.supportedApp(from: selected), .music)
        }
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
