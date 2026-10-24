#if os(macOS)
import AgentKit
import Foundation
import PeelAgent
import PeelUI
import Synchronization

/// Offscreen only: an agent chat with an earlier conversation of its own,
/// for the driver's `agent` steps (`OffscreenDriver`). It is kept in memory
/// (never the profile's `agent.sqlite`), and its key is a placeholder no
/// provider would take.
@MainActor enum OffscreenAgent {
    /// The calendar a check's device requests reach: in memory, holding one
    /// event, "Dentist" next Thursday from 14:00 to 15:00.
    static func calendar() -> StandInCalendar {
        let thursday = Calendar.current.nextDate(after: .now, matching: DateComponents(hour: 14, weekday: 5), matchingPolicy: .nextTime) ?? .now
        return StandInCalendar(events: [CalendarEvent(id: "event-dentist", title: "Dentist", start: thursday,
                                                      end: thursday.addingTimeInterval(3600), calendar: "Calendar")])
    }

    /// A new agent session in place of the account's, holding `turns`
    /// questions and their answers: each answer a different length, every
    /// fourth after a tool row.
    static func session(turns: Int) throws -> AgentSession {
        let store = try SQLiteAgentStore.inMemory(device: "offscreen")
        // Each kept as it is written (its time the store's), as the loop kept them.
        try AgentSession.keep((1...max(turns, 1)).flatMap { n -> [AgentTurn] in
            let tools = n % 4 == 0
                ? [ToolActivity(id: "call-\(n)", name: "current_time", input: .object([:]), summary: "{\"local\":\"…\"}",
                                duration: .milliseconds(100))]
                : []
            return [
                AgentTurn(id: "", author: .user, text: n % 4 == 0 ? "Question \(n), with a tool" : "Question \(n)", date: .now),
                AgentTurn(id: "", author: .agent, text: words(20 + (n * 37) % 90, from: n * 2), date: .now,
                          tools: tools),
            ]
        }, in: store)
        return AgentSession(store: store, credentials: Credentials())
    }

    /// Only the placeholder, in memory.
    private final class Credentials: AgentCredentialStore {
        private let credential = Mutex<AgentCredential?>(
            AgentCredential(provider: .anthropic, model: "claude-sonnet-4-5", apiKey: "offscreen-script")
        )

        func read() throws -> AgentCredential? { credential.withLock { $0 } }
        func write(_ credential: AgentCredential) throws { self.credential.withLock { $0 = credential } }
        func delete() throws { credential.withLock { $0 = nil } }
    }

    private static let vocabulary = """
        the chat you asked about moved on since this morning and most of it is about the trip next week \
        Kate wants to leave early on Friday while Sam would rather wait for the weekend so the tickets are \
        cheaper and nobody has booked anything yet there were also two links to places to stay and a long \
        thread about who brings the tent
        """.split(separator: " ").map(String.init)

    /// `count` words of prose, a paragraph every 45; `seed` varies where it starts.
    static func words(_ count: Int, from seed: Int) -> String {
        (0..<count).map { index in
            let word = vocabulary[(seed * 7 + index) % vocabulary.count]
            if index == 0 { return word.prefix(1).uppercased() + word.dropFirst() }
            return (index % 45 == 0 ? ".\n\n" : index % 12 == 0 ? ". " : " ") + word
        }.joined() + "."
    }
}
#endif
