import Foundation
import QuartzCore

/// 绝对源时间轴。
///
/// 作用：把「宿主时钟」（音频帧到达捕获接口的时刻）映射为「音源自身的媒体时间」。
/// 说明书 3.2 F1 要求所有候选条目都带绝对源时间戳，且该时间戳「不随缓冲窗口或识别窗口的起点变化」，
/// 因此这里不做任何以当前窗口起点为原点的相对计时。
///
/// 三种同步来源按优先级：
/// 1. 播放器自报的播放位置（MediaManager / MediaRemote），带漂移过滤；
/// 2. 音源切换、seek 时以新锚点重建，并递增代次标识（旧代次的迟到结果直接丢弃）；
/// 3. 无播放位置的音源（系统提示音、非媒体播放、会议软件等）退化为「捕获起点为零点、速率 1」的单调时钟。
final class SourceClock: @unchecked Sendable {

    /// 重锚阈值：预测值与实测值之差超过此值即认为发生跳变（seek 或音源切换）。
    private let jumpThreshold: TimeInterval = 2.0
    /// 漂移修正阈值：超过此值但未达跳变阈值时，做平滑修正而不递增代次，避免播放器秒级取整造成抖动。
    private let driftThreshold: TimeInterval = 0.25

    private let lock = NSLock()
    private var hostAnchor: TimeInterval
    private var sourceAnchor: TimeInterval
    private var rate: Double = 1
    private var generationValue: Int = 1
    private var signature: String = ""

    init() {
        hostAnchor = CACurrentMediaTime()
        sourceAnchor = 0
    }

    /// 单调宿主时钟（秒）。与系统休眠无关，用于时间差计算。
    static func hostNow() -> TimeInterval {
        CACurrentMediaTime()
    }

    var generation: Int {
        lock.lock()
        defer { lock.unlock() }
        return generationValue
    }

    /// 把宿主时刻换算为绝对源时间。
    func sourceTime(atHost host: TimeInterval) -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return sourceAnchor + (host - hostAnchor) * rate
    }

    /// 当前绝对源时间。
    func sourceNow() -> TimeInterval {
        sourceTime(atHost: SourceClock.hostNow())
    }

    /// 把绝对源时间换算回宿主时刻。用于测量「这段音频说完 → 文字上屏」的真实延迟。
    func hostTime(atSource source: TimeInterval) -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        guard rate > 0 else { return hostAnchor + (source - sourceAnchor) }
        return hostAnchor + (source - sourceAnchor) / rate
    }

    /// 以播放器自报的位置对齐。返回是否判定为跳变（跳变时代次标识已递增）。
    @discardableResult
    func align(sourceTime observed: TimeInterval, rate newRate: Double, signature newSignature: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let host = CACurrentMediaTime()
        rate = (newRate.isFinite && newRate > 0) ? newRate : 1

        // 音源变化：无条件重锚并递增代次。
        if newSignature != signature {
            signature = newSignature
            hostAnchor = host
            sourceAnchor = observed
            generationValue &+= 1
            return true
        }

        let predicted = sourceAnchor + (host - hostAnchor) * rate
        let delta = observed - predicted

        if abs(delta) > jumpThreshold {
            hostAnchor = host
            sourceAnchor = observed
            generationValue &+= 1
            return true
        }

        if abs(delta) > driftThreshold {
            // 平滑修正：直接重锚会引入可见抖动，这里按 30% 收敛。
            sourceAnchor = predicted + delta * 0.3
            hostAnchor = host
        } else {
            // 微小误差：只修正锚点时间，不改基准位置。
            hostAnchor = host
            sourceAnchor = predicted
        }
        return false
    }

    /// 无播放位置时的零点重置（开始捕获、或捕获重启）。
    func resetToZero() {
        lock.lock()
        defer { lock.unlock() }
        hostAnchor = CACurrentMediaTime()
        sourceAnchor = 0
        rate = 1
        signature = ""
        generationValue &+= 1
    }

    /// 快照，供调度器在后台队列读取，避免与主线程竞争。
    func snapshot() -> (host: TimeInterval, source: TimeInterval, rate: Double, generation: Int) {
        lock.lock()
        defer { lock.unlock() }
        let host = CACurrentMediaTime()
        return (host, sourceAnchor + (host - hostAnchor) * rate, rate, generationValue)
    }
}
