import XCTest
@testable import XNook

@MainActor
final class MediaLyricPositionTests: XCTestCase {
    func testPauseFreezesFreshExtrapolatedPositionBeforeStoppingClock() async throws {
        let fixture = LyricPositionFixture()
        try await fixture.load()
        fixture.date.addTimeInterval(1.5)
        fixture.media.pause()
        XCTAssertEqual(fixture.media.elapsedTime, 3.5, accuracy: 0.001)
        XCTAssertEqual(fixture.media.currentLyricLine, "Middle")
        XCTAssertFalse(fixture.media.isPlaying)
        XCTAssertEqual(fixture.commands, [.pause])
    }

    func testStaleIncomingPositionDoesNotReplaceLastCredibleLine() async throws {
        let fixture = LyricPositionFixture()
        try await fixture.load()
        fixture.position = 90
        fixture.sampledAt = fixture.date.addingTimeInterval(-10)
        await fixture.media.refreshNowPlayingInfo()
        XCTAssertEqual(fixture.media.elapsedTime, 2, accuracy: 0.001)
        XCTAssertEqual(fixture.media.currentLyricLine, "Early")
    }

    func testOffsetImmediatelyRefreshesFrozenPauseWithoutMovingPlayback() async throws {
        let fixture = LyricPositionFixture()
        try await fixture.load()
        fixture.date.addTimeInterval(1.5)
        fixture.media.pause()
        fixture.date.addTimeInterval(60)
        fixture.lyrics.lyricsOffset = 1
        XCTAssertEqual(fixture.media.currentLyricLine, "Early")
        XCTAssertEqual(fixture.media.elapsedTime, 3.5, accuracy: 0.001)
        XCTAssertEqual(fixture.commands, [.pause])
    }

    func testOffsetDoesNotRecomputeFromStalePlayingSampleAfterPause() async throws {
        let fixture = LyricPositionFixture()
        try await fixture.load()
        fixture.date.addTimeInterval(10)
        fixture.media.pause()
        fixture.lyrics.lyricsOffset = -5
        XCTAssertEqual(fixture.media.currentLyricLine, "Early")
        XCTAssertEqual(fixture.media.elapsedTime, 2)
    }

    func testConfirmedPausedPositionRemainsUsableAndAcceptsSeek() async throws {
        let fixture = LyricPositionFixture()
        fixture.rate = 0
        fixture.position = 4
        try await fixture.load()
        fixture.date.addTimeInterval(60)
        fixture.lyrics.lyricsOffset = 2
        XCTAssertEqual(fixture.media.currentLyricLine, "Early")
        XCTAssertEqual(fixture.media.elapsedTime, 4)
        fixture.position = 8
        await fixture.media.refreshNowPlayingInfo()
        XCTAssertEqual(fixture.media.currentLyricLine, "Late")
        XCTAssertEqual(fixture.media.elapsedTime, 8)
        XCTAssertTrue(fixture.commands.isEmpty)
    }

    func testResumeDoesNotCountPausedTimeBeforeNextPlayerSample() async throws {
        let fixture = LyricPositionFixture()
        try await fixture.load()
        fixture.date.addTimeInterval(1)
        fixture.media.pause()
        fixture.date.addTimeInterval(1)
        fixture.media.play()
        fixture.media.refreshLyricLine()
        XCTAssertEqual(fixture.media.elapsedTime, 3)
        fixture.position = 3.2
        await fixture.media.refreshNowPlayingInfo()
        XCTAssertEqual(fixture.media.elapsedTime, 3.2, accuracy: 0.001)
        XCTAssertEqual(fixture.commands, [.pause, .play])
    }

    func testResumeRejectsFreshButPreCommandSnapshot() async throws {
        let fixture = LyricPositionFixture()
        try await fixture.load()
        let oldSampleTime = fixture.date.addingTimeInterval(0.5)
        fixture.date.addTimeInterval(1)
        fixture.media.pause()
        fixture.date.addTimeInterval(1)
        fixture.media.play()
        fixture.position = 2.5
        fixture.sampledAt = oldSampleTime
        await fixture.media.refreshNowPlayingInfo()
        XCTAssertEqual(fixture.media.elapsedTime, 3, "恢复前的迟到样本不能把暂停时长计入进度")
        fixture.position = 3.2
        fixture.sampledAt = fixture.date
        await fixture.media.refreshNowPlayingInfo()
        XCTAssertEqual(fixture.media.elapsedTime, 3.2, accuracy: 0.001)
    }

    func testTogglePausesAtCurrentCrediblePosition() async throws {
        let fixture = LyricPositionFixture()
        try await fixture.load()
        fixture.date.addTimeInterval(1.5)
        fixture.media.togglePlayPause()
        XCTAssertEqual(fixture.media.elapsedTime, 3.5, accuracy: 0.001)
        XCTAssertFalse(fixture.media.isPlaying)
        fixture.date.addTimeInterval(60)
        fixture.media.togglePlayPause()
        fixture.media.refreshLyricLine()
        XCTAssertEqual(fixture.media.elapsedTime, 3.5, accuracy: 0.001)
        XCTAssertTrue(fixture.media.isPlaying)
        XCTAssertEqual(fixture.commands, [.togglePlayPause, .togglePlayPause])
    }

    func testPendingPauseIgnoresLatePlayingSnapshotUntilConfirmed() async throws {
        let fixture = LyricPositionFixture()
        try await fixture.load()
        fixture.date.addTimeInterval(1)
        fixture.media.pause()
        fixture.position = 50
        await fixture.media.refreshNowPlayingInfo()
        XCTAssertFalse(fixture.media.isPlaying)
        XCTAssertEqual(fixture.media.elapsedTime, 3)
        fixture.rate = 0
        fixture.position = 3.2
        await fixture.media.refreshNowPlayingInfo()
        XCTAssertEqual(fixture.media.elapsedTime, 3.2, accuracy: 0.001)
    }

    func testExternalPreferencesRefreshOffsetAndDisableWithoutWaitingForPoll() async throws {
        let fixture = LyricPositionFixture()
        try await fixture.load()
        fixture.date.addTimeInterval(1.5)
        fixture.media.refreshLyricLine()
        XCTAssertEqual(fixture.media.currentLyricLine, "Middle")
        fixture.defaults.set(1.0, forKey: "lyricsOffset")
        XCTAssertEqual(fixture.media.currentLyricLine, "Early")
        XCTAssertEqual(fixture.media.elapsedTime, 3.5, accuracy: 0.001)
        fixture.defaults.set(false, forKey: "showLyrics")
        XCTAssertEqual(fixture.lyrics.status, .disabled)
        XCTAssertEqual(fixture.media.currentLyricLine, "")
        fixture.defaults.set(true, forKey: "showLyrics")
        for _ in 0..<200 {
            if !fixture.lyrics.isFetching { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(fixture.lyrics.status, .synced)
        XCTAssertEqual(fixture.lyrics.lyricsOffset, 1)
        XCTAssertEqual(fixture.media.currentLyricLine, "Early")
        XCTAssertTrue(fixture.commands.isEmpty)
    }

    func testMissingPositionNeverCreatesSyncedLineThroughOffset() async throws {
        let fixture = LyricPositionFixture()
        fixture.position = nil
        try await fixture.load()
        fixture.lyrics.lyricsOffset = -5
        XCTAssertEqual(fixture.media.currentLyricLine, "")
        fixture.media.pause()
        fixture.lyrics.lyricsOffset = 5
        XCTAssertEqual(fixture.media.currentLyricLine, "")
    }
}

@MainActor
private final class LyricPositionFixture {
    let suite = "XNook.LyricPosition.\(UUID().uuidString)"
    let defaults: UserDefaults
    var date = Date(timeIntervalSince1970: 1000)
    var sampledAt: Date?
    var position: Double? = 2
    var rate = 1.0
    var title = "Song"
    var commands: [MediaRemoteCommand] = []
    static let lrc = "[00:00.00]Early\n[00:03.00]Middle\n[00:06.00]Late"

    lazy var lyrics = LyricsManager(defaults: defaults,
        loadRequest: { _ in throw URLError(.unsupportedURL) },
        readCache: { [weak self] _, _, _ in
            LyricsCache.Entry(type: .synced, payload: Self.lrc, fetchedAt: self?.date ?? .distantPast, key: "test")
        }, writeCache: { _, _, _, _, _, _ in }, now: { [weak self] in self?.date ?? .distantPast })

    lazy var media = MediaManager(startMonitoring: false, defaults: defaults, lyricsManager: lyrics,
        infoProvider: { [weak self] in
            guard let self else { return [:] }
            var info: [String: Any] = ["title": self.title, "artist": "Artist", "album": "Album",
                "source": "Music", "duration": 180.0, "playbackRate": self.rate,
                "positionTimestamp": self.sampledAt ?? self.date]
            if let position = self.position { info["playerPosition"] = position }
            return info
        }, artworkProvider: { _ in nil }, clock: { [weak self] in self?.date ?? .distantPast },
        commandSender: { [weak self] in self?.commands.append($0) })

    init() {
        defaults = UserDefaults(suiteName: suite)!
        SettingsDefaults.register(on: defaults)
    }

    func load() async throws {
        await media.refreshNowPlayingInfo()
        for _ in 0..<200 {
            if !lyrics.isFetching { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(lyrics.hasLyrics)
        media.refreshLyricLine()
    }

    deinit { defaults.removePersistentDomain(forName: suite) }
}
