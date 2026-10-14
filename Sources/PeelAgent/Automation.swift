import AgentKit
import Foundation

/// A scheduled run strut hands to Peel (`docs/phases/12-automations.md`):
/// strut keeps the schedule and fires the `peel-automation` workflow, whose
/// one `http` step posts this to `POST /automations/run`.
public struct AutomationRequest: Sendable, Equatable, Codable {
    public var name: String
    /// What to do, in the person's words.
    public var prompt: String
    /// When the last successful run finished (ISO 8601); nil on the first.
    public var since: String?

    public init(name: String, prompt: String, since: String? = nil) {
        self.name = name
        self.prompt = prompt
        self.since = since
    }
}

/// How a run ended, as strut keeps it for the run's output.
public struct AutomationReply: Sendable, Equatable, Codable {
    public enum Status: String, Sendable, Codable {
        /// Something to say: `text` goes to the person.
        case delivered
        /// Nothing worth saying this time; the person sees nothing.
        case nothing
        /// The run did not finish; strut marks it an error.
        case failed
    }

    public var status: Status
    public var text: String?
    public var error: String?

    public init(status: Status, text: String? = nil, error: String? = nil) {
        self.status = status
        self.text = text
        self.error = error
    }

    public static func failed(_ error: String) -> Self { Self(status: .failed, error: error) }
}

/// One automation run: the agent's loop with no one watching. It is given
/// no approver, so a tool that asks (a send) is refused, and a read message
/// cannot steer it into acting for anyone.
public enum AutomationRun {
    /// The whole reply that means there is nothing to tell the person.
    public static let nothingToReport = "NOTHING_TO_REPORT"

    /// What the model is told of the run, as the turn's message.
    public static func instruction(for request: AutomationRequest, now: Date) -> String {
        let format = Date.ISO8601FormatStyle(timeZone: .current)
        let since = request.since.map { "The last run finished at \($0); \"new\" means since then." }
            ?? "This is its first run; \"new\" means the last 7 days."
        return """
            This is a scheduled automation, "\(request.name)", running on its own at \(now.formatted(format)). \
            No one is watching and no one can answer a question or approve an action. \(since) Peel keeps \
            each run's time for you, so keep nothing about the run itself in memory.

            Carry out the task below with the tools you have, then reply with exactly what the person should \
            be told: it is delivered to them as it is, so write it for them, not about the run. If there is \
            nothing worth telling them this time, reply with only \(nothingToReport). If a step would need \
            something you cannot do here, such as sending a message to someone, say what you would send \
            instead of doing it.

            Task: \(AutomationsClient.unescaped(request.prompt))
            """
    }

    /// The longest a run may take: inside strut's 10-minute `http` timeout,
    /// so a run strut has given up on is never delivered as well.
    public static let deadline: Duration = .seconds(540)

    /// Runs `request` once with `loop` and says what came of it; stopped,
    /// and failed, at `deadline`.
    public static func run(
        _ request: AutomationRequest, with loop: AgentLoop, now: Date = .now, deadline: Duration = deadline
    ) async -> AutomationReply {
        var unattended = loop
        unattended.approver = nil
        let run = unattended
        let message = instruction(for: request, now: now)
        return await withTaskGroup(of: AutomationReply?.self) { group in
            group.addTask { reply(to: await run.run(history: [], message: message)) }
            group.addTask {
                try? await Task.sleep(for: deadline)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? .failed("Stopped: the run took longer than \(Int(deadline / .seconds(60))) minutes.")
        }
    }

    static func reply(to result: TurnResult) -> AutomationReply {
        let text = result.messages.last { $0.role == .assistant }?.text
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch result.outcome {
        case .finished(.endTurn), .finished(.toolUse), .finished(.other):
            if text.isEmpty || text == nothingToReport { return AutomationReply(status: .nothing) }
            return AutomationReply(status: .delivered, text: text)
        case .finished(.maxTokens) where !text.isEmpty:
            // Cut off, but most of it is better than nothing.
            return AutomationReply(status: .delivered, text: text + "\n\n(Cut off at its length limit.)")
        default:
            return .failed(result.summary ?? "The run ended without a reply.")
        }
    }
}
