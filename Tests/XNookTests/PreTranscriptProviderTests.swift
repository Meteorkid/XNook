import AVFoundation
import XCTest
@testable import XNook

/// 用假播放器驱动预转写来源，验证编排：轮询 → 切段 → 识别 → 产出带时间戳的候选。
///
/// 默认跳过，需要一段带语音的本地文件：
/// `XNOOK_PRETRANSCRIPT_FILE=/tmp/pt.m4a swift test --filter PreTranscriptProvider`
@MainActor
final class PreTranscriptProviderTests: XCTestCase {

    @MainActor
    private final class StubLocator: LocalMediaLocator {
        let identifier = "stub"
        var playback: LocalMediaPlayback?
        func currentPlayback() async -> LocalMediaPlayback? { playback }
    }

    func testProducesCandidatesFromLocalFile() async throws {
        guard let path = ProcessInfo.processInfo.environment["XNOOK_PRETRANSCRIPT_FILE"] else {
            throw XCTSkip("设置 XNOOK_PRETRANSCRIPT_FILE 指向一个带语音的本地媒体文件")
        }
        let url = URL(fileURLWithPath: path)
        let locator = StubLocator()
        // 停在 0 秒：一块 30 秒的音频就覆盖整段，游标一次推到末尾，不会空转。
        locator.playback = LocalMediaPlayback(fileURL: url, position: 0, isPlaying: true)

        let provider = PreTranscriptProvider(
            locator: locator,
            generation: { 1 },
            locale: { Locale(identifier: "en-US") },
            sourceNow: { Date().timeIntervalSince1970 }
        )
        var received: [CaptionCandidate] = []
        provider.onCandidates = { received.append(contentsOf: $0) }

        provider.start()
        defer { provider.stop() }

        for _ in 0..<80 where received.isEmpty {
            // 轮询由调度周期驱动，测试里手动泵，等价于运行时的 60 ms 定时器。
            provider.pump()
            try await Task.sleep(for: .milliseconds(500))
        }

        XCTAssertFalse(received.isEmpty, "应当产出至少一条字幕候选")
        XCTAssertTrue(provider.isAvailable, "有产物后来源应变为可用")
        let starts = received.map(\.start)
        XCTAssertEqual(starts, starts.sorted(), "候选必须按时间递增")
        XCTAssertEqual(received.first?.level, .localCache, "等级应为本地已转写缓存")
        XCTAssertTrue(received.allSatisfy { !$0.text.isEmpty })
    }
}
