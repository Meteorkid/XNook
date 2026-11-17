import AppKit
import EventKit
import Foundation

@MainActor
final class CalendarReminderManager {
    struct ReminderCandidate: Equatable {
        let identifier: String
        let startDate: Date
        let title: String

        init(identifier: String, startDate: Date, title: String = "") {
            self.identifier = identifier
            self.startDate = startDate
            self.title = title
        }
    }

    struct SoundOption: Identifiable, Equatable {
        let rawValue: String
        var id: String { rawValue }
    }

    static let shared = CalendarReminderManager()

    static let soundOptions: [SoundOption] = [
        .init(rawValue: "Glass"),
        .init(rawValue: "Ping"),
        .init(rawValue: "Pop"),
        .init(rawValue: "Purr"),
        .init(rawValue: "Sosumi"),
        .init(rawValue: "Submarine"),
        .init(rawValue: "Tink"),
    ]

    static let leadMinuteOptions: [Int] = [1, 5, 10, 15, 30]

    var onReminder: (@MainActor (ReminderCandidate) -> Bool)?

    private let defaults: UserDefaults
    private let soundPlayer: @MainActor (String) -> Void
    private let eventStore = EKEventStore()
    private var timer: Timer?
    private var isMonitoring = false
    private var notifiedReminderKeys: Set<String>

    private static let notifiedReminderKeysKey = "calendarReminderNotifiedKeys"

    init(
        defaults: UserDefaults = .standard,
        soundPlayer: @escaping @MainActor (String) -> Void = { soundName in
            if let sound = NSSound(named: NSSound.Name(soundName)) {
                sound.play()
            } else {
                NSSound.beep()
            }
        }
    ) {
        self.defaults = defaults
        self.soundPlayer = soundPlayer
        notifiedReminderKeys = Set(defaults.stringArray(forKey: Self.notifiedReminderKeysKey) ?? [])
    }

    func startMonitoring() {
        isMonitoring = true
        guard timer == nil else {
            refreshAuthorization()
            return
        }

        refreshAuthorization()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkForDueReminders()
            }
        }
    }

    func stopMonitoring() {
        isMonitoring = false
        timer?.invalidate()
        timer = nil
    }

    func refreshAuthorization() {
        checkForDueReminders()
    }

    func playPreviewSound() {
        playSound(named: selectedSoundName)
    }

    func playDueReminderSound(now: Date = Date()) {
        guard soundRemindersEnabled, !isQuietHoursActive(now: now) else { return }
        playSound(named: selectedSoundName)
    }

    @discardableResult
    func deliverReminder(_ reminder: ReminderCandidate, now: Date = Date()) -> Bool {
        guard remindersEnabled, !isQuietHoursActive(now: now),
              reminder.startDate >= now,
              reminder.startDate <= now.addingTimeInterval(max(leadMinutes, 1) * 60) else {
            return false
        }

        let reminderKey = Self.reminderKey(for: reminder.identifier, startDate: reminder.startDate)
        guard !notifiedReminderKeys.contains(reminderKey) else { return false }
        notifiedReminderKeys.insert(reminderKey)
        persistNotifiedReminderKeys()

        // 接管只表示本轮候选已消费；声响由实际展示时的回调决定。
        if activityRemindersEnabled, onReminder?(reminder) == true {
            return true
        }
        playDueReminderSound(now: now)
        return true
    }

    static func isQuietHoursActive(
        enabled: Bool,
        start: String,
        end: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        guard enabled else { return false }

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        guard let startDate = formatter.date(from: start),
              let endDate = formatter.date(from: end) else {
            return false
        }

        let nowComp = calendar.dateComponents([.hour, .minute], from: now)
        let startComp = calendar.dateComponents([.hour, .minute], from: startDate)
        let endComp = calendar.dateComponents([.hour, .minute], from: endDate)

        guard let nowMinute = calendar.date(from: nowComp),
              let startMinute = calendar.date(from: startComp),
              let endMinute = calendar.date(from: endComp) else {
            return false
        }

        if startMinute <= endMinute {
            return nowMinute >= startMinute && nowMinute < endMinute
        }

        return nowMinute >= startMinute || nowMinute < endMinute
    }

    static func nextReminder(
        candidates: [ReminderCandidate],
        now: Date,
        leadTime: TimeInterval,
        notifiedKeys: Set<String>
    ) -> ReminderCandidate? {
        candidates
            .sorted { $0.startDate < $1.startDate }
            .first { candidate in
                guard candidate.startDate >= now,
                      candidate.startDate <= now.addingTimeInterval(leadTime) else {
                    return false
                }
                return !notifiedKeys.contains(reminderKey(for: candidate.identifier, startDate: candidate.startDate))
            }
    }

    private var remindersEnabled: Bool {
        soundRemindersEnabled || activityRemindersEnabled
    }

    private var soundRemindersEnabled: Bool {
        defaults.bool(forKey: "calendarReminderSoundEnabled")
    }

    private var activityRemindersEnabled: Bool {
        defaults.bool(forKey: "activityNotificationsEnabled")
            && defaults.bool(forKey: "calendarReminderActivityEnabled")
    }

    private var quietHoursEnabled: Bool {
        defaults.bool(forKey: "quietHoursEnabled")
    }

    private var quietHoursStart: String {
        defaults.string(forKey: "quietHoursStart") ?? "22:00"
    }

    private var quietHoursEnd: String {
        defaults.string(forKey: "quietHoursEnd") ?? "07:00"
    }

    private var leadMinutes: Double {
        defaults.double(forKey: "calendarReminderLeadMinutes")
    }

    private var selectedSoundName: String {
        let rawValue = defaults.string(forKey: "calendarReminderSoundName") ?? "Glass"
        if Self.soundOptions.contains(where: { $0.rawValue == rawValue }) {
            return rawValue
        }
        return "Glass"
    }

    private func isQuietHoursActive(now: Date) -> Bool {
        Self.isQuietHoursActive(
            enabled: quietHoursEnabled,
            start: quietHoursStart,
            end: quietHoursEnd,
            now: now
        )
    }

    private func checkForDueReminders(now: Date = Date()) {
        guard isMonitoring else { return }
        pruneReminderKeys(referenceDate: now)

        guard remindersEnabled else { return }
        guard !isQuietHoursActive(now: now) else { return }
        guard hasCalendarAccess else { return }

        let leadTime = max(leadMinutes, 1) * 60
        let calendarWindowEnd = now.addingTimeInterval(leadTime)
        let allCalendars = eventStore.calendars(for: .event)
        let selectedIdentifiers = CalendarManager.selectedCalendarIdentifiers(
            availableIdentifiers: Set(allCalendars.map(\.calendarIdentifier)),
            storedIdentifiers: defaults.object(forKey: CalendarManager.selectedCalendarIdentifiersKey) as? [String]
        )
        let calendars = allCalendars.filter { selectedIdentifiers.contains($0.calendarIdentifier) }
        guard !calendars.isEmpty else { return }

        let predicate = eventStore.predicateForEvents(
            withStart: now,
            end: calendarWindowEnd,
            calendars: calendars
        )

        let candidates = eventStore.events(matching: predicate)
            .filter { !$0.isAllDay }
            .compactMap { event -> ReminderCandidate? in
                guard let identifier = event.eventIdentifier, let startDate = event.startDate else { return nil }
                return ReminderCandidate(identifier: identifier, startDate: startDate, title: event.title ?? "")
            }

        guard let reminder = Self.nextReminder(
            candidates: candidates,
            now: now,
            leadTime: leadTime,
            notifiedKeys: notifiedReminderKeys
        ) else {
            return
        }

        deliverReminder(reminder, now: now)
    }

    private var hasCalendarAccess: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) {
            return status == .fullAccess
        }
        // `authorized` 在新 SDK 上已弃用，但旧系统仍会返回同一原始值。
        return status.rawValue == 3
    }

    private func playSound(named soundName: String) {
        soundPlayer(soundName)
    }

    private func pruneReminderKeys(referenceDate: Date) {
        let cutoff = referenceDate.addingTimeInterval(-3600)
        notifiedReminderKeys = notifiedReminderKeys.filter { key in
            guard let timestamp = Double(key.split(separator: "@").last ?? "") else {
                return false
            }
            return Date(timeIntervalSince1970: timestamp) >= cutoff
        }
        persistNotifiedReminderKeys()
    }

    private func persistNotifiedReminderKeys() {
        defaults.set(Array(notifiedReminderKeys).sorted(), forKey: Self.notifiedReminderKeysKey)
    }

    private static func reminderKey(for identifier: String, startDate: Date) -> String {
        "\(identifier)@\(startDate.timeIntervalSince1970)"
    }
}
