import AgentKit
import CryptoKit
import Foundation
import PeelCore

/// The Calendar and Reminders device requests (docs/agent-on-strut.md,
/// "Request types"), on the Mac: `calendar.events` and `reminders.list`
/// answer at once; `calendar.create`, `calendar.update`, `calendar.delete`,
/// `reminders.create` and `reminders.complete` are worked out first and
/// shown on the card (`DeviceActions`), and what the card showed is what is
/// done. Access is checked before anything else, and asked for with macOS's
/// prompt the first time; turned off, the answer says so.
struct DeviceCalendar: Sendable {
    let store: any CalendarStore

    static func handles(_ kind: String) -> Bool { DeviceKind.calendarReads.contains(kind) || DeviceKind.calendarChanges.contains(kind) }

    /// The widest window one read covers, in days.
    static let maxDays = 62
    /// The most events or reminders one read lists.
    static let maxItems = 200
    static let maxTitle = 200
    static let maxNotes = 2000
    /// EventKit's ids run to about 75 characters; a longer one is no id.
    static let maxID = 200

    enum Plan {
        case answer(DeviceAnswer)
        /// A change, shown on the card first; `run` makes it and says what it did.
        case change(ToolIntent, @Sendable () async throws -> String)
    }

    func plan(_ request: DeviceRequest, _ args: AgentKit.JSONValue) async -> Plan {
        let entity: CalendarEntity = request.kind.hasPrefix("reminders.") ? .reminders : .events
        if let refusal = await allowed(entity) { return .answer(refusal) }
        do {
            switch request.kind {
            case "calendar.events": return .answer(.done(try await events(args)))
            case "reminders.list": return .answer(.done(try await reminders(args)))
            case "calendar.create": return try await createEvent(args, marker: Self.marker(request))
            case "calendar.update": return try await updateEvent(args)
            case "calendar.delete": return try await deleteEvent(args)
            case "reminders.create": return try await createReminder(args, marker: Self.marker(request))
            case "reminders.complete": return try await completeReminder(args)
            default: return .answer(.failed("unsupported: this Mac does not answer '\(request.kind)' requests"))
            }
        } catch {
            return .answer(.failed(error.localizedDescription))
        }
    }

    /// Nil when Peel may use `entity`, asking macOS first if it never has;
    /// otherwise the answer that says it may not.
    private func allowed(_ entity: CalendarEntity) async -> DeviceAnswer? {
        var access = await store.access(entity)
        if access == .undetermined { access = await store.requestAccess(entity) ? .allowed : .denied }
        let (app, pane) = entity == .events ? ("Calendar", "Calendars") : ("Reminders", "Reminders")
        switch access {
        case .allowed:
            return nil
        case .denied:
            return .denied("Peel is not allowed to use \(app) on this Mac. The user can allow it in System Settings › "
                + "Privacy & Security › \(pane), then ask again.")
        case .undetermined:
            return .denied("Peel has not been allowed to use \(app) on this Mac yet.")
        }
    }

    // MARK: - Reads

    /// `from`, `to` (a date alone covers that day), `calendars?` (names).
    private func events(_ args: AgentKit.JSONValue) async throws -> String {
        let from = try Self.time("from", in: args).date
        let (end, endDay) = try Self.time("to", in: args)
        let to = endDay ? Self.nextDay(end) : end
        guard to > from else { throw ToolFailure(errorDescription: "to must be after from") }
        guard to.timeIntervalSince(from) <= Double(Self.maxDays) * 86400 else {
            throw ToolFailure(errorDescription: "Read at most \(Self.maxDays) days at once.")
        }
        var found = try await store.events(from: from, to: to)
        if let names = args["calendars"]?.array?.compactMap(\.string), !names.isEmpty {
            found = found.filter { names.contains($0.calendar) }
        }
        var data = ChatData("Events on the user's calendar from \(Self.stamp(from)) to \(Self.stamp(to)), earliest first "
            + "(the Mac's time zone is \(TimeZone.current.identifier)):")
        for event in found.prefix(Self.maxItems) { data.add(Self.line(event)) }
        if found.isEmpty { data.notes.append("[no events]") }
        if found.count > Self.maxItems { data.notes.append("[the first \(Self.maxItems) of \(found.count) shown; ask for a narrower window]") }
        return data.text
    }

    /// `list?`, `include_done?`, `limit?`: due ones first, soonest first.
    private func reminders(_ args: AgentKit.JSONValue) async throws -> String {
        let includeDone = args["include_done"] == .bool(true)
        var found = try await store.reminders(includingDone: includeDone)
        let list = SphinxTools.optional("list", in: args)
        if let list { found = found.filter { $0.list == list } }
        found.sort { ($0.due ?? .distantFuture, $0.title) < ($1.due ?? .distantFuture, $1.title) }
        let limit = SphinxTools.limit(args, (default: 50, max: Self.maxItems))
        let which = list.map { " in the list \u{201C}\(ChatData.clean($0, max: ChatData.maxName))\u{201D}" } ?? ""
        var data = ChatData("The user's \(includeDone ? "" : "open ")reminders\(which), due soonest first:")
        for reminder in found.prefix(limit) { data.add(Self.line(reminder)) }
        if found.isEmpty { data.notes.append("[no reminders]") }
        if found.count > limit { data.notes.append("[the first \(limit) of \(found.count) shown]") }
        return data.text
    }

    // MARK: - Changes

    /// `title`, `start`, `end?` (an hour after `start` when left out),
    /// `all_day?` (or `start` a date alone), `calendar?`, `location?`, `notes?`.
    private func createEvent(_ args: AgentKit.JSONValue, marker: URL) async throws -> Plan {
        let title = try Self.title(args)
        let (start, startDay) = try Self.time("start", in: args)
        let allDay = args["all_day"] == .bool(true) || startDay
        let given = try Self.optionalTime("end", in: args)
        let end = allDay ? Self.nextDay(given ?? start) : given ?? start.addingTimeInterval(3600)
        guard end > start else { throw ToolFailure(errorDescription: "end must be after start") }
        let calendar = try await calendarName(args, .events)
        let event = CalendarEvent(title: title, start: allDay ? Calendar.current.startOfDay(for: start) : start, end: end,
                                  allDay: allDay, calendar: calendar, location: try Self.text("location", in: args, max: Self.maxTitle),
                                  notes: try Self.text("notes", in: args, max: Self.maxNotes), url: marker)
        // Made already for this request (Peel stopped before it answered): not made twice.
        let around = try await store.events(from: event.start.addingTimeInterval(-86400), to: event.end.addingTimeInterval(86400))
        if let made = around.first(where: { $0.url == marker }) { return .answer(.done(Self.said("Added", made))) }
        var details = [Self.when(event), "Calendar: \(calendar.isEmpty ? "your default calendar" : ChatData.clean(calendar, max: ChatData.maxName))"]
        if let location = event.location { details.append("At \(location)") }
        let intent = ToolIntent(action: "Add \u{201C}\(title)\u{201D} to your calendar", content: event.notes, details: details)
        return .change(intent) { [store] in Self.said("Added", try await store.save(event)) }
    }

    /// `id`, then any of `title`, `start`, `end`, `all_day`, `location`,
    /// `notes`. A new `start` alone keeps the event's length.
    private func updateEvent(_ args: AgentKit.JSONValue) async throws -> Plan {
        let old = try await event(args)
        var new = old
        if args["title"] != nil { new.title = try Self.title(args) }
        if case .bool(let allDay)? = args["all_day"] { new.allDay = allDay }
        if old.allDay, !new.allDay, args["start"] == nil {
            throw ToolFailure(errorDescription: "Give start (and end) to make an all-day event a timed one.")
        }
        if let start = try Self.optionalTime("start", in: args) {
            new.start = start
            // An all-day event moves by whole days (not hours, which a change of the clocks would skew).
            let days = Calendar.current.dateComponents([.day], from: old.start, to: old.end).day ?? 1
            new.end = old.allDay && new.allDay
                ? Calendar.current.date(byAdding: .day, value: max(days, 1), to: Calendar.current.startOfDay(for: start)) ?? start
                : start.addingTimeInterval(old.end.timeIntervalSince(old.start))
        }
        if let end = try Self.optionalTime("end", in: args) { new.end = new.allDay ? Self.nextDay(end) : end }
        if new.allDay, !old.allDay || new.start != old.start {
            new.start = Calendar.current.startOfDay(for: new.start)
            if new.end <= new.start { new.end = Self.nextDay(new.start) }
        }
        guard new.end > new.start else { throw ToolFailure(errorDescription: "end must be after start") }
        if args["location"] != nil { new.location = try Self.text("location", in: args, max: Self.maxTitle) }
        if args["notes"] != nil { new.notes = try Self.text("notes", in: args, max: Self.maxNotes) }
        // Already so (asked again after a stop, or nothing asked): nothing to do.
        guard new != old else { return .answer(.done("Nothing to change: \(Self.said("It is", old))")) }
        let name = ChatData.clean(old.title, max: Self.maxTitle)
        var details: [String] = []
        if new.title != old.title { details.append("Title: \u{201C}\(name)\u{201D} becomes \u{201C}\(new.title)\u{201D}") }
        if (new.start, new.end, new.allDay) != (old.start, old.end, old.allDay) {
            details += ["Was: \(Self.when(old))", "Now: \(Self.when(new))"]
        } else {
            details.append(Self.when(old))
        }
        if new.location != old.location { details.append(new.location.map { "At \($0)" } ?? "No location") }
        if new.notes != old.notes, new.notes == nil { details.append("Its notes are removed") }
        let intent = ToolIntent(action: "Change \u{201C}\(name)\u{201D} on your calendar",
                                content: new.notes != old.notes ? new.notes : nil, details: details)
        return .change(intent) { [store, new] in
            try await Self.unchanged(old, in: store)
            return Self.said("Changed", try await store.save(new))
        }
    }

    /// `id`.
    private func deleteEvent(_ args: AgentKit.JSONValue) async throws -> Plan {
        let old = try await event(args)
        let name = ChatData.clean(old.title, max: Self.maxTitle)
        let intent = ToolIntent(action: "Delete \u{201C}\(name)\u{201D} from your calendar",
                                details: [Self.when(old), "Calendar: \(ChatData.clean(old.calendar, max: ChatData.maxName))"])
        return .change(intent) { [store] in
            try await Self.unchanged(old, in: store)
            try await store.deleteEvent(id: old.id)
            return Self.said("Deleted", old)
        }
    }

    /// `title`, `due?`, `list?`, `notes?`.
    private func createReminder(_ args: AgentKit.JSONValue, marker: URL) async throws -> Plan {
        let due = try SphinxTools.optional("due", in: args).map { _ in try Self.time("due", in: args) }
        let reminder = CalendarReminder(title: try Self.title(args), due: due?.date, dueIsDay: due?.day ?? false,
                                        list: try await calendarName(args, .reminders, key: "list"),
                                        notes: try Self.text("notes", in: args, max: Self.maxNotes), url: marker)
        if let made = try await store.reminders(includingDone: true).first(where: { $0.url == marker }) {
            return .answer(.done(Self.said("Added", made)))
        }
        let list = reminder.list.isEmpty ? "your default list" : ChatData.clean(reminder.list, max: ChatData.maxName)
        let details = [reminder.due.map { "Due \(Self.when($0, day: reminder.dueIsDay))" } ?? "No due time", "List: \(list)"]
        let intent = ToolIntent(action: "Add the reminder \u{201C}\(reminder.title)\u{201D}", content: reminder.notes, details: details)
        return .change(intent) { [store] in Self.said("Added", try await store.add(reminder)) }
    }

    /// `id`.
    private func completeReminder(_ args: AgentKit.JSONValue) async throws -> Plan {
        let id = try Self.id(args)
        guard let reminder = try await store.reminder(id: id) else { throw ToolFailure.noItem("reminder") }
        guard !reminder.done else { return .answer(.done(Self.said("Already done:", reminder))) }
        let name = ChatData.clean(reminder.title, max: Self.maxTitle)
        var details = ["List: \(ChatData.clean(reminder.list, max: ChatData.maxName))"]
        if let due = reminder.due { details.insert("Due \(Self.when(due, day: reminder.dueIsDay))", at: 0) }
        let intent = ToolIntent(action: "Mark \u{201C}\(name)\u{201D} done", details: details)
        return .change(intent) { [store] in Self.said("Marked done", try await store.complete(id: id)) }
    }

    /// Refuses when `event` is no longer as the card showed it: changed on
    /// the Mac while the card was up, which a save would overwrite.
    static func unchanged(_ event: CalendarEvent, in store: any CalendarStore) async throws {
        guard try await store.event(id: event.id) == event else {
            throw ToolFailure(errorDescription: "The event changed on the user's Mac while the card was up, so nothing was done. Read it again first.")
        }
    }

    private func event(_ args: AgentKit.JSONValue) async throws -> CalendarEvent {
        guard let event = try await store.event(id: try Self.id(args)) else { throw ToolFailure.noItem("event") }
        return event
    }

    /// The calendar (or list) named at `key`, one that can be written to; "" for the default.
    private func calendarName(_ args: AgentKit.JSONValue, _ entity: CalendarEntity, key: String = "calendar") async throws -> String {
        guard let name = SphinxTools.optional(key, in: args) else { return "" }
        let names = await store.calendars(entity)
        guard names.contains(name) else {
            let known = names.map { "\u{201C}\(ChatData.clean($0, max: ChatData.maxName))\u{201D}" }.joined(separator: ", ")
            throw ToolFailure(errorDescription: "There is no \(entity == .events ? "calendar" : "list") called "
                + "\u{201C}\(ChatData.clean(name, max: ChatData.maxName))\u{201D} that Peel can add to. There are: \(known).")
        }
        return name
    }

    // MARK: - Words

    /// The URL an event or reminder made for `request` carries, so the same
    /// request asked again finds it rather than making a second.
    static func marker(_ request: DeviceRequest) -> URL {
        let hash = SHA256.hash(data: Data("\(request.agent)\n\(request.id)".utf8)).prefix(16).hex
        return URL(string: "peel-agent-request:\(hash)")!
    }

    /// What the model reads of one event: its times (the Mac's local time), id, calendar, title and place.
    static func describe(_ event: CalendarEvent) -> String {
        let when = event.allDay ? "\(stamp(event.start, day: true)) all day" : "\(stamp(event.start)) to \(stamp(event.end))"
        var line = "\(when) (id=\(ChatData.clean(event.id, max: maxID))) [\(ChatData.clean(event.calendar, max: ChatData.maxName))]: "
            + ChatData.clean(event.title, max: ChatData.maxText)
        if let location = event.location, !location.isEmpty { line += " · at \(ChatData.clean(location, max: ChatData.maxText))" }
        return line
    }

    static func describe(_ reminder: CalendarReminder) -> String {
        let due = reminder.due.map { "due \(stamp($0, day: reminder.dueIsDay))" } ?? "no due time"
        return "\(reminder.done ? "[done] " : "")\(due) (id=\(ChatData.clean(reminder.id, max: maxID))) "
            + "[\(ChatData.clean(reminder.list, max: ChatData.maxName))]: \(ChatData.clean(reminder.title, max: ChatData.maxText))"
    }

    static func line(_ event: CalendarEvent) -> String { "- " + describe(event) }
    static func line(_ reminder: CalendarReminder) -> String { "- " + describe(reminder) }

    /// What a change did, as the model reads it: the item between the
    /// markers, since its title may be someone else's words (an invitation).
    static func said(_ verb: String, _ event: CalendarEvent) -> String {
        said("\(verb) this event on the user's calendar:", describe(event))
    }

    static func said(_ verb: String, _ reminder: CalendarReminder) -> String {
        said("\(verb) this reminder:", describe(reminder))
    }

    private static func said(_ header: String, _ line: String) -> String {
        var data = ChatData(header)
        data.add(line)
        return data.text
    }

    /// When an event is, for the card: "Thu 29 Oct, 14:00–15:00".
    static func when(_ event: CalendarEvent) -> String {
        let day = Date.FormatStyle().weekday(.abbreviated).day().month(.abbreviated)
        if event.allDay {
            let last = event.end.addingTimeInterval(-1)
            return Calendar.current.isDate(event.start, inSameDayAs: last)
                ? "\(event.start.formatted(day)), all day" : "\(event.start.formatted(day)) to \(last.formatted(day)), all day"
        }
        let time = Date.FormatStyle().hour().minute()
        return Calendar.current.isDate(event.start, inSameDayAs: event.end)
            ? "\(event.start.formatted(day)), \(event.start.formatted(time))–\(event.end.formatted(time))"
            : "\(event.start.formatted(day)) \(event.start.formatted(time)) to \(event.end.formatted(day)) \(event.end.formatted(time))"
    }

    /// "Thu 29 Oct at 17:00", or "Thu 29 Oct" for a `day`.
    static func when(_ date: Date, day: Bool = false) -> String {
        let words = date.formatted(Date.FormatStyle().weekday(.abbreviated).day().month(.abbreviated))
        return day ? words : "\(words) at \(date.formatted(date: .omitted, time: .shortened))"
    }

    /// Local time on the Mac, ISO 8601 with no offset, as the model reads and
    /// writes times: an offset worked out from today's would be wrong across
    /// a change of the clocks.
    static func stamp(_ date: Date, day: Bool = false) -> String {
        date.formatted(day ? localDay : localTime)
    }

    // Computed: the Mac's zone as it is now.
    private static var localDay: Date.ISO8601FormatStyle { Date.ISO8601FormatStyle(timeZone: .current).year().month().day() }
    private static var localTime: Date.ISO8601FormatStyle { localDay.dateTimeSeparator(.standard).time(includingFractionalSeconds: false) }

    // MARK: - Arguments

    /// A time the agent gave: local time on the Mac (with or without
    /// seconds), ISO 8601 with an offset, or a date alone (`day`, its start).
    static func time(_ text: String) -> (date: Date, day: Bool)? {
        // To the minute, with or without an offset: the seconds put in.
        let full = text.replacing(/^(\d{4}-\d\d-\d\dT\d\d:\d\d)(?=$|Z|[+-]\d)/) { "\($0.1):00" }
        // With an offset (or Z): the full style, which reads it (a narrower one takes the time as UTC).
        if let date = try? Date(full, strategy: .iso8601) { return (date, false) }
        if let date = try? localTime.parse(full) { return (date, false) }
        if let date = try? localDay.parse(text) { return (date, true) }
        return nil
    }

    static func time(_ key: String, in args: AgentKit.JSONValue) throws -> (date: Date, day: Bool) {
        guard let text = SphinxTools.optional(key, in: args) else { throw ToolFailure(errorDescription: "\(key) is required") }
        guard let time = time(text) else {
            throw ToolFailure(errorDescription: "\(key) must be local time such as 2026-10-29T17:00, or a date such as 2026-10-29")
        }
        return time
    }

    static func optionalTime(_ key: String, in args: AgentKit.JSONValue) throws -> Date? {
        SphinxTools.optional(key, in: args) == nil ? nil : try time(key, in: args).date
    }

    /// The start of the day after `date`'s: the end of an all-day event that day.
    static func nextDay(_ date: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: date)) ?? date.addingTimeInterval(86400)
    }

    static func id(_ args: AgentKit.JSONValue) throws -> String {
        guard let id = SphinxTools.optional("id", in: args), id.count <= maxID else {
            throw ToolFailure(errorDescription: "id is required: an id from a list result")
        }
        return id
    }

    /// The title, shown on the card as it is: one showable line.
    static func title(_ args: AgentKit.JSONValue) throws -> String {
        guard let title = try text("title", in: args, max: maxTitle), !title.contains(where: \.isNewline) else {
            throw ToolFailure(errorDescription: "title is required: one line of at most \(maxTitle) characters")
        }
        return title
    }

    /// Text for the card, shown in full: nil when left out.
    static func text(_ key: String, in args: AgentKit.JSONValue, max: Int) throws -> String? {
        guard let text = SphinxTools.optional(key, in: args) else { return nil }
        guard text.count <= max, ToolIntent.isShowable(text) else {
            throw ToolFailure(errorDescription: "\(key) must be showable text of at most \(max) characters")
        }
        return text
    }
}
