import Foundation

/// 展开面板只保留一个等待任务；重复轮询不延长离开后的倒计时。
///
/// 支持**悬停暂停**：鼠标移到面板上时挂起倒计时，并记住已消耗的时间；
/// 离开后按剩余时间重排，而不是把整个延迟重新计一遍。否则用户每次瞥一眼面板，
/// 倒计时都会重置，面板就再也不会自动收起。
///
/// 内部区分两个概念，否则轮询会把倒计时反复重置：
/// - `configuredDelay`：用户设置里的自动收起延迟，每轮轮询都会传进来
/// - `waitDuration`：本次实际睡眠的时长，暂停恢复后可能小于 configuredDelay
@MainActor
final class ExpandedAutoHideController {
    private var pendingTask: Task<Void, Never>?
    /// 用户设置的延迟；只要它不变，轮询就不会打断正在进行的等待
    private var configuredDelay: TimeInterval?
    /// 本次实际睡眠时长（恢复时可能只剩一部分）
    private var waitDuration: TimeInterval?
    /// 本次等待的起始时刻；用于暂停时结算已消耗时间
    private var startedAt: Date?
    /// 暂停时保留的剩余秒数
    private var remainingWhenPaused: TimeInterval?
    private let now: @MainActor () -> Date
    private let sleep: @MainActor (Duration) async throws -> Void

    init(
        now: @escaping @MainActor () -> Date = { Date() },
        sleep: @escaping @MainActor (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.now = now
        self.sleep = sleep
    }

    func update(
        isExpanded: Bool,
        shouldDefer: Bool,
        delay: TimeInterval,
        onHide: @escaping @MainActor () -> Void
    ) {
        guard isExpanded, delay.isFinite, delay > 0 else {
            cancel()
            return
        }

        // 悬停中：挂起倒计时并记账，等离开后再续上剩余时间。
        if shouldDefer {
            pause()
            return
        }

        // 正在等待中：只有用户设置真的变了才重排，否则保持原倒计时不被打断。
        // 注意比较的是 configuredDelay 而不是 waitDuration——恢复后的等待时长短于
        // 设置值，若拿设置值去比对，每轮轮询都会误判成"延迟变了"并重置为完整延迟。
        if pendingTask != nil {
            guard configuredDelay != delay else { return }
            cancel()
            schedule(wait: delay, configured: delay, onHide: onHide)
            return
        }

        // 从暂停恢复：设置没变就只等剩余时间；用户改过设置则用新值。
        if let remaining = remainingWhenPaused {
            let settingChanged = configuredDelay.map { $0 != delay } ?? false
            schedule(
                wait: settingChanged ? delay : remaining,
                configured: delay,
                onHide: onHide
            )
            return
        }

        schedule(wait: delay, configured: delay, onHide: onHide)
    }

    /// 挂起倒计时并记住剩余时间。未在等待时是 no-op。
    func pause() {
        guard pendingTask != nil else { return }
        let elapsed = startedAt.map { now().timeIntervalSince($0) } ?? 0
        let total = waitDuration ?? 0
        let remaining = max(0, total - max(0, elapsed))
        // configuredDelay 保留不动：它代表用户设置，恢复时用来判断设置是否被改过。
        pendingTask?.cancel()
        pendingTask = nil
        waitDuration = nil
        startedAt = nil
        remainingWhenPaused = remaining
    }

    func cancel() {
        pendingTask?.cancel()
        pendingTask = nil
        configuredDelay = nil
        waitDuration = nil
        startedAt = nil
        remainingWhenPaused = nil
    }

    /// - Parameters:
    ///   - wait: 本次实际睡眠时长，暂停恢复后可能小于 configured
    ///   - configured: 用户设置的延迟，轮询用它判断是否需要重排
    private func schedule(
        wait: TimeInterval,
        configured: TimeInterval,
        onHide: @escaping @MainActor () -> Void
    ) {
        configuredDelay = configured
        waitDuration = wait
        startedAt = now()
        remainingWhenPaused = nil
        let sleep = sleep
        pendingTask = Task { [weak self] in
            do {
                try await sleep(.seconds(wait))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.pendingTask = nil
            self.configuredDelay = nil
            self.waitDuration = nil
            self.startedAt = nil
            onHide()
        }
    }

    deinit {
        pendingTask?.cancel()
    }
}
