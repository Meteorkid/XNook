import XCTest
@testable import XNook

@MainActor
final class LyricsCandidatePolicyTests: XCTestCase {
    func testKnownMetadataMatrixKeepsSearchAndSharedEligibilityConsistent() {
        let cases: [(String, String, String, Double?, String, String, Double?, Bool)] = [
            ("普通同曲", "Paper Lantern", "Fixture Artist", 180, "Paper Lantern", "Fixture Artist", 180, true),
            ("不同标题", "Other Tune", "Fixture Artist", 180, "Paper Lantern", "Fixture Artist", 180, false),
            ("短标题不能包含", "光年", "Fixture Artist", 180, "光", "Fixture Artist", 180, false),
            ("歌手别称", "Paper Lantern", "Alias / Fixture Artist", 180, "Paper Lantern", "Fixture Artist", 180, true),
            ("相异歌手时长冲突", "Paper Lantern", "Other Artist", 300, "Paper Lantern", "Fixture Artist", 180, false),
            ("沿用翻唱回退", "Paper Lantern", "Other Artist", 184, "Paper Lantern", "Fixture Artist", 180, true),
            ("跨歌手缺时长", "Paper Lantern", "Other Artist", nil, "Paper Lantern", "Fixture Artist", 180, false),
            ("请求缺时长", "Paper Lantern", "Other Artist", 180, "Paper Lantern", "Fixture Artist", nil, false),
            ("同歌手缺时长", "Paper Lantern", "Fixture Artist", nil, "Paper Lantern", "Fixture Artist", nil, true),
            ("保留同歌手既有时长策略", "Paper Lantern", "Fixture Artist", 150, "Paper Lantern", "Fixture Artist", 180, true)
        ]
        for (name, candidateTitle, candidateArtist, candidateDuration, title, artist, duration, expected) in cases {
            let candidate = LrcResponse(trackName: candidateTitle, artistName: candidateArtist, duration: candidateDuration,
                syncedLyrics: "[00:01.00]Synthetic sample line", plainLyrics: nil)
            XCTAssertEqual(LyricsManager.isEligibleCandidate(candidate, title: title, artist: artist, duration: duration), expected, name)
            XCTAssertEqual(LyricsManager.bestSearchResult(from: [candidate], title: title, artist: artist, duration: duration) != nil, expected, name)
        }
    }

    func testEligibilityRejectsEmptyContentAndRetainsPlainFallback() {
        for (synced, plain, expected) in [(nil, nil, false), ("[ti:Fixture]", " \n\t ", false),
            ("[ti:Fixture]", "Synthetic plain line", true), ("[00:01]Synthetic line", nil, true)] as [(String?, String?, Bool)] {
            let candidate = LrcResponse(trackName: "Paper Lantern", artistName: "Fixture Artist", duration: nil,
                syncedLyrics: synced, plainLyrics: plain)
            XCTAssertEqual(LyricsManager.isEligibleCandidate(candidate, title: "Paper Lantern", artist: "Fixture Artist", duration: nil), expected)
        }
    }

    func testMissingExactMetadataDoesNotBecomeAFabricatedMismatch() {
        for (title, artist) in [(nil, nil), ("Paper Lantern", nil), (nil, "Fixture Artist")] as [(String?, String?)] {
            let candidate = LrcResponse(trackName: title, artistName: artist, duration: nil,
                syncedLyrics: "[00:01]Synthetic line", plainLyrics: nil)
            XCTAssertTrue(LyricsManager.isEligibleCandidate(candidate, title: "Paper Lantern", artist: "Fixture Artist", duration: 180))
        }
    }
}
