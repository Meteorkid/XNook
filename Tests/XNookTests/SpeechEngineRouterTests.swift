import AVFoundation
import XCTest
@testable import XNook

/// 语音引擎的换路规则。
///
/// 这些用例存在的理由：多语言分析器失败发生在 `prepare()` 阶段，那时字幕链路已经装配完、
/// 音频也在流。若换路不生效，用户看到的是「字幕坏了」，而不是「换了一条更慢但能用的路」。
final class SpeechEngineRouterTests: XCTestCase {

    /// 可编排的假来源：想让它什么时候失败，就在闭包里抛。
    private final class FakeProvider: SpeechEvidenceProviding {
        let providerID: String
        let level: EvidenceLevel = .streaming
        let prefetchRequired = false
        let allowsAsync = true
        let isSlow = false
        var weight: Double = 0.45
        let estimatedLatency: TimeInterval = 0.35
        let timeoutAction: CaptionTimeoutAction = .fallbackStreaming

        var onCandidates: (([CaptionCandidate]) -> Void)?
        var onCoverageChange: (() -> Void)?
        var onFailure: ((Error) -> Void)?
        var onDiagnostics: ((String) -> Void)?

        var startCount = 0
        var stopCount = 0
        var appendedFrames: AVAudioFramePosition = 0
        var startHook: ((FakeProvider) -> Void)?

        init(id: String) {
            providerID = id
        }

        func start() {
            startCount += 1
            startHook?(self)
        }

        func stop() { stopCount += 1 }

        func updateContentHint(_ text: String) {}

        func append(buffer: AVAudioPCMBuffer, hostTime: TimeInterval) {
            appendedFrames += AVAudioFramePosition(buffer.frameLength)
        }
    }

    private struct SampleError: LocalizedError {
        var errorDescription: String? { "analyzer unavailable" }
    }

    private func makeBuffer(seconds: Double = 1, sampleRate: Double = 48_000) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        return buffer
    }

    private func makeRouter(
        primary: FakeProvider,
        fallback: FakeProvider
    ) -> SpeechEngineRouter {
        let router = SpeechEngineRouter(
            clock: SourceClock(),
            generation: { 1 },
            locales: [Locale(identifier: "zh-CN")],
            primary: primary,
            fallbackFactory: { _, _ in fallback }
        )
        return router
    }

    func testPrimaryFailureSwapsToFallbackAndKeepsRunning() {
        let primary = FakeProvider(id: "speech.analyzer")
        let fallback = FakeProvider(id: "speech.streaming")
        let router = makeRouter(primary: primary, fallback: fallback)

        var note: String?
        var forwarded: [CaptionCandidate] = []
        router.onEngineChanged = { note = $0 }
        router.onCandidates = { forwarded.append(contentsOf: $0) }

        primary.startHook = { provider in provider.onFailure?(SampleError()) }
        router.start()

        XCTAssertEqual(primary.startCount, 1)
        XCTAssertEqual(primary.stopCount, 1, "失败的那一路必须停掉")
        XCTAssertEqual(fallback.startCount, 1, "换路后要立刻接管")
        XCTAssertNotNil(note, "换路必须告诉上层，否则用户以为在测新引擎")

        // 换路后音频应送进新引擎，候选也应原样转发。
        router.append(buffer: makeBuffer(), hostTime: 0)
        XCTAssertEqual(fallback.appendedFrames, 48_000)
        XCTAssertEqual(primary.appendedFrames, 0)

        let candidate = CaptionCandidate(
            providerID: "speech.streaming",
            level: .streaming,
            weight: 0.45,
            start: 0,
            end: 1,
            text: "你好",
            generation: 1,
            pipelineKey: "speech.v1"
        )
        fallback.onCandidates?([candidate])
        XCTAssertEqual(forwarded.count, 1)
    }

    func testFallbackIsNotRepeatedForLateAnalyzerFailures() {
        let primary = FakeProvider(id: "speech.analyzer")
        let fallback = FakeProvider(id: "speech.streaming")
        let router = makeRouter(primary: primary, fallback: fallback)

        var reported: [Error] = []
        router.onFailure = { reported.append($0) }

        primary.startHook = { provider in provider.onFailure?(SampleError()) }
        router.start()
        // 分析器已经停掉，之后再冒出来的失败不应再触发一次换路，也不该被当成整体失败。
        primary.onFailure?(SampleError())

        XCTAssertEqual(fallback.startCount, 1)
        XCTAssertTrue(reported.isEmpty)
    }

    func testStableEngineFailureIsReportedUpward() {
        let primary = FakeProvider(id: "speech.analyzer")
        let fallback = FakeProvider(id: "speech.streaming")
        let router = makeRouter(primary: primary, fallback: fallback)

        var reported: [Error] = []
        router.onFailure = { reported.append($0) }

        primary.startHook = { provider in provider.onFailure?(SampleError()) }
        router.start()
        fallback.onFailure?(SampleError())

        XCTAssertEqual(reported.count, 1, "稳定引擎自己失败就是真失败，不能再换路")
    }

    func testSilentAnalyzerSwitchesAfterIdleTimeout() {
        let primary = FakeProvider(id: "speech.analyzer")
        let fallback = FakeProvider(id: "speech.streaming")
        let router = makeRouter(primary: primary, fallback: fallback)
        var note: String?
        router.onEngineChanged = { note = $0 }

        router.start()
        // 只喂 10 秒：还没到阈值，不该换路。
        for _ in 0..<10 { router.append(buffer: makeBuffer(), hostTime: 0) }
        XCTAssertEqual(fallback.startCount, 0)

        // 累计过 45 秒仍无任何候选 —— 分析器起来了但哑了，必须换路。
        for _ in 0..<40 { router.append(buffer: makeBuffer(), hostTime: 0) }
        XCTAssertEqual(fallback.startCount, 1)
        XCTAssertNotNil(note)
    }

    func testAnalyzerProducingCandidatesNeverTimesOut() {
        let primary = FakeProvider(id: "speech.analyzer")
        let fallback = FakeProvider(id: "speech.streaming")
        let router = makeRouter(primary: primary, fallback: fallback)

        router.start()
        let candidate = CaptionCandidate(
            providerID: "speech.analyzer",
            level: .streaming,
            weight: 0.45,
            start: 0,
            end: 1,
            text: "hello",
            generation: 1,
            pipelineKey: "speech.analyzer.v1"
        )
        primary.onCandidates?([candidate])

        for _ in 0..<60 { router.append(buffer: makeBuffer(), hostTime: 0) }
        XCTAssertEqual(fallback.startCount, 0, "有产出就不该按超时处理")
    }
}
