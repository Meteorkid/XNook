import SwiftUI
import EventKit
import Observation

/// 日历管理器
@Observable @MainActor
final class CalendarManager {
    static let selectedCalendarIdentifiersKey = "selectedCalendarIdentifiers"

    // MARK: - Published Properties

    var hasAccess = false
    var calendars: [EKCalendar] = []
    var upcomingEvents: [EKEvent] = []
    var selectedCalendars: Set<String> = []

    // MARK: - Private Properties

    private let eventStore = EKEventStore()
    private var displayedDate = Date()
    // MARK: - Public Methods

    /// 首次展开日历时触发权限请求（延迟到用户需要时）
    func ensureAccess() {
        guard !hasAccess else { return }
        Task {
            await requestAccess()
        }
    }

    func requestAccess() async {
        if #available(macOS 14.0, *) {
            let granted = try? await eventStore.requestFullAccessToEvents()
            hasAccess = granted ?? false
        } else {
            let granted = try? await eventStore.requestAccess(to: .event)
            hasAccess = granted ?? false
        }

        if hasAccess {
            loadCalendars()
            loadEvents(for: displayedDate)
        }

        CalendarReminderManager.shared.refreshAuthorization()
    }

    func loadCalendars() {
        calendars = eventStore.calendars(for: .event)
        let availableIdentifiers = Set(calendars.map(\.calendarIdentifier))
        selectedCalendars = Self.selectedCalendarIdentifiers(
            availableIdentifiers: availableIdentifiers,
            storedIdentifiers: UserDefaults.standard.object(forKey: Self.selectedCalendarIdentifiersKey) as? [String]
        )
    }

    static func eventInterval(
        for date: Date,
        calendar: Calendar = .current
    ) -> DateInterval? {
        calendar.dateInterval(of: .day, for: date)
    }

    func loadEvents(for date: Date) {
        displayedDate = date
        guard let interval = Self.eventInterval(for: date) else {
            upcomingEvents = []
            return
        }

        let selected = calendars.filter {
            selectedCalendars.contains($0.calendarIdentifier)
        }
        guard !selected.isEmpty else {
            upcomingEvents = []
            return
        }

        let predicate = eventStore.predicateForEvents(
            withStart: interval.start,
            end: interval.end,
            calendars: selected
        )
        upcomingEvents = eventStore.events(matching: predicate).sorted(by: { $0.startDate < $1.startDate })
    }

    func toggleCalendar(_ calendar: EKCalendar) {
        if selectedCalendars.contains(calendar.calendarIdentifier) {
            selectedCalendars.remove(calendar.calendarIdentifier)
        } else {
            selectedCalendars.insert(calendar.calendarIdentifier)
        }
        UserDefaults.standard.set(Array(selectedCalendars).sorted(), forKey: Self.selectedCalendarIdentifiersKey)
        loadEvents(for: displayedDate)
    }

    static func selectedCalendarIdentifiers(
        availableIdentifiers: Set<String>,
        storedIdentifiers: [String]?
    ) -> Set<String> {
        guard let storedIdentifiers else { return availableIdentifiers }
        return Set(storedIdentifiers).intersection(availableIdentifiers)
    }

    func createEvent(title: String, startDate: Date, endDate: Date) {
        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.startDate = startDate
        event.endDate = endDate
        event.calendar = eventStore.defaultCalendarForNewEvents

        do {
            try eventStore.save(event, span: .thisEvent)
            loadEvents(for: displayedDate)
        } catch {
            print("Failed to create event: \(error)")
        }
    }

    func deleteEvent(_ event: EKEvent) {
        do {
            try eventStore.remove(event, span: .thisEvent)
            loadEvents(for: displayedDate)
        } catch {
            print("Failed to delete event: \(error)")
        }
    }
}
