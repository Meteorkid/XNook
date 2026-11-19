import AVFoundation
import Speech
import XCTest
@testable import XNook

/// 预转写的离线冒烟测试：解码 → 16k 单声道 WAV → 本地识别 → 带时间戳的文本。
///
/// 默认跳过。用一段已知的带语音文件验证整条链路：
/// `XNOOK_PRETRANSCRIPT_FILE=/tmp/pt.m4a swift test --filter PreTranscriptSmoke`
final class PreTranscriptSmokeTests: XCTestCase {

    func testExtractsChunkAndTranscribes() async throws {
        guard let path = ProcessInfo.processInfo.environment["XNOOK_PRETRANSCRIPT_FILE"] else {
            throw XCTSkip("设置 XNOOK_PRETRANSCRIPT_FILE 指向一个带语音的本地媒体文件")
        }
        let source = URL(fileURLWithPath: path)

        let chunk = try await MediaAudioChunkExtractor.extractWAV(from: source, start: 0, duration: 20)
        defer { try? FileManager.default.removeItem(at: chunk.url) }

        XCTAssertGreaterThan(chunk.duration, 5, "切出来的片段应当有实际音频")

        let transcribed = expectation(description: "transcribed")
        var segments: [SFTranscriptionSegment] = []
        var failure: Error?

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else {
            return XCTFail("识别器不可用")
        }
        let request = SFSpeechURLRecognitionRequest(url: chunk.url)
        request.shouldReportPartialResults = false
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        recognizer.recognitionTask(with: request) { result, error in
            if let error { failure = error; transcribed.fulfill(); return }
            guard let result, result.isFinal else { return }
            segments = result.bestTranscription.segments
            transcribed.fulfill()
        }

        await fulfillment(of: [transcribed], timeout: 60)
        if let failure { return XCTFail("转写失败：\(failure.localizedDescription)") }
        XCTAssertFalse(segments.isEmpty, "应当转出至少一个词")

        let offsets = segments.map(\.timestamp)
        XCTAssertEqual(offsets, offsets.sorted(), "时间戳必须单调递增")
        XCTAssertLessThan(offsets.first ?? 99, 3, "首词时间戳应接近片段开头")
    }

    /// 只编译不执行：既验证 AppleScript 语法，也不会触发任何授权弹窗。
    func testQuickTimeScriptCompiles() throws {
        guard let script = NSAppleScript(source: QuickTimeMediaLocator.script) else {
            return XCTFail("脚本无法构造")
        }
        var error: NSDictionary?
        XCTAssertTrue(script.compileAndReturnError(&error), "脚本语法错误：\(String(describing: error))")
    }
}
