import Foundation

/// 到期只生成短提示；不结束任务，也不以窗口是否可见改变计划时间。
@MainActor
final class FocusDeadlineMonitor {
    static let notifiedKey = "focusDeadlineNotifiedKeys"
    private let defaults: UserDefaults
    private let currentSession: () -> FocusSession?
    private let notificationsEnabled: () -> Bool
    private let emit: (PanelActivityEvent) -> Bool
    private let now: () -> Date
    private let schedule: PanelActivityCoordinator.Schedule
    private var notified: [String]
    private var scheduledKey: String?
    private var scheduledDeadline: Date?
    private var cancelScheduled: (() -> Void)?
    private var generation = 0
    private var isShutdown = false
    private var isDelivering = false

    init(
        defaults: UserDefaults = .standard,
        currentSession: @escaping () -> FocusSession?,
        notificationsEnabled: @escaping () -> Bool,
        emit: @escaping (PanelActivityEvent) -> Bool,
        now: @escaping () -> Date = Date.init,
        schedule: @escaping PanelActivityCoordinator.Schedule = { date, callback in
            let task = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow))) }
                catch { return }
                guard !Task.isCancelled else { return }
                callback()
            }
            return { task.cancel() }
        }
    ) {
        self.defaults = defaults
        self.currentSession = currentSession
        self.notificationsEnabled = notificationsEnabled
        self.emit = emit
        self.now = now
        self.schedule = schedule
        notified = Array((defaults.stringArray(forKey: Self.notifiedKey) ?? []).suffix(256))
    }

    func refresh() {
        guard !isShutdown, !isDelivering else { return }
        guard notificationsEnabled(), let session = currentSession(), session.state == .active,
              session.endedAt == nil, let deadline = session.scheduledEndAt,
              deadline.timeIntervalSince1970.isFinite else { suspend(); return }
        let time = now()
        guard time.timeIntervalSince1970.isFinite else { suspend(); return }
        let key = "\(session.id.uuidString)@\(deadline.timeIntervalSince1970)"
        guard !notified.contains(key) else { suspend(); return }
        if deadline <= time {
            suspend()
            isDelivering = true
            defer { isDelivering = false }
            let event = PanelActivityEvent(source: "focus-deadline", id: key,
                title: String(L10n.flowBudgetDue(session.title).prefix(160)), kind: .deadline, createdAt: time)
            if emit(event) {
                notified.append(key)
                notified = Array(notified.suffix(256))
                defaults.set(notified, forKey: Self.notifiedKey)
            }
            return
        }
        guard scheduledKey != key || scheduledDeadline != deadline || cancelScheduled == nil else { return }
        suspend()
        scheduledKey = key
        scheduledDeadline = deadline
        let expectedGeneration = generation
        // 兼容日历中的长任务，同时避免极远日期转换为 Duration 时溢出。
        let nextCheck = min(deadline, time.addingTimeInterval(86_400))
        cancelScheduled = schedule(nextCheck) { [weak self] in
            guard let self, self.generation == expectedGeneration, !self.isShutdown else { return }
            self.cancelScheduled = nil
            self.scheduledKey = nil
            self.scheduledDeadline = nil
            self.generation &+= 1
            self.refresh()
        }
    }

    func resynchronize() {
        suspend()
        refresh()
    }

    func suspend() {
        generation &+= 1
        cancelScheduled?()
        cancelScheduled = nil
        scheduledKey = nil
        scheduledDeadline = nil
    }

    func shutdown() {
        isShutdown = true
        suspend()
    }

    deinit { cancelScheduled?() }
}
