import AppKit
import EventKit
import Observation

/// 观察者令牌在普通对象析构时清理，避免跨 actor 读取可观察属性。
private final class CalendarObservationLifetime {
    let notificationCenter: NotificationCenter
    var tokens: [NSObjectProtocol] = []

    init(notificationCenter: NotificationCenter) {
        self.notificationCenter = notificationCenter
    }

    deinit {
        for token in tokens { notificationCenter.removeObserver(token) }
    }
}

/// 日历数据按当前选择的日期刷新；权限只能由用户操作发起请求。
@Observable @MainActor
final class CalendarManager {
    static let selectedCalendarIdentifiersKey = "selectedCalendarIdentifiers"

    private(set) var hasAccess = false
    private(set) var authorizationStatus: EKAuthorizationStatus = .notDetermined
    private(set) var isRequestingAccess = false
    private(set) var accessError: String?
    var calendars: [EKCalendar] = []
    var upcomingEvents: [EKEvent] = []
    var selectedCalendars: Set<String> = []
    private(set) var displayedDate: Date
    private(set) var currentDate: Date

    private let eventStore: EKEventStore
    private let defaults: UserDefaults
    private let observations: CalendarObservationLifetime
    private let now: () -> Date
    private let calendar: Calendar
    private let readAuthorization: () -> EKAuthorizationStatus
    private let fetchCalendars: () -> [EKCalendar]
    private let fetchEvents: (DateInterval, [EKCalendar]) -> [EKEvent]
    private let requestFullAccess: () async throws -> Bool
    private let didRefreshAuthorization: @MainActor () -> Void
    private var monitoringStopped = false

    init(
        eventStore: EKEventStore = EKEventStore(),
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default,
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .autoupdatingCurrent,
        observeChanges: Bool = true,
        readAuthorization: @escaping () -> EKAuthorizationStatus = { EKEventStore.authorizationStatus(for: .event) },
        fetchCalendars: (() -> [EKCalendar])? = nil,
        fetchEvents: ((DateInterval, [EKCalendar]) -> [EKEvent])? = nil,
        requestFullAccess: (() async throws -> Bool)? = nil,
        didRefreshAuthorization: (@MainActor () -> Void)? = nil
    ) {
        self.eventStore = eventStore
        self.defaults = defaults
        self.observations = CalendarObservationLifetime(notificationCenter: notificationCenter)
        self.now = now
        self.calendar = calendar
        self.readAuthorization = readAuthorization
        self.fetchCalendars = fetchCalendars ?? { eventStore.calendars(for: .event) }
        self.fetchEvents = fetchEvents ?? { interval, calendars in
            let predicate = eventStore.predicateForEvents(
                withStart: interval.start, end: interval.end, calendars: calendars
            )
            return eventStore.events(matching: predicate)
        }
        self.requestFullAccess = requestFullAccess ?? { try await eventStore.requestFullAccessToEvents() }
        self.didRefreshAuthorization = didRefreshAuthorization ?? { CalendarReminderManager.shared.refreshAuthorization() }
        let date = now()
        displayedDate = date
        currentDate = date

        if observeChanges {
            for name in [Notification.Name.EKEventStoreChanged, NSApplication.didBecomeActiveNotification,
                         Notification.Name.NSCalendarDayChanged, Notification.Name.NSSystemTimeZoneDidChange] {
                observations.tokens.append(notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.refresh() }
                })
            }
        }
    }

    /// 展开时仅检查现有权限，不重复弹出系统授权对话框。
    func ensureAccess() {
        refresh()
    }

    func stopMonitoring() {
        monitoringStopped = true
        for token in observations.tokens { observations.notificationCenter.removeObserver(token) }
        observations.tokens.removeAll()
    }

    func refresh() {
        guard !monitoringStopped else { return }
        let date = now()
        if calendar.isDate(displayedDate, inSameDayAs: currentDate),
           !calendar.isDate(currentDate, inSameDayAs: date) {
            displayedDate = date
        }
        currentDate = date
        authorizationStatus = readAuthorization()
        hasAccess = authorizationStatus == .fullAccess
        guard hasAccess else {
            calendars = []
            selectedCalendars = []
            upcomingEvents = []
            return
        }
        accessError = nil
        loadCalendars()
        loadEvents(for: displayedDate)
    }

    func requestAccess() async {
        guard !isRequestingAccess else { return }
        refresh()
        guard !hasAccess else { return }
        // 拒绝或限制后只引导用户去设置，不重新发起系统请求。
        guard authorizationStatus == .notDetermined || authorizationStatus == .writeOnly else { return }
        isRequestingAccess = true
        defer { isRequestingAccess = false }
        do {
            _ = try await requestFullAccess()
            accessError = nil
        } catch {
            accessError = L10n.calendarAccessFailed
        }
        refresh()
        didRefreshAuthorization()
    }

    func loadCalendars() {
        guard hasAccess else { return }
        calendars = fetchCalendars()
        selectedCalendars = Self.selectedCalendarIdentifiers(
            availableIdentifiers: Set(calendars.map(\.calendarIdentifier)),
            storedIdentifiers: defaults.object(forKey: Self.selectedCalendarIdentifiersKey) as? [String]
        )
    }

    static func eventInterval(for date: Date, calendar: Calendar = .current) -> DateInterval? {
        calendar.dateInterval(of: .day, for: date)
    }

    /// 有界缓冲围绕当前浏览位置移动，远期跳转不创建从今天到目标之间的所有日期。
    nonisolated static func visibleDates(centeredOn date: Date, calendar: Calendar = .current) -> [Date] {
        let center = calendar.startOfDay(for: date)
        return (-90...90).compactMap { calendar.date(byAdding: .day, value: $0, to: center) }
    }

    func loadEvents(for date: Date) {
        displayedDate = date
        guard hasAccess, let interval = Self.eventInterval(for: date, calendar: calendar) else {
            upcomingEvents = []
            return
        }
        let selected = calendars.filter { selectedCalendars.contains($0.calendarIdentifier) }
        guard !selected.isEmpty else {
            upcomingEvents = []
            return
        }
        upcomingEvents = Self.eventsForDay(fetchEvents(interval, selected), date: date, calendar: calendar)
    }

    /// EventKit 查询包含跨日事件；再次按半开区间过滤，避免午夜结束的事件占用次日列表。
    static func eventsForDay(_ events: [EKEvent], date: Date, calendar: Calendar = .current) -> [EKEvent] {
        guard let interval = eventInterval(for: date, calendar: calendar) else { return [] }
        return events.filter { event in
            guard let start = event.startDate, let end = event.endDate else { return false }
            return start < interval.end && (end > interval.start || (start == end && start >= interval.start))
        }.sorted { left, right in
            if left.startDate != right.startDate { return left.startDate < right.startDate }
            if left.endDate != right.endDate { return left.endDate < right.endDate }
            return (left.title ?? "") < (right.title ?? "")
        }
    }

    /// 今天只优先展示尚未结束的事件；浏览其他日期仍保留完整时间顺序。
    static func overviewEvents(_ events: [EKEvent], date: Date, now: Date, calendar: Calendar = .current) -> [EKEvent] {
        let dayEvents = eventsForDay(events, date: date, calendar: calendar)
        guard calendar.isDate(date, inSameDayAs: now) else { return dayEvents }
        return dayEvents.filter { event in
            event.endDate > now || (event.startDate == event.endDate && event.startDate >= now)
        }
    }

    func toggleCalendar(_ calendar: EKCalendar) {
        if selectedCalendars.contains(calendar.calendarIdentifier) {
            selectedCalendars.remove(calendar.calendarIdentifier)
        } else {
            selectedCalendars.insert(calendar.calendarIdentifier)
        }
        defaults.set(Array(selectedCalendars).sorted(), forKey: Self.selectedCalendarIdentifiersKey)
        loadEvents(for: displayedDate)
    }

    static func selectedCalendarIdentifiers(availableIdentifiers: Set<String>, storedIdentifiers: [String]?) -> Set<String> {
        guard let storedIdentifiers else { return availableIdentifiers }
        return Set(storedIdentifiers).intersection(availableIdentifiers)
    }

    func createEvent(title: String, startDate: Date, endDate: Date) {
        guard hasAccess else { return }
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
        guard hasAccess else { return }
        do {
            try eventStore.remove(event, span: .thisEvent)
            loadEvents(for: displayedDate)
        } catch {
            print("Failed to delete event: \(error)")
        }
    }
}
