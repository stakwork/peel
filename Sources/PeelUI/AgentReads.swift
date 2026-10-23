import Foundation
import PeelCore

/// One read folded into a row of the agent's DM (`ChatRow.agentReads`):
/// its message, which a jump and the list's newest still find, and how it went.
public struct AgentRead: Equatable, Sendable {
    public let message: Message
    public let request: AgentRequest
}

/// Reads the agent asked this Mac for back to back, done or on their way, as one line
/// that opens into steps: "Checked unread messages, 4 chats and threads",
/// then a step per kind of read in the order first asked.
public struct AgentReads: Equatable, Sendable {
    /// The most time between two reads of one row: one look around the
    /// chats asks every few seconds, a scheduled run's next look is hours on.
    public static let gap: TimeInterval = 2 * 60

    /// The kinds of read that fold; a send, an approval or a change to your
    /// calendar always has its own row.
    public enum Kind: Equatable, Sendable {
        case unseen, chats, chat, threads, search, calendar

        public init?(_ kind: String) {
            switch kind {
            case "chats.unseen": self = .unseen
            case "chats.list": self = .chats
            case "chats.read": self = .chat
            case "chats.threads": self = .threads
            case "chats.search": self = .search
            case "calendar.events": self = .calendar
            default: return nil
            }
        }
    }

    /// The reads of one kind: "Read 4 chats", and the chats or searches it
    /// named, as the agent asked for them, each once.
    public struct Step: Equatable, Sendable {
        public let kind: Kind
        public var requests: [AgentRequest]
        public var subjects: [String]

        /// What it read, after "Read": "4 chats", "threads in 2 chats"; nil for a search.
        var object: String? {
            let count = max(subjects.count, 1)
            switch kind {
            case .unseen: return "your unread messages"
            case .chats: return "your chats"
            case .chat: return count == 1 ? "a chat" : "\(count) chats"
            case .threads: return count == 1 ? "threads in a chat" : "threads in \(count) chats"
            case .calendar: return "your calendar"
            case .search: return nil
            }
        }

        /// Every read of it answered.
        public var done: Bool { requests.allSatisfy { $0.status == .done } }

        public var title: String {
            guard let object else {
                return requests.count == 1 ? "Searched your messages" : "Searched your messages \(requests.count) times"
            }
            return "Read " + object
        }
    }

    public let steps: [Step]
    /// From the first read asked to the last.
    public let span: TimeInterval

    public init(_ reads: [AgentRead]) {
        var steps: [Step] = []
        for read in reads {
            guard let kind = Kind(read.request.kind) else { continue }
            let subject = Self.subject(of: read.request, kind: kind)
            if let index = steps.firstIndex(where: { $0.kind == kind }) {
                steps[index].requests.append(read.request)
                if let subject, !steps[index].subjects.contains(subject) { steps[index].subjects.append(subject) }
            } else {
                steps.append(Step(kind: kind, requests: [read.request], subjects: subject.map { [$0] } ?? []))
            }
        }
        self.steps = steps
        span = (reads.last?.message.date).map { $0.timeIntervalSince(reads[0].message.date) } ?? 0
    }

    /// The row's line, short enough for one: "Checked unread messages, 2
    /// chats, threads and a search". Reading the list of chats, which every
    /// look starts with, is left to the steps unless it is all there was.
    public var summary: String {
        let items = steps.compactMap { step -> String? in
            let count = step.requests.count, chats = max(step.subjects.count, 1)
            switch step.kind {
            case .unseen: return "unread messages"
            case .chats: return steps.count == 1 ? "your chats" : nil
            case .chat: return chats == 1 ? "a chat" : "\(chats) chats"
            case .threads: return "threads"
            case .search: return count == 1 ? "a search" : "\(count) searches"
            case .calendar: return "your calendar"
            }
        }
        // In English as the rest of the row, whatever the Mac's language.
        let list = items.count < 2 ? items.joined() : items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        return "Checked " + list
    }

    /// The first read not yet answered, whose outcome the line shows in
    /// place of its tick ("on your Mac…", then too late at its expiry).
    public var waiting: AgentRequest? {
        steps.lazy.flatMap(\.requests).first { $0.status == nil }
    }

    /// What a read named: the chat it read (a name or a chat id, as the
    /// agent wrote it), a search's words in quotes; nil when it named none.
    static func subject(of request: AgentRequest, kind: Kind) -> String? {
        guard case .object(let args)? = request.args else { return nil }
        switch kind {
        case .chat, .threads, .unseen:
            if case .string(let chat)? = args["chat"], !chat.isEmpty { return chat }
        case .search:
            if case .string(let words)? = args["q"], !words.isEmpty { return "“\(words)”" }
        case .chats, .calendar:
            break
        }
        return nil
    }
}
