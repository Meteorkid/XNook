import AVFoundation
import Foundation

/// 从本地媒体文件里切出一段音频，写成 16 kHz 单声道 WAV 供离线转写。
///
/// 为什么切段而不是整段转写：一段两小时的视频整段转写会占用大量内存与时间，
/// 而字幕只需要「播放前沿之后的一小段」。滚动切 30 秒既够领先，也能及时跟上拖动。
enum MediaAudioChunkExtractor {

    enum ExtractError: LocalizedError {
        case noAudioTrack
        case readerFailed(String)
        case empty

        var errorDescription: String? {
            switch self {
            case .noAudioTrack: "该文件没有可解码的音轨"
            case .readerFailed(let reason): "音频读取失败：\(reason)"
            case .empty: "该区间没有音频数据"
            }
        }
    }

    static let sampleRate: Double = 16_000

    /// 切出 `[start, start + duration)`。返回临时 WAV 路径与实际写入的时长。
    static func extractWAV(from url: URL, start: TimeInterval, duration: TimeInterval) async throws -> (url: URL, duration: TimeInterval) {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { throw ExtractError.noAudioTrack }

        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ExtractError.readerFailed("无法挂载音频输出") }
        reader.add(output)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: max(0, start), preferredTimescale: 600),
            duration: CMTime(seconds: max(0.5, duration), preferredTimescale: 600)
        )
        guard reader.startReading() else {
            throw ExtractError.readerFailed(reader.error?.localizedDescription ?? "startReading 失败")
        }

        var samples: [Int16] = []
        samples.reserveCapacity(Int(duration * sampleRate))
        while let sampleBuffer = output.copyNextSampleBuffer() {
            defer { CMSampleBufferInvalidate(sampleBuffer) }
            var bufferList = AudioBufferList()
            var blockBuffer: CMBlockBuffer?
            let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer,
                bufferListSizeNeededOut: nil,
                bufferListOut: &bufferList,
                bufferListSize: MemoryLayout<AudioBufferList>.size,
                blockBufferAllocator: nil,
                blockBufferMemoryAllocator: nil,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
            guard status == noErr, bufferList.mNumberBuffers >= 1 else { continue }
            let buffer = bufferList.mBuffers
            guard let data = buffer.mData else { continue }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size
            guard count > 0 else { continue }
            let pointer = data.assumingMemoryBound(to: Int16.self)
            samples.append(contentsOf: UnsafeBufferPointer(start: pointer, count: count))
        }

        guard reader.status != .failed else {
            throw ExtractError.readerFailed(reader.error?.localizedDescription ?? "读取中断")
        }
        guard !samples.isEmpty else { throw ExtractError.empty }

        let url = try writeWAV(samples: samples)
        let written = Double(samples.count) / sampleRate
        return (url, written)
    }

    /// 手写 44 字节 RIFF 头 + PCM。比走 `AVAudioFile` 少一层格式假设，失败面更小。
    private static func writeWAV(samples: [Int16]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("XNookPreTranscript", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("chunk-\(UUID().uuidString).wav")

        let byteRate = UInt32(sampleRate) * 2
        let dataBytes = UInt32(samples.count * MemoryLayout<Int16>.size)
        var data = Data(capacity: 44 + Int(dataBytes))

        func appendASCII(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func appendUInt32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func appendUInt16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        appendASCII("RIFF")
        appendUInt32(36 + dataBytes)
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendUInt32(16)
        appendUInt16(1)                 // PCM
        appendUInt16(1)                 // 单声道
        appendUInt32(UInt32(sampleRate))
        appendUInt32(byteRate)
        appendUInt16(2)                 // blockAlign
        appendUInt16(16)                // bitsPerSample
        appendASCII("data")
        appendUInt32(dataBytes)
        samples.withUnsafeBufferPointer { buffer in
            data.append(UnsafeBufferPointer(start: buffer.baseAddress, count: buffer.count))
        }

        try data.write(to: url, options: .atomic)
        return url
    }
}
