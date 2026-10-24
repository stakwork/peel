import EventKit
import Foundation

/// Whether Peel may use Calendar or Reminders on this Mac.
public enum CalendarAccess: Sendable, Equatable {
    case allowed
    /// Turned off, or limited to adding (macOS's "Add events only").
    case denied
    /// Never asked.
    case undetermined
}

/// Events or reminders: macOS asks for each apart.
public enum CalendarEntity: Sendable {
    case events, reminders
}

/// One calendar event, as the device requests read and write it. A new
/// one has an empty `id`; an empty `calendar` is the default calendar.
public struct CalendarEvent: Sendable, Equatable {
    public var id = ""
    public var title: String
    public var start: Date
    public var end: Date
    public var allDay = false
    public var calendar = ""
    public var location: String?
    public var notes: String?
    /// Marks an event Peel made for one device request (`DeviceCalendar.marker`).
    public var url: URL?

    public init(id: String = "", title: String, start: Date, end: Date, allDay: Bool = false, calendar: String = "",
                location: String? = nil, notes: String? = nil, url: URL? = nil) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.allDay = allDay
        self.calendar = calendar
        self.location = location
        self.notes = notes
        self.url = url
    }
}

/// One reminder: a new one has an empty `id`, an empty `list` the default list.
public struct CalendarReminder: Sendable, Equatable {
    public var id = ""
    public var title: String
    public var due: Date?
    /// Due on a day, at no time: Reminders shows it all day.
    public var dueIsDay = false
    public var list = ""
    public var done = false
    public var notes: String?
    public var url: URL?

    public init(id: String = "", title: String, due: Date? = nil, dueIsDay: Bool = false, list: String = "", done: Bool = false,
                notes: String? = nil, url: URL? = nil) {
        self.id = id
        self.title = title
        self.due = due
        self.dueIsDay = dueIsDay
        self.list = list
        self.done = done
        self.notes = notes
        self.url = url
    }
}

/// The calendars and reminders the agent's device requests reach
/// (`DeviceCalendar`): EventKit on the Mac (`EventKitCalendar`), or a
/// stand-in that touches nothing (`StandInCalendar`) for tests and the
/// offscreen checks.
public protocol CalendarStore: Sendable {
    func access(_ entity: CalendarEntity) async -> CalendarAccess
    /// Asks macOS once, with its prompt: whether it is allowed now.
    func requestAccess(_ entity: CalendarEntity) async -> Bool
    func events(from start: Date, to end: Date) async throws -> [CalendarEvent]
    func event(id: String) async throws -> CalendarEvent?
    /// Saves a new event (empty `id`) or changes one; the event as saved.
    func save(_ event: CalendarEvent) async throws -> CalendarEvent
    func deleteEvent(id: String) async throws
    func reminders(includingDone: Bool) async throws -> [CalendarReminder]
    func reminder(id: String) async throws -> CalendarReminder?
    /// Adds a new reminder; the reminder as saved.
    func add(_ reminder: CalendarReminder) async throws -> CalendarReminder
    /// Marks a reminder done, changing nothing else about it.
    func complete(id: String) async throws -> CalendarReminder
    /// The calendars (or reminder lists) that can be written to, by name.
    func calendars(_ entity: CalendarEntity) async -> [String]
}

/// The person's Calendar and Reminders through EventKit. Every EventKit
/// object stays inside the actor; what leaves is plain values.
public actor EventKitCalendar: CalendarStore {
    private let store = EKEventStore()

    public init() {}

    public func access(_ entity: CalendarEntity) -> CalendarAccess {
        switch EKEventStore.authorizationStatus(for: Self.type(entity)) {
        case .fullAccess: .allowed
        case .notDetermined: .undetermined
        default: .denied
        }
    }

    public func requestAccess(_ entity: CalendarEntity) async -> Bool {
        await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            let answer: EKEventStoreRequestAccessCompletionHandler = { granted, _ in done.resume(returning: granted) }
            switch entity {
            case .events: store.requestFullAccessToEvents(completion: answer)
            case .reminders: store.requestFullAccessToReminders(completion: answer)
            }
        }
    }

    public func events(from start: Date, to end: Date) -> [CalendarEvent] {
        store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil)).map(Self.value)
    }

    public func event(id: String) -> CalendarEvent? {
        find(id).map(Self.value)
    }

    public func save(_ event: CalendarEvent) throws -> CalendarEvent {
        let saved: EKEvent
        if event.id.isEmpty {
            saved = EKEvent(eventStore: store)
            saved.calendar = try calendar(event.calendar, for: .event) ?? store.defaultCalendarForNewEvents
        } else {
            guard let found = find(event.id) else { throw ToolFailure.noItem("event") }
            saved = found
        }
        // Only what differs: an untouched field (a location's map pin) stays as it is.
        if saved.title != event.title { saved.title = event.title }
        if saved.startDate != event.start { saved.startDate = event.start }
        if saved.endDate != event.end { saved.endDate = event.end }
        if saved.isAllDay != event.allDay { saved.isAllDay = event.allDay }
        if saved.location != event.location { saved.location = event.location }
        if saved.notes != event.notes { saved.notes = event.notes }
        if let url = event.url { saved.url = url }
        try store.save(saved, span: .thisEvent, commit: true)
        return Self.value(saved)
    }

    public func deleteEvent(id: String) throws {
        guard let event = find(id) else { throw ToolFailure.noItem("event") }
        try store.remove(event, span: .thisEvent, commit: true)
    }

    public func reminders(includingDone: Bool) async -> [CalendarReminder] {
        let predicate = includingDone
            ? store.predicateForReminders(in: nil)
            : store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        return await withCheckedContinuation { (done: CheckedContinuation<[CalendarReminder], Never>) in
            _ = store.fetchReminders(matching: predicate) { found in
                done.resume(returning: (found ?? []).map(Self.value))
            }
        }
    }

    public func reminder(id: String) -> CalendarReminder? {
        (store.calendarItem(withIdentifier: id) as? EKReminder).map(Self.value)
    }

    public func add(_ reminder: CalendarReminder) throws -> CalendarReminder {
        let saved = EKReminder(eventStore: store)
        guard let list = try calendar(reminder.list, for: .reminder) ?? store.defaultCalendarForNewReminders() else {
            throw ToolFailure(errorDescription: "There is no Reminders list to add it to.")
        }
        saved.calendar = list
        saved.title = reminder.title
        saved.dueDateComponents = reminder.due.map {
            Calendar.current.dateComponents(reminder.dueIsDay ? [.calendar, .year, .month, .day]
                                                : [.calendar, .timeZone, .year, .month, .day, .hour, .minute], from: $0)
        }
        saved.notes = reminder.notes
        saved.url = reminder.url
        try store.save(saved, commit: true)
        return Self.value(saved)
    }

    public func complete(id: String) throws -> CalendarReminder {
        guard let saved = store.calendarItem(withIdentifier: id) as? EKReminder else { throw ToolFailure.noItem("reminder") }
        saved.isCompleted = true
        try store.save(saved, commit: true)
        return Self.value(saved)
    }

    public func calendars(_ entity: CalendarEntity) -> [String] {
        store.calendars(for: Self.type(entity)).filter(\.allowsContentModifications).map(\.title)
    }

    /// An event by its id here (`id(of:)`): one occurrence of a recurring
    /// event, which EventKit's own id names only as the whole series (its
    /// `event(withIdentifier:)` is the first occurrence).
    private func find(_ id: String) -> EKEvent? {
        let parts = id.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let seconds = TimeInterval(parts[1]) else { return store.event(withIdentifier: id) }
        let occurrence = Date(timeIntervalSince1970: seconds)
        let near = store.predicateForEvents(withStart: occurrence.addingTimeInterval(-86400), end: occurrence.addingTimeInterval(86400),
                                            calendars: nil)
        return store.events(matching: near).first { $0.eventIdentifier == String(parts[0]) && $0.occurrenceDate.map { Int($0.timeIntervalSince1970) } == Int(seconds) }
    }

    /// An occurrence of a recurring event is its series' id and when it was
    /// due to start; any other event is EventKit's id.
    private static func id(of event: EKEvent) -> String {
        let id = event.eventIdentifier ?? ""
        guard event.hasRecurrenceRules, let occurrence = event.occurrenceDate else { return id }
        return "\(id)@\(Int(occurrence.timeIntervalSince1970))"
    }

    /// The writable calendar called `name`; nil for no name (the default).
    private func calendar(_ name: String, for type: EKEntityType) throws -> EKCalendar? {
        guard !name.isEmpty else { return nil }
        guard let found = store.calendars(for: type).first(where: { $0.title == name && $0.allowsContentModifications }) else {
            throw ToolFailure(errorDescription: "There is no \(type == .event ? "calendar" : "Reminders list") called \u{201C}\(name)\u{201D} that Peel can add to.")
        }
        return found
    }

    private static func type(_ entity: CalendarEntity) -> EKEntityType {
        entity == .events ? .event : .reminder
    }

    private static func value(_ event: EKEvent) -> CalendarEvent {
        CalendarEvent(id: id(of: event), title: event.title ?? "", start: event.startDate, end: event.endDate,
                      allDay: event.isAllDay, calendar: event.calendar?.title ?? "", location: event.location,
                      notes: event.notes, url: event.url)
    }

    private static func value(_ reminder: EKReminder) -> CalendarReminder {
        CalendarReminder(id: reminder.calendarItemIdentifier, title: reminder.title ?? "",
                         due: reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) },
                         dueIsDay: reminder.dueDateComponents.map { $0.hour == nil } ?? false,
                         list: reminder.calendar?.title ?? "", done: reminder.isCompleted, notes: reminder.notes,
                         url: reminder.url)
    }


}

/// A calendar that lives only in memory, for the tests and the offscreen
/// checks: it never asks macOS and never touches the person's Calendar or
/// Reminders. Access is what it was made with.
public actor StandInCalendar: CalendarStore {
    public private(set) var allEvents: [CalendarEvent]
    public private(set) var allReminders: [CalendarReminder]
    private let granted: CalendarAccess
    /// How many times it asked for access, as macOS's prompt would.
    public private(set) var asked = 0
    private var next = 0

    public init(access: CalendarAccess = .allowed, events: [CalendarEvent] = [], reminders: [CalendarReminder] = []) {
        granted = access
        allEvents = events
        allReminders = reminders
    }

    public func access(_ entity: CalendarEntity) -> CalendarAccess { granted }

    public func requestAccess(_ entity: CalendarEntity) -> Bool {
        asked += 1
        return granted == .allowed
    }

    public func events(from start: Date, to end: Date) -> [CalendarEvent] {
        allEvents.filter { $0.start < end && $0.end > start }.sorted { $0.start < $1.start }
    }

    public func event(id: String) -> CalendarEvent? {
        allEvents.first { $0.id == id }
    }

    public func save(_ event: CalendarEvent) throws -> CalendarEvent {
        var event = event
        if event.calendar.isEmpty { event.calendar = "Calendar" }
        if let index = allEvents.firstIndex(where: { $0.id == event.id && !event.id.isEmpty }) {
            allEvents[index] = event
        } else {
            guard event.id.isEmpty else { throw ToolFailure.noItem("event") }
            next += 1
            event.id = "event-\(next)"
            allEvents.append(event)
        }
        return event
    }

    public func deleteEvent(id: String) throws {
        guard allEvents.contains(where: { $0.id == id }) else {
            throw ToolFailure.noItem("event")
        }
        allEvents.removeAll { $0.id == id }
    }

    public func reminders(includingDone: Bool) -> [CalendarReminder] {
        allReminders.filter { includingDone || !$0.done }
    }

    public func reminder(id: String) -> CalendarReminder? {
        allReminders.first { $0.id == id }
    }

    public func add(_ reminder: CalendarReminder) -> CalendarReminder {
        var reminder = reminder
        if reminder.list.isEmpty { reminder.list = "Reminders" }
        next += 1
        reminder.id = "reminder-\(next)"
        allReminders.append(reminder)
        return reminder
    }

    public func complete(id: String) throws -> CalendarReminder {
        guard let index = allReminders.firstIndex(where: { $0.id == id }) else {
            throw ToolFailure.noItem("reminder")
        }
        allReminders[index].done = true
        return allReminders[index]
    }

    public func calendars(_ entity: CalendarEntity) -> [String] {
        entity == .events ? ["Calendar"] : ["Reminders"]
    }
}
