import Foundation
import Observation

/// One message of the agent chat as it is shown: the person's, or the
/// agent's reply with the tools it ran on the way.
public struct AgentTurn: Identifiable, Sendable, Equatable {
    public enum Author: String, Sendable { case user, agent }

    /// How an agent's reply ended, when not on its own.
    public enum Ending: String, Sendable {
        case stopped
        /// The reply reached its length limit.
        case cutOff = "cut_off"
        /// The provider declined to answer; left out of what the model sees.
        case declined
        /// The turn ran out of steps.
        case stepLimit = "step_limit"
        /// The provider failed after an action had run: kept, so asking
        /// again is the person's choice, never a Retry that acts twice.
        case failed
    }

    public internal(set) var id: String
    public var author: Author
    public var text: String
    public var date: Date
    /// The tools an agent's reply ran, in order, shown above its text.
    public var tools: [ToolActivity] = []
    public var ending: Ending?

    public init(id: String, author: Author, text: String, date: Date, tools: [ToolActivity] = [], ending: Ending? = nil) {
        self.id = id
        self.author = author
        self.text = text
        self.date = date
        self.tools = tools
        self.ending = ending
    }
}

/// A tool the agent ran, as a quiet row: what it was, how long it took,
/// and what it was asked and answered, for when the row is opened.
public struct ToolActivity: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let input: JSONValue
    /// The first line of what it returned; nil while it runs.
    public var summary: String?
    public var duration: Duration?
    public var failed = false
    /// For a tool that acts: what it asked to do and how the person answered.
    public var approval: ToolApproval?

    public init(id: String, name: String, input: JSONValue, summary: String? = nil, duration: Duration? = nil,
                failed: Bool = false, approval: ToolApproval? = nil) {
        self.id = id
        self.name = name
        self.input = input
        self.summary = summary
        self.duration = duration
        self.failed = failed
        self.approval = approval
    }

    public var isRunning: Bool { duration == nil }

    /// Waiting on the person: its card is up.
    public var isWaiting: Bool { approval != nil && approval?.outcome == nil && isRunning }
}

/// A tool call that needed approval: what it would do, and the answer
/// (nil while its card waits).
public struct ToolApproval: Sendable, Equatable, Codable {
    public var intent: ToolIntent
    public var outcome: ApprovalOutcome?

    public init(intent: ToolIntent, outcome: ApprovalOutcome? = nil) {
        self.intent = intent
        self.outcome = outcome
    }
}

/// The agent chat: one long conversation with the connected model, kept in
/// the account's agent store, and the reply streaming now. Views read it and
/// call its actions; nothing about a turn lives in a view.
///
/// Each message is a `Turn` record linked from one `Conversation` record
/// (`created_by` user or agent, an agent's `source` the turn it answers),
/// so the conversation survives a restart and moves to the graph as it is.
/// The key is read from `credentials` for each turn and never kept here.
@MainActor @Observable
public final class AgentSession {
    /// Why a turn got no reply: no model connected, or the provider's error.
    public enum Failure: Sendable, Equatable {
        case noModel
        /// The key could not be read (the Keychain refused): Retry, not Connect.
        case unreadableKey(String)
        case model(ModelError)

        /// The key was refused: Replace key rather than Retry.
        public var isKeyRefused: Bool {
            if case .model(.invalidKey) = self { true } else { false }
        }
    }

    /// The last turn's failure, under the message that got no reply.
    public struct Problem: Sendable, Equatable {
        public let turnID: String
        public let failure: Failure
    }

    /// A model call made again on its own: how long it waits (`.zero` once
    /// it goes), and why.
    public struct Retrying: Sendable, Equatable {
        public let after: Duration
        public let reason: ModelError
    }

    /// The connected model as screens show it: no key, only its last four.
    public struct Connection: Sendable, Equatable {
        public let provider: AgentProvider
        public let model: String
        public let keyHint: String
    }

    /// The conversation as shown, oldest first, without the reply in progress.
    public private(set) var turns: [AgentTurn] = []
    /// The reply streaming now.
    public private(set) var reply: AgentTurn?
    /// The reply's model call failed and is made again on its own after a
    /// wait; nil once anything else happens.
    public private(set) var retrying: Retrying?
    public private(set) var problem: Problem?
    public private(set) var connection: Connection?
    /// What the agent is called in the sidebar, its header and its messages.
    public private(set) var name = AgentSession.defaultName
    /// A failure to save or read the conversation, said once in the chat.
    public var notice: String?
    /// Replies and failures that came while the chat was not on screen.
    public private(set) var unread = 0
    /// Whether the chat is on screen; set by its view. Showing it reads it.
    public var isShown = false {
        didSet { if isShown { unread = 0 } }
    }

    public var isRunning: Bool { running != nil }

    /// The tool call whose card waits on the person, if any.
    public private(set) var waiting: ApprovalRequest?
    /// The account's remembered "Always allow" rules, for Account to list.
    public private(set) var approvalRules: [ApprovalRule] = []

    public static let defaultName = "Peel"

    /// The tools the agent may use; registering one is a line in the app.
    public var tools: ToolRegistry
    public var systemPrompt: String

    private let store: any AgentStore
    private let rules: ApprovalRules
    /// Answers the card that waits (`waiting`).
    @ObservationIgnored private var answering: CheckedContinuation<ApprovalDecision, Never>?
    /// The person's last answer, to tell an "Always" that could not be kept.
    @ObservationIgnored private var lastAnswer: ApprovalDecision?
    private let credentials: any AgentCredentialStore
    private let makeClient: @Sendable (AgentCredential) -> any ModelProvider
    private var conversationID: String?
    /// What the model is sent as the conversation so far: whole turns,
    /// rebuilt from the records at launch.
    private var history: [ModelMessage] = []
    private var running: Task<Void, Never>?
    /// When a failed model call is made again on its own (tests turn it off).
    @ObservationIgnored var retryPolicy = RetryPolicy()
    /// Streamed text not yet shown: deltas are shown at most every 50 ms,
    /// so a fast stream redraws and re-reads its Markdown a few times a
    /// second rather than once a token.
    /// Closed with its account: nothing more is run or kept.
    @ObservationIgnored private var closed = false
    /// A tool ran after some text: the next words start a paragraph.
    @ObservationIgnored private var paragraphDue = false
    @ObservationIgnored private var pendingText = ""
    @ObservationIgnored private var flushing: Task<Void, Never>?
    /// The run whose events and end are taken; one left behind by Clear is not.
    private var runID: UUID?

    /// Opens the conversation in `store`. `makeClient` builds the provider's
    /// client for a credential (the app's; a fake in tests).
    public init(
        store: any AgentStore, credentials: any AgentCredentialStore, tools: ToolRegistry, systemPrompt: String,
        makeClient: @escaping @Sendable (AgentCredential) -> any ModelProvider = {
            $0.provider.client(apiKey: $0.apiKey)
        }
    ) {
        self.store = store
        rules = ApprovalRules(store: store)
        self.credentials = credentials
        self.tools = tools
        self.systemPrompt = systemPrompt
        self.makeClient = makeClient
        load()
    }

    private func load() {
        do {
            connection = try credentials.read().map(Connection.init)
        } catch {
            notice = "Could not read the connected model's key: \(error.localizedDescription)"
        }
        do {
            approvalRules = try rules.all()
        } catch {
            notice = [notice, "Could not read what the agent is always allowed to do: \(error.localizedDescription)"]
                .compactMap { $0 }.joined(separator: " ")
        }
        do {
            name = try store.records(type: RecordType.agent, limit: 1).first?.name ?? Self.defaultName
            guard let conversation = try store.records(type: RecordType.conversation, limit: 1).first else { return }
            conversationID = conversation.refId
            turns = try store.walk(conversation.refId, edgeTypes: [LinkType.turn], direction: .outgoing, depth: 1,
                                   limit: Int.max).map { step in
                var turn = AgentTurn(record: step.record)
                if turn.author == .agent { turn.tools = try toolCalls(of: turn.id).map(ToolActivity.init(record:)) }
                return turn
            }
            history = Self.history(of: turns)
        } catch {
            notice = "Could not read the agent chat: \(error.localizedDescription)"
        }
    }

    // MARK: Turns

    /// Sends a message and streams the reply. Nothing while a reply runs.
    public func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning, !closed else { return }
        problem = nil
        let turn = save(AgentTurn(id: UUID().uuidString.lowercased(), author: .user, text: text, date: .now), answering: nil)
        turns.append(turn)
        run(answering: turn)
    }

    /// Asks again for the message whose reply failed.
    public func retry() {
        guard let problem, !isRunning, !closed, let turn = turns.first(where: { $0.id == problem.turnID }) else { return }
        self.problem = nil
        run(answering: turn)
    }

    /// Stops the reply in progress; what arrived is kept, marked Stopped.
    public func stop() {
        running?.cancel()
    }

    private func run(answering turn: AgentTurn) {
        let credential: AgentCredential?
        do {
            credential = try credentials.read()
        } catch {
            problem = Problem(turnID: turn.id, failure: .unreadableKey(error.localizedDescription))
            return
        }
        guard let credential else {
            connection = nil
            problem = Problem(turnID: turn.id, failure: .noModel)
            return
        }
        var loop = AgentLoop(provider: makeClient(credential), tools: tools, model: credential.model, systemPrompt: systemPrompt)
        loop.retry = retryPolicy
        let earlier = history
        let id = UUID()
        runID = id
        loop.approver = RunApprover(session: self, run: id)
        reply = AgentTurn(id: UUID().uuidString.lowercased(), author: .agent, text: "", date: .now)
        paragraphDue = false
        // Holds the session until the turn ends, which Stop makes prompt.
        running = Task {
            let result = await loop.run(history: earlier, message: turn.text) { event in
                await self.apply(event, run: id)
            }
            finish(result, answering: turn, run: id)
        }
    }

    private func apply(_ event: LoopEvent, run: UUID) {
        guard runID == run else { return }
        if case .retrying(let delay, let reason) = event {
            retrying = Retrying(after: delay, reason: reason)
            return
        }
        // Only when set: clearing it on every delta would redraw the reply each token.
        if retrying != nil { retrying = nil }
        if case .textDelta(let text) = event {
            // The model's words after a tool ran start a paragraph of their
            // own: "Let me look." and "You have 3 unread." never run together.
            if paragraphDue {
                pendingText += "\n\n"
                paragraphDue = false
            }
            pendingText += text
            flushing = flushing ?? Task {
                try? await Task.sleep(for: .milliseconds(50))
                if !Task.isCancelled, runID == run { showPendingText() }
            }
            return
        }
        showPendingText()
        switch event {
        case .textDelta, .retrying:
            break
        case .toolStarted(let id, let name, let input):
            paragraphDue = reply?.text.isEmpty == false
            reply?.tools.append(ToolActivity(id: id, name: name, input: input))
        case .toolFinished(let id, _, let summary, let duration, let failed):
            updateTool(id) {
                $0.summary = summary
                $0.duration = duration
                $0.failed = failed
            }
        }
    }

    /// The text streamed since it was last shown.
    private func showPendingText() {
        flushing?.cancel()
        flushing = nil
        guard !pendingText.isEmpty else { return }
        reply?.text += pendingText
        pendingText = ""
    }

    private func finish(_ result: TurnResult, answering turn: AgentTurn, run: UUID) {
        guard runID == run else { return }
        showPendingText()
        guard var shown = reply else { return }
        running = nil
        runID = nil
        reply = nil
        retrying = nil
        let ending: AgentTurn.Ending?
        switch result.outcome {
        case .failed(let error):
            // Once an action ran, Retry could do it again: the reply is kept,
            // with what ran, and ends there.
            guard shown.tools.contains(where: { $0.approval?.outcome?.allows == true }) else {
                // Nothing else is kept: Retry asks the same message again.
                problem = Problem(turnID: turn.id, failure: .model(error))
                if !isShown { unread += 1 }
                return
            }
            ending = .failed
        case .finished(.endTurn), .finished(.toolUse), .finished(.other): ending = nil
        case .finished(.maxTokens): ending = .cutOff
        case .finished(.refusal): ending = .declined
        case .stepLimit: ending = .stepLimit
        case .stopped: ending = .stopped
        }
        // A tool still marked running was stopped under it.
        for index in shown.tools.indices where shown.tools[index].isRunning {
            shown.tools[index].duration = .zero
            shown.tools[index].failed = true
        }
        shown.ending = ending
        shown.date = .now
        guard !shown.text.isEmpty || !shown.tools.isEmpty || ending != nil else {
            // Nothing came back: say so, with Retry, rather than leave the
            // message unanswered.
            problem = Problem(turnID: turn.id, failure: .model(.malformed("an empty reply")))
            if !isShown { unread += 1 }
            return
        }
        turns.append(save(shown, answering: turn.id))
        // What the model sees next is what a relaunch rebuilds: each message
        // and the words that answered it. Tool results are left out (they
        // are copies of chats Peel keeps); a reply that needs one names it.
        history = Self.history(of: turns)
        if !isShown { unread += 1 }
    }

    // MARK: Approvals

    /// Answers the card that waits: Return is Allow once, Escape Deny.
    public func answer(_ decision: ApprovalDecision) {
        guard let answering else { return }
        lastAnswer = decision
        self.answering = nil
        waiting = nil
        answering.resume(returning: decision)
    }

    /// Forgets an "Always allow": that tool asks again for that target.
    public func revoke(_ rule: ApprovalRule) throws {
        try rules.revoke(rule)
        approvalRules = try rules.all()
    }

    /// What the loop asks before a tool that acts: a rule, or the card.
    /// The tool's row shows the card while it waits, then the outcome.
    /// Only for `run`, the reply in progress: one that Clear or Stop left
    /// behind asks nothing and changes no row.
    fileprivate func approveShown(_ request: ApprovalRequest, run: UUID) async -> ApprovalOutcome {
        guard runID == run else { return .stopped }
        let gate = ApprovalGate(rules: rules) { [weak self] request in await self?.ask(request, run: run) ?? .deny }
        lastAnswer = nil
        var outcome = await gate.approve(request)
        guard runID == run else { return .stopped }
        // Allowed, then stopped before it ran: the row says so, not "allowed".
        if Task.isCancelled { outcome = .stopped }
        updateTool(request.callID) { $0.approval = ToolApproval(intent: request.intent, outcome: outcome) }
        if outcome == .alwaysAllowed { approvalRules = (try? rules.all()) ?? approvalRules }
        if outcome == .allowedOnce, lastAnswer == .alwaysAllow {
            notice = "Could not remember \"\(request.intent.alwaysLabel)\"; it was allowed this once."
        }
        return outcome
    }

    /// Puts the card up and waits for `answer`; Stop (the task cancelled)
    /// takes it down as a Deny, which the gate reads as stopped.
    private func ask(_ request: ApprovalRequest, run: UUID) async -> ApprovalDecision {
        guard !closed, !Task.isCancelled, runID == run, answering == nil else { return .deny }
        updateTool(request.callID) { $0.approval = ToolApproval(intent: request.intent) }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                answering = continuation
                waiting = request
            }
        } onCancel: {
            // Only this run's card: by the time this runs another may be up.
            Task { @MainActor in if self.runID == run, self.waiting == request { self.answer(.deny) } }
        }
    }

    /// Changes the reply's newest running tool with `id`: ids can repeat
    /// across a reply's steps (an OpenAI-compatible provider that numbers
    /// its calls).
    private func updateTool(_ id: String, _ change: (inout ToolActivity) -> Void) {
        guard let index = reply?.tools.lastIndex(where: { $0.id == id && $0.isRunning }) else { return }
        change(&reply!.tools[index])
    }

    // MARK: Connecting

    /// Checks `credential` with one small call, then keeps it in the
    /// Keychain. Throws the provider's failure (`ModelError`) or the
    /// Keychain's; nothing is kept then.
    public func connect(_ credential: AgentCredential) async throws {
        try await Self.check(makeClient(credential), model: credential.model)
        // Cancelled (the panel closed) or the account closed while it checked: keep nothing.
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        try credentials.write(credential)
        connection = Connection(credential)
        if problem?.failure == .noModel || problem?.failure.isKeyRefused == true {
            // Connected now: the message waiting can be asked again.
            retry()
        }
    }

    /// Changes the model the connected key uses; the next turn uses it.
    public func setModel(_ model: String) throws {
        guard var credential = try credentials.read() else { return }
        credential.model = model
        try credentials.write(credential)
        connection = Connection(credential)
    }

    /// Removes the key from this device. The agent stops until connected again.
    public func removeKey() throws {
        stop()
        try credentials.delete()
        connection = nil
    }

    /// One small call: the provider answering at all means the key, the
    /// model and the network work. Stops reading at the first event.
    static func check(_ client: any ModelProvider, model: String) async throws {
        let request = ModelRequest(model: model, system: "", messages: [.user("Reply with OK.")], maxTokens: 256)
        do {
            for try await _ in client.stream(request) { return }
        } catch {
            throw ModelError(error)
        }
    }

    // MARK: The conversation

    /// Forgets every message of the conversation; the next starts a new one.
    public func clear() throws {
        endRun()
        // The conversation first: once it is forgotten nothing reads its
        // turns, so a failure part way leaves no old chat to come back.
        if let conversationID { try store.forget(conversationID, reason: "cleared") }
        let ids = turns.map(\.id)
        conversationID = nil
        turns = []
        history = []
        problem = nil
        for id in ids {
            for call in try toolCalls(of: id) { try store.forget(call.refId, reason: "cleared") }
            try store.forget(id, reason: "cleared")
        }
    }

    /// The account is closing: the reply in progress ends and nothing more
    /// is run or kept, a connect still checking its key included.
    public func close() {
        closed = true
        endRun()
    }

    /// Ends the reply in progress and lets go of it, keeping nothing of it.
    private func endRun() {
        running?.cancel()
        answer(.deny)
        running = nil
        runID = nil
        reply = nil
        retrying = nil
        flushing?.cancel()
        flushing = nil
        pendingText = ""
    }

    /// Renames the agent; an empty name is refused.
    public func rename(_ newName: String) throws {
        let newName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != name else { return }
        if let agent = try store.records(type: RecordType.agent, limit: 1).first {
            try store.update(agent.refId, name: newName)
        } else {
            try store.add(type: RecordType.agent, name: newName, createdBy: AgentTurn.Author.user.rawValue)
        }
        name = newName
    }

    // MARK: Records

    enum RecordType {
        static let agent = "Agent"
        static let conversation = "Conversation"
        static let turn = "Turn"
        static let toolCall = "ToolCall"
    }

    enum LinkType {
        static let turn = "turn"
        static let toolCall = "tool_call"
    }

    /// The tool calls a reply made, in the order they ran.
    private func toolCalls(of turn: String) throws -> [Record] {
        try store.walk(turn, edgeTypes: [LinkType.toolCall], direction: .outgoing, depth: 1, limit: Int.max)
            .map(\.record)
            .sorted { ($0.props["index"].flatMap(\.int) ?? 0) < ($1.props["index"].flatMap(\.int) ?? 0) }
    }

    /// Writes `turn` as a record linked from the conversation, made on the
    /// first turn; returns it with the record's id. A failure is said in the
    /// chat and the turn still shows.
    private func save(_ turn: AgentTurn, answering source: String?) -> AgentTurn {
        do {
            let conversation = try conversationID ?? store.add(
                type: RecordType.conversation, name: name, createdBy: AgentTurn.Author.user.rawValue)
            conversationID = conversation
            let author = turn.author.rawValue
            let id = try store.add(type: RecordType.turn, name: String(turn.text.prefix(80)), body: turn.text,
                                   props: turn.props, createdBy: author, source: source)
            try store.link(conversation, LinkType.turn, id, createdBy: author)
            // Each tool call its own record, pointing at the reply that made it.
            for (index, tool) in turn.tools.enumerated() {
                var props = tool.props
                props["index"] = .number(Double(index))
                let call = try store.add(type: RecordType.toolCall, name: tool.name, body: tool.summary,
                                         props: props, createdBy: author, source: id)
                try store.link(id, LinkType.toolCall, call, createdBy: author)
            }
            var saved = turn
            saved.id = id
            return saved
        } catch {
            notice = "Could not save the agent chat: \(error.localizedDescription)"
            return turn
        }
    }

    /// What the model sees of `turns`: each message and the reply to it,
    /// without replies that are empty or were declined.
    static func history(of turns: [AgentTurn]) -> [ModelMessage] {
        var history: [ModelMessage] = []
        var asked: AgentTurn?
        for turn in turns {
            switch turn.author {
            case .user:
                asked = turn
            case .agent:
                guard let question = asked, !turn.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      turn.ending != .declined else { continue }
                history += [.user(question.text), ModelMessage(role: .assistant, content: [.text(turn.text)])]
                asked = nil
            }
        }
        return history
    }
}

/// The approver one run of the session's loop asks: the card in its reply.
private struct RunApprover: ToolApprover {
    let session: AgentSession
    let run: UUID

    func approve(_ request: ApprovalRequest) async -> ApprovalOutcome {
        await session.approveShown(request, run: run)
    }
}

extension AgentSession.Connection {
    init(_ credential: AgentCredential) {
        self.init(provider: credential.provider, model: credential.model, keyHint: credential.keyHint)
    }
}

// MARK: - Turns as records

extension AgentTurn {
    init(record: Record) {
        let props = JSONValue.object(record.props)
        self.init(
            id: record.refId,
            author: record.createdBy == Author.agent.rawValue ? .agent : .user,
            text: record.body ?? "",
            date: Date(timeIntervalSince1970: Double(record.createdMs) / 1000),
            ending: props["ending"]?.string.flatMap(Ending.init(rawValue:)))
    }

    var props: [String: JSONValue] {
        var props: [String: JSONValue] = [:]
        if let ending { props["ending"] = .string(ending.rawValue) }
        return props
    }
}

extension ToolActivity {
    /// A `ToolCall` record: the tool's name, the summary of its result as
    /// the body, what it was asked, how long it took and whether it failed.
    /// What it returned in full is not kept: it is a copy of chats Peel
    /// already stores.
    init(record: Record) {
        let props = JSONValue.object(record.props)
        let ms: Double? = if case .number(let ms)? = props["ms"] { ms } else { nil }
        self.init(id: props["call_id"]?.string ?? record.refId, name: record.name, input: props["input"] ?? .object([:]),
                  summary: record.body, duration: .milliseconds(Int64(ms ?? 0)), failed: props["failed"] == .bool(true),
                  approval: props["approval"].flatMap { try? $0.decoded(as: ToolApproval.self) })
    }

    var props: [String: JSONValue] {
        var props: [String: JSONValue] = ["call_id": .string(id), "input": input, "failed": .bool(failed)]
        if let duration { props["ms"] = .number((duration / .milliseconds(1)).rounded()) }
        if let approval, let json = try? JSONValue(encoding: approval) { props["approval"] = json }
        return props
    }
}
