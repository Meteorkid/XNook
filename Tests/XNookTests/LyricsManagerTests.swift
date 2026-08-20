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

    // MARK: - 核心歌名（去括号）匹配

    func testStrippedTitleRemovesBracketSuffix() {
        XCTAssertEqual(LyricsManager.strippedTitle("光亮 (大型纪录片《紫禁城》主题歌)"), "光亮")
        XCTAssertEqual(LyricsManager.strippedTitle("光亮（大型紀錄片《紫禁城》主題歌）"), "光亮")
        XCTAssertEqual(LyricsManager.strippedTitle("Shape of You [Remix]"), "Shape of You")
        XCTAssertEqual(LyricsManager.strippedTitle("大鱼"), "大鱼")
    }

    func testStrippedTitleKeepsWhollyBracketedTitle() {
        // 整个标题都在括号里时不能截成空串，否则查询无从发起
        XCTAssertEqual(LyricsManager.strippedTitle("(Reprise)"), "(Reprise)")
    }

    func testCoreTitleMatchesAcrossBracketAnnotations() throws {
        // 括号内的版本/来源标注两侧写法不同（简体 vs 繁体），
        // 第一轮严格匹配必然失败，应由第二轮的核心歌名匹配兜住
        let candidates = [
            LrcResponse(
                trackName: "光亮（大型紀錄片《紫禁城》主題歌）",
                artistName: "张杰",
                duration: 240,
                syncedLyrics: "[00:01.00]Correct",
                plainLyrics: nil
            ),
        ]

        let selected = try XCTUnwrap(
            LyricsManager.bestSearchResult(
                from: candidates,
                title: "光亮 (大型纪录片《紫禁城》主题歌)",
                artist: "张杰",
                duration: 240
            )
        )

        XCTAssertEqual(selected.syncedLyrics, "[00:01.00]Correct")
    }

    // MARK: - 翻唱兜底（第三轮）

    func testCoverFallbackMatchesDifferentArtistWhenDurationIsClose() throws {
        let candidates = [
            LrcResponse(
                trackName: "心墙",
                artistName: "郭静",
                duration: 254,
                syncedLyrics: "[00:01.00]Correct",
                plainLyrics: nil
            ),
        ]

        let selected = try XCTUnwrap(
            LyricsManager.bestSearchResult(
                from: candidates,
                title: "心墙",
                artist: "林俊杰",
                duration: 250
            )
        )

        XCTAssertEqual(selected.artistName, "郭静")
    }

    func testCoverFallbackRejectsSameTitleWhenDurationUnknown() {
        // duration 是第三轮唯一的安全阀。缺失时只剩歌名相等，
        // 会把 Adele 的 Hello 匹配成 Lionel Richie 的 Hello——整首歌词全错。
        let candidates = [
            LrcResponse(
                trackName: "Hello",
                artistName: "Lionel Richie",
                duration: nil,
                syncedLyrics: "[00:01.00]Wrong song",
                plainLyrics: nil
            ),
        ]

        let selected = LyricsManager.bestSearchResult(
            from: candidates,
            title: "Hello",
            artist: "Adele",
            duration: nil
        )

        XCTAssertNil(selected)
    }

    func testCoverFallbackRejectsCandidateWithoutDuration() {
        let candidates = [
            LrcResponse(
                trackName: "Hello",
                artistName: "Lionel Richie",
                duration: nil,
                syncedLyrics: "[00:01.00]Wrong song",
                plainLyrics: nil
            ),
        ]

        let selected = LyricsManager.bestSearchResult(
            from: candidates,
            title: "Hello",
            artist: "Adele",
            duration: 295
        )

        XCTAssertNil(selected, "候选没有时长就无法确认是同一首歌，不应接受跨歌手匹配")
    }

    func testCoverFallbackRejectsDistantDuration() {
        let candidates = [
            LrcResponse(
                trackName: "Hello",
                artistName: "Lionel Richie",
                duration: 250,
                syncedLyrics: "[00:01.00]Wrong song",
                plainLyrics: nil
            ),
        ]

        let selected = LyricsManager.bestSearchResult(
            from: candidates,
            title: "Hello",
            artist: "Adele",
            duration: 295
        )

        XCTAssertNil(selected, "时长相差超过容差应视为同名不同曲")
    }

    // MARK: - q= 兜底搜索

    func testFallbackSearchURLKeepsWordBoundaries() throws {
        let url = try XCTUnwrap(
            LyricsManager.fallbackSearchURL(title: "Shape of You (Remix)", artist: "Ed Sheeran")
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = try XCTUnwrap(components.queryItems?.first { $0.name == "q" }?.value)

        // q= 是分词全文检索，归一化成 "shapeofyou" 这种粘连串几乎不可能命中
        XCTAssertEqual(query, "Shape of You Ed Sheeran")
    }

    func testFallbackSearchURLOmitsEmptyArtist() throws {
        let url = try XCTUnwrap(
            LyricsManager.fallbackSearchURL(title: "大鱼", artist: "   ")
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = try XCTUnwrap(components.queryItems?.first { $0.name == "q" }?.value)

        XCTAssertEqual(query, "大鱼")
    }

    // MARK: - 重试判定

    func testOnlyTransientNetworkErrorsAreRetried() {
        XCTAssertTrue(LyricsManager.isRetryable(URLError(.timedOut)))
        XCTAssertTrue(LyricsManager.isRetryable(URLError(.networkConnectionLost)))
        XCTAssertTrue(LyricsManager.isRetryable(URLError(.notConnectedToInternet)))
        // 确定性失败重试也不会变好，只是白白多打一次请求
        XCTAssertFalse(LyricsManager.isRetryable(URLError(.badServerResponse)))
        XCTAssertFalse(LyricsManager.isRetryable(URLError(.unsupportedURL)))
        XCTAssertFalse(
            LyricsManager.isRetryable(
                DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad json"))
            )
        )
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

    func testPreviewLineSkipsInstrumentalBreakMarker() {
        XCTAssertEqual(LyricsManager.previewLine(from: "Instrumental Break\nReal line"), "Real line")
    }

    func testPreviewLineKeepsLyricContainingInstrumental() {
        // 整行不是间奏标记、只是正文里含该词，不应被当作占位符跳过
        let line = "The instrumental section moved me more than the words"
        XCTAssertEqual(LyricsManager.previewLine(from: line), line)
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
