import Foundation
import CryptoKit

extension PanelActivityEvent {
    @MainActor
    static func completedSession(_ session: FocusSession) -> PanelActivityEvent {
        PanelActivityEvent(source: "focus", id: session.id.uuidString,
            title: String(L10n.activityTaskCompleted(session.title).prefix(160)), kind: .completion,
            createdAt: session.endedAt ?? Date())
    }

    @MainActor
    static func calendarReminder(_ reminder: CalendarReminderManager.ReminderCandidate, now: Date = Date()) -> PanelActivityEvent {
        let key = "\(reminder.identifier)@\(reminder.startDate.timeIntervalSince1970)"
        let id = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let title = reminder.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return PanelActivityEvent(source: "calendar", id: id,
            title: String(L10n.activityCalendarDue(title.isEmpty ? L10n.untitled : title).prefix(160)),
            kind: .deadline, createdAt: now, action: .openCalendar)
    }
}

/// 只判断展示许可；输入由宿主从当前窗口和交互状态读取。
struct PanelActivityPresentationContext {
    var isWindowActive = false
    var isEditing = false
    var isRequestingPermission = false
    var hasModalWindow = false
    var hasAttachedSheet = false
    var hasVisibleChildWindow = false
    var isQuietHours = false

    var allowsPresentation: Bool {
        isWindowActive && !isEditing && !isRequestingPermission
            && !hasModalWindow && !hasAttachedSheet && !hasVisibleChildWindow && !isQuietHours
    }
}
