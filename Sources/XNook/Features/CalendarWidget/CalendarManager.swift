import SwiftUI
import EventKit

/// 日历管理器
@MainActor
final class CalendarManager: ObservableObject {
    // MARK: - Published Properties

    @Published var hasAccess = false
    @Published var calendars: [EKCalendar] = []
    @Published var upcomingEvents: [EKEvent] = []
    @Published var selectedCalendars: Set<String> = []

    // MARK: - Private Properties

    private let eventStore = EKEventStore()

    // MARK: - Init

    init() {
        Task {
            await requestAccess()
        }
    }

    // MARK: - Public Methods

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
            loadUpcomingEvents()
        }
    }

    func loadCalendars() {
        calendars = eventStore.calendars(for: .event)
    }

    func loadUpcomingEvents() {
        let startDate = Date()
        let endDate = Calendar.current.date(byAdding: .day, value: 7, to: startDate)!

        let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: nil)
        upcomingEvents = eventStore.events(matching: predicate).sorted(by: { $0.startDate < $1.startDate })
    }

    func toggleCalendar(_ calendar: EKCalendar) {
        if selectedCalendars.contains(calendar.calendarIdentifier) {
            selectedCalendars.remove(calendar.calendarIdentifier)
        } else {
            selectedCalendars.insert(calendar.calendarIdentifier)
        }
        loadUpcomingEvents()
    }

    func createEvent(title: String, startDate: Date, endDate: Date) {
        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.startDate = startDate
        event.endDate = endDate
        event.calendar = eventStore.defaultCalendarForNewEvents

        do {
            try eventStore.save(event, span: .thisEvent)
            loadUpcomingEvents()
        } catch {
            print("Failed to create event: \(error)")
        }
    }

    func deleteEvent(_ event: EKEvent) {
        do {
            try eventStore.remove(event, span: .thisEvent)
            loadUpcomingEvents()
        } catch {
            print("Failed to delete event: \(error)")
        }
    }
}
