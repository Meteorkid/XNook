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
    private var displayedDate = Date()
    private var hasInitializedCalendarSelection = false

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
    }

    func loadCalendars() {
        calendars = eventStore.calendars(for: .event)
        let availableIdentifiers = Set(calendars.map(\.calendarIdentifier))
        if hasInitializedCalendarSelection {
            selectedCalendars.formIntersection(availableIdentifiers)
        } else {
            selectedCalendars = availableIdentifiers
            hasInitializedCalendarSelection = true
        }
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
        loadEvents(for: displayedDate)
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
