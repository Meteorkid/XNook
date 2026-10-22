import Foundation

/// 展开面板只保留一个等待任务；重复轮询不延长离开后的倒计时。
@MainActor
final class ExpandedAutoHideController {
    private var pendingTask: Task<Void, Never>?
    private var scheduledDelay: TimeInterval?
    private let sleep: @MainActor (Duration) async throws -> Void

    init(sleep: @escaping @MainActor (Duration) async throws -> Void = { duration in
        try await Task.sleep(for: duration)
    }) {
        self.sleep = sleep
    }

    func update(
        isExpanded: Bool,
        shouldDefer: Bool,
        delay: TimeInterval,
        onHide: @escaping @MainActor () -> Void
    ) {
        guard isExpanded, !shouldDefer, delay.isFinite, delay > 0 else {
            cancel()
            return
        }
        guard pendingTask == nil || scheduledDelay != delay else { return }

        cancel()
        scheduledDelay = delay
        let sleep = sleep
        pendingTask = Task { [weak self] in
            do {
                try await sleep(.seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.pendingTask = nil
            self.scheduledDelay = nil
            onHide()
        }
    }

    func cancel() {
        pendingTask?.cancel()
        pendingTask = nil
        scheduledDelay = nil
    }

    deinit {
        pendingTask?.cancel()
    }
}
