import AVFoundation
import Foundation
import Speech
import XCTest
@testable import XNook

/// 分析器通路的冒烟测试：真的合成一段语音、真的喂进 `SpeechAnalyzerEvidenceProvider`，
/// 看它能不能吐出候选。
///
/// 默认跳过（需要语音模型资产、且依赖系统版本），用 `XNOOK_ANALYZER_SMOKE=1` 开启。
/// 它验证的是「接线」而不是「识别质量」：格式转换、`AnalyzerInput` 时间戳、结果循环、
/// 候选产出这几段一旦有一处写错，用户切到多语言并行后看到的就是「字幕没有反应」。
final class SpeechAnalyzerSmokeTests: XCTestCase {

    func testProviderEmitsCandidatesForSynthesizedSpeech() throws {
        guard ProcessInfo.processInfo.environment["XNOOK_ANALYZER_SMOKE"] == "1" else {
            throw XCTSkip("设置 XNOOK_ANALYZER_SMOKE=1 才运行（依赖语音模型资产）")
        }
        guard #available(macOS 26.0, *), SpeechTranscriber.isAvailable else {
            throw XCTSkip("SpeechTranscriber 在当前系统不可用")
        }

        let url = try synthesize("This is a test of the live caption engine.")
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let total = AVAudioFrameCount(file.length)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total)!
        try file.read(into: buffer)

        let clock = SourceClock()
        clock.resetToZero()

        let provider = SpeechAnalyzerEvidenceProvider(
            clock: clock,
            generation: { 1 },
            locales: [Locale(identifier: "en-US")]
        )
        let produced = expectation(description: "analyzer candidate")
        produced.assertForOverFulfill = false
        var texts: [String] = []

        provider.onCandidates = { candidates in
            let text = candidates.map(\.text).joined(separator: " ")
            texts.append(text)
            print("SMOKE candidate: \(text)")
            produced.fulfill()
        }
        provider.onDiagnostics = { print("SMOKE diag: \($0)") }
        provider.onFailure = { print("SMOKE failure: \($0.localizedDescription)") }

        provider.start()
        // 让 prepare() 先跑起来，否则前几帧会被丢掉。
        Thread.sleep(forTimeInterval: 3)

        // 按 0.5 秒一块喂，模拟实时流；一次性灌满会让分析器把整段当成一个超长片段。
        let chunk = AVAudioFrameCount(format.sampleRate / 2)
        var host = SourceClock.hostNow()
        var offset: AVAudioFramePosition = 0
        while offset < AVAudioFramePosition(buffer.frameLength) {
            let count = AVAudioFrameCount(min(AVAudioFramePosition(chunk), AVAudioFramePosition(buffer.frameLength) - offset))
            let slice = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
            slice.frameLength = count
            for channel in 0..<Int(format.channelCount) {
                memcpy(
                    slice.floatChannelData![channel],
                    buffer.floatChannelData![channel].advanced(by: Int(offset)),
                    Int(count) * MemoryLayout<Float>.size
                )
            }
            provider.append(buffer: slice, hostTime: host)
            host += Double(count) / format.sampleRate
            offset += AVAudioFramePosition(count)
            Thread.sleep(forTimeInterval: 0.05)
        }

        wait(for: [produced], timeout: 45)
        provider.stop()
        XCTAssertFalse(texts.isEmpty)
    }

    /// `say` 合成一段语音到临时文件。默认音色即可，这里只验证接线，不验证语种。
    private func synthesize(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("xnook-smoke-\(UUID().uuidString).aiff")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-o", url.path, text]
        try process.run()
        process.waitUntilExit()
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("say 没有产出音频")
        }
        return url
    }
}
