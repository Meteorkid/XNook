import Foundation
import Observation

struct PanelActivityEvent: Equatable, Identifiable {
    enum Kind: Int, Equatable {
        case information = 0
        case completion = 1
        case deadline = 2
        case failure = 3
    }

    enum Action: Equatable {
        case none
        case openCalendar
    }

    let source: String
    let id: String
    let title: String
    let kind: Kind
    let createdAt: Date
    let expiresAt: Date
    let action: Action

    init(
        source: String, id: String, title: String, kind: Kind,
        createdAt: Date = Date(), expiresAt: Date? = nil, action: Action = .none
    ) {
        self.source = source
        self.id = id
        self.title = title
        self.kind = kind
        self.createdAt = createdAt
        self.expiresAt = expiresAt ?? createdAt.addingTimeInterval(60)
        self.action = action
    }

    fileprivate func validated(at now: Date) -> PanelActivityEvent? {
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, source.count <= 64,
              !id.isEmpty, id.count <= 128,
              !title.isEmpty, title.count <= 160,
              now.timeIntervalSince1970.isFinite,
              createdAt.timeIntervalSince1970.isFinite,
              expiresAt.timeIntervalSince1970.isFinite,
              createdAt <= now.addingTimeInterval(5),
              expiresAt > createdAt, expiresAt > now,
              expiresAt <= createdAt.addingTimeInterval(60) else { return nil }
        return PanelActivityEvent(
            source: source, id: id, title: title, kind: kind,
            createdAt: createdAt, expiresAt: expiresAt, action: action
        )
    }
}

/// 仅调度短提示；窗口是否能展示和用户动作由宿主决定。
@Observable @MainActor
final class PanelActivityCoordinator {
    typealias Schedule = (Date, @escaping @MainActor () -> Void) -> () -> Void

    private(set) var current: PanelActivityEvent?
    private(set) var pendingCount = 0
    private(set) var isEnabled = true

    private struct EventKey: Hashable {
        let source: String
        let id: String

        init(_ event: PanelActivityEvent) {
            source = event.source
            id = event.id
        }
    }

    private struct Entry {
        let event: PanelActivityEvent
        let order: UInt64
        var remainingPresentation: TimeInterval = 5
        var wasPresented = false
    }

    private struct SeenEntry {
        let expiresAt: Date
        let order: UInt64
    }

    private let now: () -> Date
    private let schedule: Schedule
    private let onPresent: (@MainActor (PanelActivityEvent) -> Void)?
    private let onAction: (@MainActor (PanelActivityEvent.Action) -> Void)?
    private var isPresentationAllowed: @MainActor () -> Bool
    private var active: Entry?
    private var activeSince: Date?
    private var pending: [Entry] = []
    private var seen: [EventKey: SeenEntry] = [:]
    private var nextOrder: UInt64 = 0
    @ObservationIgnored private var cancelScheduled: (() -> Void)?
    private var scheduledDeadline: Date?
    private var generation: UInt64 = 0
    private var isShutdown = false

    init(
        now: @escaping () -> Date = Date.init,
        schedule: @escaping Schedule = { date, callback in
            let task = Task { @MainActor in
                do {
                    try await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow)))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                callback()
            }
            return { task.cancel() }
        },
        isPresentationAllowed: @escaping @MainActor () -> Bool = { false },
        onPresent: (@MainActor (PanelActivityEvent) -> Void)? = nil,
        onAction: (@MainActor (PanelActivityEvent.Action) -> Void)? = nil
    ) {
        self.now = now
        self.schedule = schedule
        self.isPresentationAllowed = isPresentationAllowed
        self.onPresent = onPresent
        self.onAction = onAction
    }

    func configurePresentation(_ isAllowed: @escaping @MainActor () -> Bool) {
        isPresentationAllowed = isAllowed
        refreshPresentation()
    }

    @discardableResult
    func enqueue(_ event: PanelActivityEvent) -> Bool {
        guard isEnabled, !isShutdown else { return false }
        let time = now()
        seen = seen.filter { $0.value.expiresAt > time }
        guard let event = event.validated(at: time) else {
            refreshPresentation(at: time)
            return false
        }
        let key = EventKey(event)
        guard seen[key] == nil,
              active.map({ $0.event.expiresAt <= time || EventKey($0.event) != key }) ?? true,
              !pending.contains(where: { $0.event.expiresAt > time && EventKey($0.event) == key }) else {
            refreshPresentation(at: time)
            return false
        }
        let order = nextOrder
        nextOrder &+= 1
        seen[key] = SeenEntry(expiresAt: event.expiresAt, order: order)
        if seen.count > 256, let oldest = seen.min(by: { $0.value.order < $1.value.order })?.key {
            seen.removeValue(forKey: oldest)
        }
        pending.append(Entry(event: event, order: order))
        refreshPresentation(at: time)
        return true
    }

    func refreshPresentation() {
        refreshPresentation(at: now())
    }

    func setEnabled(_ enabled: Bool) {
        guard !isShutdown, enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            refreshPresentation()
        } else {
            clear()
        }
    }

    func dismissCurrent(_ event: PanelActivityEvent) {
        refreshPresentation()
        guard current == event else { return }
        active = nil
        activeSince = nil
        refreshPresentation()
    }

    func performCurrentAction(_ event: PanelActivityEvent) {
        refreshPresentation()
        guard current == event, event.action != .none else { return }
        dismissCurrent(event)
        onAction?(event.action)
    }

    func shutdown() {
        isShutdown = true
        isEnabled = false
        clear()
    }

    private func refreshPresentation(at time: Date) {
        guard isEnabled, !isShutdown else { return }
        let allowed = isPresentationAllowed()
        seen = seen.filter { $0.value.expiresAt > time }
        pending.removeAll { $0.event.expiresAt <= time }
        if var entry = active, let startedAt = activeSince {
            let elapsed = max(0, time.timeIntervalSince(startedAt))
            if entry.event.expiresAt <= time || elapsed >= entry.remainingPresentation {
                active = nil
                activeSince = nil
            } else if !allowed {
                entry.remainingPresentation -= elapsed
                pending.append(entry)
                active = nil
                activeSince = nil
            }
        }

        var firstPresentation: PanelActivityEvent?
        if allowed, active == nil, let index = pending.indices.min(by: { precedes(pending[$0], pending[$1]) }) {
            var entry = pending.remove(at: index)
            if !entry.wasPresented {
                entry.wasPresented = true
                firstPresentation = entry.event
            }
            active = entry
            activeSince = time
        }
        while pending.count > 5 {
            let index = pending.indices.min { left, right in
                let lhs = pending[left]
                let rhs = pending[right]
                if lhs.event.kind != rhs.event.kind { return lhs.event.kind.rawValue < rhs.event.kind.rawValue }
                return lhs.order < rhs.order
            }!
            pending.remove(at: index)
        }
        current = active?.event
        pendingCount = pending.count
        scheduleNext(at: time)
        // 先完成状态与定时器更新，允许宿主回调安全地关闭或继续入队。
        if let firstPresentation { onPresent?(firstPresentation) }
    }

    private func precedes(_ lhs: Entry, _ rhs: Entry) -> Bool {
        if lhs.event.kind != rhs.event.kind { return lhs.event.kind.rawValue > rhs.event.kind.rawValue }
        return lhs.order < rhs.order
    }

    private func scheduleNext(at time: Date) {
        var dates = pending.map(\.event.expiresAt)
        if let active, let activeSince {
            dates.append(active.event.expiresAt)
            dates.append(activeSince.addingTimeInterval(active.remainingPresentation))
        }
        let nextDate = dates.min().map { max(time, $0) }
        guard nextDate != scheduledDeadline else { return }
        cancelTimer()
        guard let nextDate else { return }
        let expectedGeneration = generation
        scheduledDeadline = nextDate
        cancelScheduled = schedule(nextDate) { [weak self] in
            guard let self, self.generation == expectedGeneration, self.isEnabled, !self.isShutdown else { return }
            self.cancelScheduled = nil
            self.scheduledDeadline = nil
            self.generation &+= 1
            self.refreshPresentation()
        }
    }

    private func cancelTimer() {
        generation &+= 1
        cancelScheduled?()
        cancelScheduled = nil
        scheduledDeadline = nil
    }

    private func clear() {
        cancelTimer()
        active = nil
        activeSince = nil
        current = nil
        pending.removeAll()
        pendingCount = 0
        seen.removeAll()
    }

    deinit { cancelScheduled?() }
}

/// 纯数据边界：来源白名单不代表调用者认证，外部输入无法提供动作。
enum PanelActivityEnvelope {
    enum DecodeError: Error, Equatable {
        case tooLarge
        case invalidEnvelope
    }

    static func decode(_ data: Data, allowedSources: Set<String>, now: Date) throws -> PanelActivityEvent {
        guard data.count <= 64 * 1_024 else { throw DecodeError.tooLarge }
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw DecodeError.invalidEnvelope
        }
        let source = payload.source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard payload.version == 1, allowedSources.contains(source),
              payload.result == "success" || payload.result == "failure" else {
            throw DecodeError.invalidEnvelope
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = payload.createdAt.trimmingCharacters(in: .whitespacesAndNewlines)
        var createdAt = formatter.date(from: timestamp)
        if createdAt == nil {
            formatter.formatOptions = [.withInternetDateTime]
            createdAt = formatter.date(from: timestamp)
        }
        guard let createdAt,
              let event = PanelActivityEvent(
                source: source, id: payload.id, title: payload.title,
                kind: payload.result == "success" ? .completion : .failure,
                createdAt: createdAt
              ).validated(at: now) else { throw DecodeError.invalidEnvelope }
        return event
    }

    private struct Payload: Decodable {
        let version: Int
        let source: String
        let id: String
        let title: String
        let result: String
        let createdAt: String

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case version, source, id, title, result, createdAt
        }

        private struct AnyKey: CodingKey {
            let stringValue: String
            var intValue: Int? { nil }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }

        init(from decoder: Decoder) throws {
            let allKeys = try decoder.container(keyedBy: AnyKey.self).allKeys
            let allowedKeys = Set(CodingKeys.allCases.map(\.rawValue))
            guard allKeys.allSatisfy({ allowedKeys.contains($0.stringValue) }) else {
                throw DecodeError.invalidEnvelope
            }
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decode(Int.self, forKey: .version)
            source = try values.decode(String.self, forKey: .source)
            id = try values.decode(String.self, forKey: .id)
            title = try values.decode(String.self, forKey: .title)
            result = try values.decode(String.self, forKey: .result)
            createdAt = try values.decode(String.self, forKey: .createdAt)
        }
    }
}
