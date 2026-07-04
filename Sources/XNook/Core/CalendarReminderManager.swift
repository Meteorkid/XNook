import AppKit
import EventKit
import Foundation

@MainActor
final class CalendarReminderManager {
    struct ReminderCandidate: Equatable {
        let identifier: String
        let startDate: Date
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

    private let eventStore = EKEventStore()
    private var timer: Timer?
    private var notifiedReminderKeys: Set<String> = []

    func startMonitoring() {
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
        timer?.invalidate()
        timer = nil
    }

    func refreshAuthorization() {
        checkForDueReminders()
    }

    func playPreviewSound() {
        playSound(named: selectedSoundName)
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
        UserDefaults.standard.bool(forKey: "calendarReminderSoundEnabled")
    }

    private var quietHoursEnabled: Bool {
        UserDefaults.standard.bool(forKey: "quietHoursEnabled")
    }

    private var quietHoursStart: String {
        UserDefaults.standard.string(forKey: "quietHoursStart") ?? "22:00"
    }

    private var quietHoursEnd: String {
        UserDefaults.standard.string(forKey: "quietHoursEnd") ?? "07:00"
    }

    private var leadMinutes: Double {
        UserDefaults.standard.double(forKey: "calendarReminderLeadMinutes")
    }

    private var selectedSoundName: String {
        let rawValue = UserDefaults.standard.string(forKey: "calendarReminderSoundName") ?? "Glass"
        if Self.soundOptions.contains(where: { $0.rawValue == rawValue }) {
            return rawValue
        }
        return "Glass"
    }

    private func checkForDueReminders(now: Date = Date()) {
        pruneReminderKeys(referenceDate: now)

        guard remindersEnabled else { return }
        guard !Self.isQuietHoursActive(
            enabled: quietHoursEnabled,
            start: quietHoursStart,
            end: quietHoursEnd,
            now: now
        ) else { return }
        guard hasCalendarAccess else { return }

        let leadTime = max(leadMinutes, 1) * 60
        let calendarWindowEnd = now.addingTimeInterval(leadTime)
        let calendars = eventStore.calendars(for: .event)
        guard !calendars.isEmpty else { return }

        let predicate = eventStore.predicateForEvents(
            withStart: now,
            end: calendarWindowEnd,
            calendars: calendars
        )

        let candidates = eventStore.events(matching: predicate)
            .filter { !$0.isAllDay }
            .map { ReminderCandidate(identifier: $0.eventIdentifier, startDate: $0.startDate) }

        guard let reminder = Self.nextReminder(
            candidates: candidates,
            now: now,
            leadTime: leadTime,
            notifiedKeys: notifiedReminderKeys
        ) else {
            return
        }

        notifiedReminderKeys.insert(Self.reminderKey(for: reminder.identifier, startDate: reminder.startDate))
        playSound(named: selectedSoundName)
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
        if let sound = NSSound(named: NSSound.Name(soundName)) {
            sound.play()
        } else {
            NSSound.beep()
        }
    }

    private func pruneReminderKeys(referenceDate: Date) {
        let cutoff = referenceDate.addingTimeInterval(-3600)
        notifiedReminderKeys = notifiedReminderKeys.filter { key in
            guard let timestamp = Double(key.split(separator: "@").last ?? "") else {
                return false
            }
            return Date(timeIntervalSince1970: timestamp) >= cutoff
        }
    }

    private static func reminderKey(for identifier: String, startDate: Date) -> String {
        "\(identifier)@\(startDate.timeIntervalSince1970)"
    }
}
