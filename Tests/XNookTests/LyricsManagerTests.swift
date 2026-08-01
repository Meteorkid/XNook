import XCTest
@testable import XNook

@MainActor
final class LyricsManagerTests: XCTestCase {
    func testParseLrcSortsTimestampedLines() {
        let lines = LyricsManager.parseLrc(
            """
            [00:10.50]Second line
            [00:02.00]First line
            """
        )

        XCTAssertEqual(lines.map(\.text), ["First line", "Second line"])
        XCTAssertEqual(lines.map(\.time), [2.0, 10.5])
    }

    func testParseLrcExpandsMultipleTimestampsForOneLine() {
        let lines = LyricsManager.parseLrc("[00:12.00][00:30.50]Chorus")

        XCTAssertEqual(lines.map(\.time), [12.0, 30.5])
        XCTAssertEqual(lines.map(\.text), ["Chorus", "Chorus"])
    }

    func testParseLrcRejectsPlainLyricsWithoutTimestamps() {
        XCTAssertTrue(LyricsManager.parseLrc("Plain lyric without timing").isEmpty)
    }

    func testExactLookupRequiresAlbumAndDuration() {
        XCTAssertFalse(LyricsManager.shouldUseExactLookup(album: "", duration: 180))
        XCTAssertFalse(LyricsManager.shouldUseExactLookup(album: "Album", duration: nil))
        XCTAssertTrue(LyricsManager.shouldUseExactLookup(album: "Album", duration: 180))
    }

    func testSearchResultMatchesArtistAlias() throws {
        let candidates = [
            LrcResponse(
                trackName: "唯一",
                artistName: "其他歌手",
                duration: 254,
                syncedLyrics: "[00:01.00]Wrong",
                plainLyrics: nil
            ),
            LrcResponse(
                trackName: "唯一",
                artistName: "G.E.M. 邓紫棋",
                duration: 254,
                syncedLyrics: "[00:01.00]Correct",
                plainLyrics: nil
            ),
        ]

        let selected = try XCTUnwrap(
            LyricsManager.bestSearchResult(
                from: candidates,
                title: "唯一",
                artist: "邓紫棋",
                duration: 254
            )
        )

        XCTAssertEqual(selected.artistName, "G.E.M. 邓紫棋")
    }

    func testSearchResultPrefersSyncedLyricsOverCloserPlainLyrics() throws {
        let candidates = [
            LrcResponse(
                trackName: "Song",
                artistName: "Artist",
                duration: 180,
                syncedLyrics: nil,
                plainLyrics: "Plain"
            ),
            LrcResponse(
                trackName: "Song",
                artistName: "Artist",
                duration: 150,
                syncedLyrics: "[00:01.00]Synced",
                plainLyrics: "Synced"
            ),
        ]

        let selected = try XCTUnwrap(
            LyricsManager.bestSearchResult(
                from: candidates,
                title: "Song",
                artist: "Artist",
                duration: 180
            )
        )

        XCTAssertTrue(selected.hasSyncedLyrics)
    }

    // MARK: - 短歌名匹配（防回归）

    func testShortTitleExactMatchStillWorks() throws {
        // 单字歌名完全相等应能匹配
        let candidates = [
            LrcResponse(
                trackName: "光",
                artistName: "Artist",
                duration: 180,
                syncedLyrics: "[00:01.00]Correct",
                plainLyrics: nil
            ),
        ]

        let selected = try XCTUnwrap(
            LyricsManager.bestSearchResult(
                from: candidates,
                title: "光",
                artist: "Artist",
                duration: 180
            )
        )

        XCTAssertEqual(selected.trackName, "光")
    }

    func testShortTitleDoesNotMatchLongerCandidate() {
        // 短歌名"光"不应误匹配"光年"——避免 contains 方向导致的误匹配
        let candidates = [
            LrcResponse(
                trackName: "光年",
                artistName: "Artist",
                duration: 180,
                syncedLyrics: "[00:01.00]Wrong",
                plainLyrics: nil
            ),
        ]

        let selected = LyricsManager.bestSearchResult(
            from: candidates,
            title: "光",
            artist: "Artist",
            duration: 180
        )

        XCTAssertNil(selected)
    }

    // MARK: - hasLyrics / plainLyricPreview

    func testHasLyricsFalseByDefault() {
        let manager = LyricsManager()
        XCTAssertFalse(manager.hasLyrics)
        XCTAssertEqual(manager.plainLyricPreview, "")
    }

    func testPreviewLineReturnsEmptyForEmptyInput() {
        XCTAssertEqual(LyricsManager.previewLine(from: ""), "")
    }

    func testPreviewLineSkipsBlankAndMetadataLines() {
        let plain = """

        [ti:Song Title]
        [ar:Artist]

        First real line
        Second line
        """
        XCTAssertEqual(LyricsManager.previewLine(from: plain), "First real line")
    }

    func testPreviewLineTruncatesLongLines() {
        let longLine = String(repeating: "A", count: 120)
        let preview = LyricsManager.previewLine(from: longLine)
        XCTAssertEqual(preview.count, 81)  // 80 字符 + 省略号
        XCTAssertTrue(preview.hasSuffix("…"))
    }

    func testPreviewLineReturnsFirstNonEmptyLine() {
        let plain = "Only line\nSecond"
        XCTAssertEqual(LyricsManager.previewLine(from: plain), "Only line")
    }

    func testPreviewLineSkipsInstrumentalMarkers() {
        let plain = """
        Instrumental

        [music]

        First real line
        """
        XCTAssertEqual(LyricsManager.previewLine(from: plain), "First real line")
    }

    func testPreviewLineSkipsSoloMarker() {
        XCTAssertEqual(LyricsManager.previewLine(from: "Guitar Solo"), "")
    }

    func testPreviewLineReturnsEmptyForAllInstrumental() {
        XCTAssertEqual(LyricsManager.previewLine(from: "Instrumental"), "")
    }

    // MARK: - onLyricsStateChanged 回调

    func testLyricsStateChangedFiresOnReset() {
        let manager = LyricsManager()
        var callCount = 0
        manager.onLyricsStateChanged = { callCount += 1 }
        manager.reset()
        XCTAssertEqual(callCount, 1)
    }
}
