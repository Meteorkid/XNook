import XCTest
@testable import XNook

@MainActor
final class CalendarActivityDeliveryTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var manager: CalendarReminderManager!
    private var playedSounds: [String] = []

    override func setUp() {
        super.setUp()
        suiteName = "XNook.CalendarActivityDeliveryTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(false, forKey: "calendarReminderSoundEnabled")
        defaults.set(false, forKey: "calendarReminderActivityEnabled")
        defaults.set(false, forKey: "activityNotificationsEnabled")
        defaults.set(false, forKey: "quietHoursEnabled")
        defaults.set("22:00", forKey: "quietHoursStart")
        defaults.set("07:00", forKey: "quietHoursEnd")
        defaults.set(5, forKey: "calendarReminderLeadMinutes")
        defaults.set("Ping", forKey: "calendarReminderSoundName")
        manager = makeManager()
    }

    override func tearDown() {
        manager = nil
        playedSounds = []
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testSoundOnlyRetainsOriginalBehavior() {
        defaults.set(true, forKey: "calendarReminderSoundEnabled")
        manager.onReminder = { _ in
            XCTFail("文字提醒关闭时不应委托展示")
            return true
        }
        let now = date(hour: 9)

        XCTAssertTrue(manager.deliverReminder(reminder(now: now), now: now))
        XCTAssertEqual(playedSounds, ["Ping"])
    }

    func testVisualOnlyDeliversTitleWithoutSound() {
        enableActivityReminders()
        let now = date(hour: 9)
        let candidate = reminder(now: now)
        var received: [CalendarReminderManager.ReminderCandidate] = []
        manager.onReminder = { received.append($0); return true }

        XCTAssertTrue(manager.deliverReminder(candidate, now: now))
        XCTAssertEqual(received, [candidate])
        XCTAssertEqual(received.first?.title, "项目评审")
        manager.playDueReminderSound(now: now)
        XCTAssertTrue(playedSounds.isEmpty)
    }

    func testVisualOnlyWithoutDelegateStillDoesNotPlaySound() {
        enableActivityReminders()
        let now = date(hour: 9)

        XCTAssertTrue(manager.deliverReminder(reminder(now: now), now: now))
        XCTAssertTrue(playedSounds.isEmpty)
    }

    func testConsumedReminderWaitsForActualPresentationBeforeSound() {
        enableActivityReminders()
        defaults.set(true, forKey: "calendarReminderSoundEnabled")
        manager.onReminder = { _ in true }
        let now = date(hour: 9)

        XCTAssertTrue(manager.deliverReminder(reminder(now: now), now: now))
        XCTAssertTrue(playedSounds.isEmpty)
        manager.playDueReminderSound(now: now)
        XCTAssertEqual(playedSounds, ["Ping"])
    }

    func testDeclinedDelegateFallsBackToEnabledSound() {
        enableActivityReminders()
        defaults.set(true, forKey: "calendarReminderSoundEnabled")
        var calls = 0
        manager.onReminder = { _ in calls += 1; return false }
        let now = date(hour: 9)

        XCTAssertTrue(manager.deliverReminder(reminder(now: now), now: now))
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(playedSounds, ["Ping"])
    }

    func testConsumedReminderIsDeduplicatedAcrossManagerInstances() {
        enableActivityReminders()
        let now = date(hour: 9)
        let candidate = reminder(now: now)
        var calls = 0
        manager.onReminder = { _ in calls += 1; return true }

        XCTAssertTrue(manager.deliverReminder(candidate, now: now))
        XCTAssertFalse(manager.deliverReminder(candidate, now: now))
        let reloaded = makeManager()
        reloaded.onReminder = { _ in calls += 1; return true }
        XCTAssertFalse(reloaded.deliverReminder(candidate, now: now))
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(playedSounds.isEmpty)
    }

    func testQuietHoursSuppressDeliveryWithoutConsumingCandidate() {
        enableActivityReminders()
        defaults.set(true, forKey: "calendarReminderSoundEnabled")
        defaults.set(true, forKey: "quietHoursEnabled")
        let now = date(hour: 23)
        let candidate = reminder(now: now)
        var calls = 0
        manager.onReminder = { _ in calls += 1; return true }

        XCTAssertFalse(manager.deliverReminder(candidate, now: now))
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(playedSounds.isEmpty)
        defaults.set(false, forKey: "quietHoursEnabled")
        XCTAssertTrue(manager.deliverReminder(candidate, now: now))
        XCTAssertEqual(calls, 1)
    }

    func testDisabledRemindersDoNotDeliverOrConsumeCandidate() {
        let now = date(hour: 9)
        let candidate = reminder(now: now)
        var calls = 0
        manager.onReminder = { _ in calls += 1; return true }

        XCTAssertFalse(manager.deliverReminder(candidate, now: now))
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(playedSounds.isEmpty)
        enableActivityReminders()
        XCTAssertTrue(manager.deliverReminder(candidate, now: now))
        XCTAssertEqual(calls, 1)
    }

    func testMasterSwitchDisablesVisualDeliveryAndKeepsSoundMode() {
        defaults.set(true, forKey: "calendarReminderActivityEnabled")
        manager.onReminder = { _ in
            XCTFail("总开关关闭时不应委托展示")
            return true
        }
        let now = date(hour: 9)
        let candidate = reminder(now: now)

        XCTAssertFalse(manager.deliverReminder(candidate, now: now))
        defaults.set(true, forKey: "calendarReminderSoundEnabled")
        XCTAssertTrue(manager.deliverReminder(candidate, now: now))
        XCTAssertEqual(playedSounds, ["Ping"])
    }

    func testPastAndOutOfWindowRemindersAreNotDelivered() {
        enableActivityReminders()
        defaults.set(true, forKey: "calendarReminderSoundEnabled")
        manager.onReminder = { _ in
            XCTFail("窗口外候选不应投递")
            return true
        }
        let now = date(hour: 9)

        for offset: TimeInterval in [-1, 301] {
            let candidate = CalendarReminderManager.ReminderCandidate(
                identifier: "event-\(offset)", startDate: now.addingTimeInterval(offset)
            )
            XCTAssertFalse(manager.deliverReminder(candidate, now: now))
        }
        XCTAssertTrue(playedSounds.isEmpty)
        XCTAssertNil(defaults.stringArray(forKey: "calendarReminderNotifiedKeys"))
    }

    func testPresentationRechecksCurrentSoundAndQuietHoursSettings() {
        enableActivityReminders()
        defaults.set(true, forKey: "calendarReminderSoundEnabled")
        manager.onReminder = { _ in true }
        let now = date(hour: 23)
        XCTAssertTrue(manager.deliverReminder(reminder(now: now), now: now))

        defaults.set(false, forKey: "calendarReminderSoundEnabled")
        manager.playDueReminderSound(now: now)
        defaults.set(true, forKey: "calendarReminderSoundEnabled")
        defaults.set(true, forKey: "quietHoursEnabled")
        manager.playDueReminderSound(now: now)
        XCTAssertTrue(playedSounds.isEmpty)

        defaults.set(false, forKey: "quietHoursEnabled")
        defaults.set("Tink", forKey: "calendarReminderSoundName")
        manager.playDueReminderSound(now: now)
        XCTAssertEqual(playedSounds, ["Tink"])
    }

    func testExplicitPreviewRetainsSoundEvenWhenRemindersAreDisabled() {
        defaults.set(true, forKey: "quietHoursEnabled")
        defaults.set("invalid-sound", forKey: "calendarReminderSoundName")

        manager.playPreviewSound()

        XCTAssertEqual(playedSounds, ["Glass"])
        XCTAssertNil(defaults.stringArray(forKey: "calendarReminderNotifiedKeys"))
    }

    private func makeManager() -> CalendarReminderManager {
        CalendarReminderManager(defaults: defaults, soundPlayer: { [weak self] in
            self?.playedSounds.append($0)
        })
    }

    private func enableActivityReminders() {
        defaults.set(true, forKey: "activityNotificationsEnabled")
        defaults.set(true, forKey: "calendarReminderActivityEnabled")
    }

    private func reminder(now: Date) -> CalendarReminderManager.ReminderCandidate {
        .init(identifier: "event", startDate: now.addingTimeInterval(120), title: "项目评审")
    }

    private func date(hour: Int) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(
            year: 2026, month: 7, day: 4, hour: hour, minute: 0, second: 0
        ))!
    }
}
