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
}
