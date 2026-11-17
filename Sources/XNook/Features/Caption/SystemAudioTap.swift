import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

/// 系统音频捕获（屏幕捕获框架的纯音频模式）。
///
/// 为什么用它：本 App 没有麦克风通路，需要的是「任意应用正在播放的音频」。
/// ScreenCaptureKit 在 macOS 13+ 支持只订阅音频轨（capturesAudio），
/// 不订阅画面输出即可，代价是一次「屏幕与系统音频录制」授权。
///
/// 输出统一转换为 16 kHz 单声道 Float32 —— 这是流式语音识别的输入格式，
/// 也避免了识别引擎内部再次重采样带来的额外延迟。
final class SystemAudioTap: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {

    struct Config {
        var targetSampleRate: Double = 16_000
        var targetChannels: AVAudioChannelCount = 1
        /// 只请求音频，画面按 1 fps、2×2 像素请求，避免解码视频帧。
        var videoFrameInterval = CMTime(value: 1, timescale: 1)
    }

    enum TapError: LocalizedError {
        case noDisplay
        case permissionDenied
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .noDisplay:
                return L10n.localized(zh: "没有可用的显示器，无法订阅系统音频。",
                                      en: "No display available for system audio capture.")
            case .permissionDenied:
                return L10n.localized(zh: "未获得「屏幕与系统音频录制」权限，请在系统设置中允许 X Nook。",
                                      en: "Screen & System Audio Recording permission is required.")
            case .failed(let message):
                return message
            }
        }
    }

    /// 每帧音频回调：转换后的 PCM 缓冲 + 该帧到达捕获接口的宿主时刻（秒）。
    var onBuffer: ((AVAudioPCMBuffer, TimeInterval) -> Void)?
    var onError: ((Error) -> Void)?

    private let config: Config
    private let queue = DispatchQueue(label: "com.meteorkid.xnook.caption.audio", qos: .userInitiated)
    private var stream: SCStream?
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?
    private var isRunning = false

    init(config: Config = Config()) {
        self.config = config
        super.init()
    }

    // MARK: - 权限

    /// 探测是否已获得系统音频捕获权限。
    /// 未授权时该调用会触发系统弹窗；返回 false 表示用户拒绝或无法枚举。
    static func hasPermission() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            return true
        } catch {
            return false
        }
    }

    // MARK: - 启停

    func start() async throws {
        guard !isRunning else { return }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            if Self.isUserDeclined(error) { throw TapError.permissionDenied }
            throw TapError.failed(error.localizedDescription)
        }

        guard let display = content.displays.first else { throw TapError.noDisplay }

        // 排除本进程音频，避免把自身播放的声音再识别一遍形成回授。
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let streamConfig = SCStreamConfiguration()
        streamConfig.capturesAudio = true
        streamConfig.excludesCurrentProcessAudio = true
        streamConfig.sampleRate = 48_000
        streamConfig.channelCount = 2
        // 不消费画面：最小分辨率 + 低帧率。SCK 的配置项必须给值，但不会产生实际解码负载。
        streamConfig.width = 2
        streamConfig.height = 2
        streamConfig.minimumFrameInterval = config.videoFrameInterval
        streamConfig.showsCursor = false

        let newStream = SCStream(filter: filter, configuration: streamConfig, delegate: self)
        do {
            try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            try await newStream.startCapture()
        } catch {
            if Self.isUserDeclined(error) { throw TapError.permissionDenied }
            throw TapError.failed(error.localizedDescription)
        }

        stream = newStream
        isRunning = true
    }

    func stop() async {
        guard let stream, isRunning else { return }
        isRunning = false
        self.stream = nil
        converter = nil
        inputFormat = nil
        outputFormat = nil
        try? await stream.stopCapture()
    }

    private static func isUserDeclined(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == SCStreamErrorDomain && nsError.code == -3801
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        // t_audio：该帧到达音频捕获接口的时刻。说明书把首帧时限锚在这个量上，而不是锚在识别结果返回时刻。
        let arrivalHost = SourceClock.hostNow()

        guard
            let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
            let formatPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else { return }

        if inputFormat == nil {
            inputFormat = AVAudioFormat(streamDescription: formatPointer)
            outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: config.targetSampleRate,
                channels: config.targetChannels,
                interleaved: false
            )
            if let input = inputFormat, let output = outputFormat {
                converter = AVAudioConverter(from: input, to: output)
                // 低延迟优先：重采样质量对字幕文本几乎无影响，但直接影响端到端延迟。
                converter?.sampleRateConverterQuality = AVAudioQuality.low.rawValue
            }
        }

        guard let inputFormat, let outputFormat, let converter else { return }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return }

        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else { return }
        inputBuffer.frameLength = AVAudioFrameCount(frameCount)

        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: inputBuffer.mutableAudioBufferList
        )
        guard copyStatus == noErr else { return }

        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(frameCount) * ratio) + 64
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return
        }

        var supplied = false
        var conversionError: NSError?
        converter.convert(to: outputBuffer, error: &conversionError) { _, statusPointer in
            if supplied {
                statusPointer.pointee = .noDataNow
                return nil
            }
            supplied = true
            statusPointer.pointee = .haveData
            return inputBuffer
        }

        guard conversionError == nil, outputBuffer.frameLength > 0 else { return }
        onBuffer?(outputBuffer, arrivalHost)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        isRunning = false
        onError?(error)
    }
}
