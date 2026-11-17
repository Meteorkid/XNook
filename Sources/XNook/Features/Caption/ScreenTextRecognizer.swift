import CoreGraphics
import Foundation
import ScreenCaptureKit
import Vision

/// 屏幕文字识别：按需截一帧 → 只认底部字幕带 → 返回一行文本。
///
/// 为什么用「按需截图」而不是持续视频流：
/// 这个来源的定位是**按区间执行、可被跳过**的低等级证据。
/// 持续视频流会让「跳过」失去意义（流已经在解码了），
/// 而 `SCScreenshotManager` 只在真正需要时才付出一次捕获 + 一次 OCR 的代价，
/// 于是「证书成立 → 不算了」能省下可计量的算力。
enum ScreenTextRecognizer {

    enum Failure: LocalizedError {
        case noDisplay
        case captureFailed(String)

        var errorDescription: String? {
            switch self {
            case .noDisplay:
                return L10n.localized(zh: "没有可用于画面识别的显示器。",
                                      en: "No display available for frame text recognition.")
            case .captureFailed(let message):
                return message
            }
        }
    }

    /// 字幕通常落在画面底部这一带。取 30% 高度：既能覆盖双行字幕，又避开大部分画面主体。
    static let bottomBandRatio: CGFloat = 0.30
    /// 截图宽度。1280 足够让 24px 左右的字幕被稳定识别，又不至于让 OCR 变慢。
    static let captureWidth: CGFloat = 1280

    /// 抓取主显示器的一帧并识别底部字幕带。
    static func recognizeSubtitle() async throws -> String? {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw Failure.captureFailed(error.localizedDescription)
        }

        let mainID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first else {
            throw Failure.noDisplay
        }

        // 排除本进程：否则灵动岛自己和设置窗口会被当成画面文字读进来。
        let ownApps = content.applications.filter {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])

        let config = SCStreamConfiguration()
        let aspect = CGFloat(display.height) / max(1, CGFloat(display.width))
        config.width = Int(captureWidth)
        config.height = Int(captureWidth * aspect)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            throw Failure.captureFailed(error.localizedDescription)
        }

        guard let band = cropBottomBand(image) else { return nil }
        // Vision 的 perform 是同步 CPU 密集调用，必须离开主线程；
        // 这条路径每次执行都会阻塞几十到上百毫秒，也正是它值得被「短路」的原因。
        return await Task.detached(priority: .userInitiated) {
            recognize(in: band)
        }.value
    }

    /// 只保留底部字幕带。整帧 OCR 会把菜单栏、工具栏、弹幕全读进来。
    static func cropBottomBand(_ image: CGImage) -> CGImage? {
        let height = CGFloat(image.height)
        let bandHeight = max(1, (height * bottomBandRatio).rounded())
        let rect = CGRect(x: 0, y: 0, width: CGFloat(image.width), height: bandHeight)
        return image.cropping(to: rect)
    }

    /// 同步 OCR。调用方保证在专用队列上执行。
    static func recognize(in image: CGImage) -> String? {
        let request = VNRecognizeTextRequest()
        // 字幕是短句，语言纠错会把专有名词改坏；精度优先，速度靠缩小识别区域换。
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["zh-Hans", "en-US"]

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let observations = request.results, !observations.isEmpty else { return nil }
        return mergeObservations(observations)
    }

    /// 同一行字幕可能被切成多个 observation，按纵向位置归并后再拼接。
    static func mergeObservations(_ observations: [VNRecognizedTextObservation]) -> String? {
        let accepted: [(text: String, box: CGRect)] = observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            guard candidate.confidence >= 0.35 else { return nil }
            let text = sanitize(candidate.string)
            guard let text else { return nil }
            return (text, observation.boundingBox)
        }
        guard !accepted.isEmpty else { return nil }

        // 按纵向位置从上到下排（Vision 的 y 轴原点在左下，越大越靠上）。
        let ordered = accepted.sorted { $0.box.midY > $1.box.midY }
        // 只取最靠下的那一到两行：字幕不会同时出现四五行。
        let bottom = ordered.prefix(2)
        let merged = bottom.map(\.text).joined(separator: " ")
        return sanitize(merged)
    }

    /// 文本清洗：去空、去纯符号、限制长度。
    /// 公开出来是为了单测——这些规则决定了 OCR 会不会用垃圾覆盖准确的字幕。
    static func sanitize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{FFFD}", with: "")
        guard trimmed.count >= 2, trimmed.count <= 60 else { return nil }

        // 至少要有两个「实义字符」（字母、数字或汉字），否则是分隔线、时间码之类的噪声。
        let meaningful = trimmed.unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || (0x4E00...0x9FFF).contains(scalar.value)
        }
        guard meaningful.count >= 2 else { return nil }

        // 纯数字/时间码不是字幕。
        let digits = trimmed.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }
        if digits.count >= trimmed.unicodeScalars.count / 2 + 1 { return nil }

        return trimmed
    }
}
