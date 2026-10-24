import Foundation
import Observation

/// 装饰动画与交互轮询的共同门控，不改变媒体和歌词时钟。
@Observable @MainActor
final class PanelActivityState {
    private(set) var isWindowVisible = false
    private(set) var isSystemAwake = true

    var isActive: Bool { isWindowVisible && isSystemAwake }

    func setWindowVisible(_ isVisible: Bool) {
        isWindowVisible = isVisible
    }

    func setSystemAwake(_ isAwake: Bool) {
        isSystemAwake = isAwake
    }
}

/// 只负责窗口的跨屏鼠标轮询；允许不用 WindowServer 重放隐藏与恢复。
@MainActor
final class PanelMouseTrackingController {
    typealias Schedule = (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void

    private let schedule: Schedule
    private let onTick: @MainActor () -> Void
    private var cancel: (() -> Void)?
    private var generation = 0
    private var isActive = false

    init(
        schedule: @escaping Schedule = { interval, callback in
            let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
                Task { @MainActor in callback() }
            }
            return { timer.invalidate() }
        },
        onTick: @escaping @MainActor () -> Void
    ) {
        self.schedule = schedule
        self.onTick = onTick
    }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        generation += 1
        cancel?()
        cancel = nil
        guard active else { return }
        let expectedGeneration = generation
        cancel = schedule(0.5) { [weak self] in
            guard let self, self.isActive, self.generation == expectedGeneration else { return }
            self.onTick()
        }
    }

    deinit { cancel?() }
}
