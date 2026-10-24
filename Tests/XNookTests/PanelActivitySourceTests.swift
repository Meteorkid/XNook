import XCTest
@testable import XNook

@MainActor
final class PanelActivitySourceTests: XCTestCase {
    func testCalendarSourceDefersSoundUntilAllowedAndDoesNotReplayOnResume() throws {
        let suite = "XNook.CalendarActivityIntegration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        SettingsDefaults.register(on: defaults)
        defaults.set(true, forKey: "calendarReminderSoundEnabled")
        defaults.set(true, forKey: "calendarReminderActivityEnabled")
        let now = Date()
        var allowed = false
        var sounds: [String] = []
        let calendar = CalendarReminderManager(defaults: defaults, soundPlayer: { sounds.append($0) })
        let activities = PanelActivityCoordinator(now: { now }, schedule: { _, _ in {} },
            isPresentationAllowed: { allowed }, onPresent: { event in
                if event.source == "calendar" { calendar.playDueReminderSound(now: now) }
            })
        defer { activities.shutdown() }
        calendar.onReminder = { [weak activities] reminder in
            activities?.enqueue(.calendarReminder(reminder, now: now))
            return true
        }
        let candidate = CalendarReminderManager.ReminderCandidate(identifier: "event",
            startDate: now.addingTimeInterval(120), title: "评审")
        XCTAssertTrue(calendar.deliverReminder(candidate, now: now))
        XCTAssertNil(activities.current)
        XCTAssertEqual(activities.pendingCount, 1)
        XCTAssertTrue(sounds.isEmpty)
        allowed = true
        activities.refreshPresentation()
        XCTAssertEqual(activities.current?.source, "calendar")
        XCTAssertEqual(sounds, ["Glass"])
        allowed = false
        activities.refreshPresentation()
        allowed = true
        activities.refreshPresentation()
        XCTAssertEqual(sounds.count, 1)
        XCTAssertFalse(calendar.deliverReminder(candidate, now: now))
    }

    func testEachInteractionGatePreventsPresentation() {
        let available = PanelActivityPresentationContext(isWindowActive: true)
        XCTAssertTrue(available.allowsPresentation)
        var hidden = available; hidden.isWindowActive = false
        var editing = available; editing.isEditing = true
        var permission = available; permission.isRequestingPermission = true
        var modal = available; modal.hasModalWindow = true
        var sheet = available; sheet.hasAttachedSheet = true
        var child = available; child.hasVisibleChildWindow = true
        var quiet = available; quiet.isQuietHours = true
        for context in [hidden, editing, permission, modal, sheet, child, quiet] {
            XCTAssertFalse(context.allowsPresentation)
        }
        XCTAssertFalse(PanelActivityPresentationContext().allowsPresentation, "窗口未绑定时默认阻断")
    }

    func testCalendarIdentityIsStableBoundedAndIncludesOccurrence() {
        let now = Date(timeIntervalSince1970: 1000)
        let candidate = CalendarReminderManager.ReminderCandidate(
            identifier: String(repeating: "long-event-id", count: 100),
            startDate: now.addingTimeInterval(120), title: String(repeating: "会议", count: 150))
        let first = PanelActivityEvent.calendarReminder(candidate, now: now)
        let repeated = PanelActivityEvent.calendarReminder(candidate, now: now.addingTimeInterval(1))
        let nextOccurrence = PanelActivityEvent.calendarReminder(.init(identifier: candidate.identifier,
            startDate: candidate.startDate.addingTimeInterval(3600), title: candidate.title), now: now)
        XCTAssertEqual(first.id, repeated.id)
        XCTAssertNotEqual(first.id, nextOccurrence.id)
        XCTAssertEqual(first.id.count, 64)
        XCTAssertEqual(first.title.count, 160)
        XCTAssertEqual(first.action, .openCalendar)
        XCTAssertEqual(first.kind, .deadline)
        XCTAssertEqual(first.expiresAt, now.addingTimeInterval(60))
    }

    func testCompletedTaskUsesSessionIdentityAndActualEndTime() {
        let date = Date(timeIntervalSince1970: 1000)
        let session = FocusSession(id: UUID(), title: "Task", eventIdentifier: nil,
            startedAt: date.addingTimeInterval(-30), scheduledEndAt: nil, endedAt: date,
            state: .ended, linkedNote: nil, linkedFiles: [])
        let event = PanelActivityEvent.completedSession(session)
        XCTAssertEqual(event.source, "focus")
        XCTAssertEqual(event.id, session.id.uuidString)
        XCTAssertEqual(event.kind, .completion)
        XCTAssertEqual(event.createdAt, date)
        XCTAssertEqual(event.action, .none)
    }
}
