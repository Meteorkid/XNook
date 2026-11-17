import Foundation

/// 通过系统 `/usr/bin/perl` 桥接读写 macOS 系统播放中心。
///
/// 背景：本项目为 ad-hoc 签名，从其进程直接调用 MediaRemote 私有框架时，
/// 系统对读取接口返回空字典（写入命令仍可用）。`/usr/bin/perl` 带 Apple 平台签名，
/// 具备 MediaRemote 访问权。实测 ad-hoc 进程读到空、perl 能完整读到并控制播放。
///
/// 实现来自 BSD 3-Clause 开源项目 ejbills/mediaremote-adapter，
/// C 桥接源码见 Sources/CMediaRemote（含原始 LICENSE）。这里用一次性 `get` 命令
/// 读取（约 0.16s），避免常驻子进程管理复杂度。
enum PerlMediaRemote {
    typealias TrackPayload = PerlTrackPayload

    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: perlPath)
            && FileManager.default.fileExists(atPath: scriptPath)
            && FileManager.default.fileExists(atPath: dylibPath)
    }

    private static let perlPath = "/usr/bin/perl"

    private static var bundleResources: URL? {
        Bundle.main.url(forResource: "MediaRemoteBridge", withExtension: nil)
    }

    private static var scriptPath: String {
        bundleResources?.appendingPathComponent("run.pl").path ?? ""
    }

    private static var dylibPath: String {
        bundleResources?.appendingPathComponent("libCMediaRemote.dylib").path ?? ""
    }

    /// 读取当前播放信息。无播放时 payload 为 nil。
    static func get() async -> PerlTrackPayload? {
        guard isAvailable, let data = await run(["get"]) else { return nil }
        return decode(data)
    }

    /// 发送播放控制命令。
    @discardableResult
    static func send(_ command: Command) async -> Bool {
        guard isAvailable else { return false }
        return await run([command.rawValue]) != nil
    }

    enum Command: String {
        case play, pause, togglePlayPause = "toggle_play_pause"
        case nextTrack = "next_track", previousTrack = "previous_track"
        case stop, seek = "set_time"
    }

    // MARK: - 子进程

    /// 运行 perl 脚本并返回标准输出首行；失败或超时返回 nil。
    private static func run(_ arguments: [String]) async -> Data? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: perlPath)
            process.arguments = [scriptPath, dylibPath] + arguments

            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = Pipe()

            let lock = NSLock()
            var finished = false
            let finish: (Data?) -> Void = { result in
                lock.lock()
                guard !finished else { lock.unlock(); return }
                finished = true
                lock.unlock()
                continuation.resume(returning: result)
            }

            // get 约 0.16s；3s 未退出则强杀，避免异常时挂起。
            let killTask: DispatchWorkItem = DispatchWorkItem {
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: killTask)
            process.terminationHandler = { proc in
                killTask.cancel()
                guard proc.terminationStatus == 0 else { finish(nil); return }
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                finish(data.isEmpty ? nil : data)
            }

            do {
                try process.run()
            } catch {
                killTask.cancel()
                finish(nil)
            }
        }
    }

    // MARK: - 解析

    private struct Response: Decodable {
        let type: String?
        let payload: PerlTrackPayload?
    }

    private static func decode(_ data: Data) -> PerlTrackPayload? {
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              response.type == "data" else { return nil }
        // 无播放时 C 桥接输出 type=empty 或 payload 缺标题。
        guard let payload = response.payload, payload.hasTrack else { return nil }
        return payload
    }
}

/// 桥接返回的播放快照（微秒时间轴）。
struct PerlTrackPayload: Decodable {
    let title: String?
    let artist: String?
    let album: String?
    let isPlaying: Bool?
    let playbackRate: Double?
    let durationMicros: Double?
    let elapsedTimeMicros: Double?
    let timestampEpochMicros: Double?
    let applicationName: String?
    let bundleIdentifier: String?
    let artworkDataBase64: String?
    let PID: Int?

    var hasTrack: Bool {
        guard let title, !title.isEmpty else { return false }
        return true
    }

    var artworkData: Data? {
        guard let base64 = artworkDataBase64 else { return nil }
        return Data(base64Encoded: base64)
    }

    /// 按采样时间戳补偿后的当前播放位置（秒）。
    func elapsedTime(at now: Date = Date()) -> TimeInterval? {
        guard let micros = elapsedTimeMicros else { return nil }
        let base = micros / 1_000_000
        guard isPlaying == true, let stamp = timestampEpochMicros else { return base }
        let age = now.timeIntervalSince1970 - stamp / 1_000_000
        return base + max(0, age) * (playbackRate ?? 1)
    }

    private enum CodingKeys: String, CodingKey {
        case title, artist, album, isPlaying, playbackRate
        case durationMicros, elapsedTimeMicros, timestampEpochMicros
        case applicationName, bundleIdentifier, artworkDataBase64, PID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        artist = try c.decodeIfPresent(String.self, forKey: .artist)
        album = try c.decodeIfPresent(String.self, forKey: .album)
        playbackRate = try c.decodeIfPresent(Double.self, forKey: .playbackRate)
        durationMicros = try c.decodeIfPresent(Double.self, forKey: .durationMicros)
        elapsedTimeMicros = try c.decodeIfPresent(Double.self, forKey: .elapsedTimeMicros)
        timestampEpochMicros = try c.decodeIfPresent(Double.self, forKey: .timestampEpochMicros)
        applicationName = try c.decodeIfPresent(String.self, forKey: .applicationName)
        bundleIdentifier = try c.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        artworkDataBase64 = try c.decodeIfPresent(String.self, forKey: .artworkDataBase64)
        // isPlaying 可能是 Bool 或 0/1
        if let bool = try? c.decode(Bool.self, forKey: .isPlaying) {
            isPlaying = bool
        } else if let int = try? c.decode(Int.self, forKey: .isPlaying) {
            isPlaying = int != 0
        } else {
            isPlaying = nil
        }
        // PID 可能是数字或字符串
        if let number = try? c.decode(Int.self, forKey: .PID) {
            PID = number
        } else if let string = try? c.decode(String.self, forKey: .PID) {
            PID = Int(string)
        } else {
            PID = nil
        }
    }
}
