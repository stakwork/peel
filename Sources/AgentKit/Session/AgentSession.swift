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
    /// For a result a scheduled automation delivered on its own, its name.
    public var automation: String?

    public init(id: String, author: Author, text: String, date: Date, tools: [ToolActivity] = [], ending: Ending? = nil,
                automation: String? = nil) {
        self.id = id
        self.author = author
        self.text = text
        self.date = date
        self.tools = tools
        self.ending = ending
        self.automation = automation
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
    /// What it returned, kept for its row when the tool says so
    /// (`Tool.Output.kept`); nil for the rest.
    public var row: JSONValue?

    public init(id: String, name: String, input: JSONValue, summary: String? = nil, duration: Duration? = nil,
                failed: Bool = false, approval: ToolApproval? = nil, row: JSONValue? = nil) {
        self.id = id
        self.name = name
        self.input = input
        self.summary = summary
        self.duration = duration
        self.failed = failed
        self.approval = approval
        self.row = row
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

    /// A summary of the conversation up to a turn, which the model is sent
    /// in place of those turns (`Compaction`); they still show in full.
    public struct Summary: Sendable, Equatable {
        public let id: String
        public let text: String
        /// The last turn it covers.
        public let through: String
        public let date: Date
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
    /// The id each reply of this session streamed under, by the id its turn
    /// was saved as: a list keeps the reply's row as that turn.
    public private(set) var streamedAs: [String: String] = [:]
    /// The reply's model call failed and is made again on its own after a
    /// wait; nil once anything else happens.
    public private(set) var retrying: Retrying?
    public private(set) var problem: Problem?
    /// The latest summary of earlier turns, if the conversation has grown
    /// long enough for one.
    public private(set) var summary: Summary?
    public private(set) var connection: Connection? {
        didSet { credentialChanged?() }
    }
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
    /// Called before each reply is asked for (a send or a retry), so the
    /// app can change `tools` and `systemPrompt` first.
    @ObservationIgnored public var willRun: (() -> Void)?
    /// Called whenever `connection` is set (a key or model kept, or the
    /// key gone), so the app can hand the change on.
    @ObservationIgnored public var credentialChanged: (() -> Void)?

    private let store: any AgentStore
    /// The "always" rules, which the device's send cards share (`DeviceActions`).
    public let rules: ApprovalRules
    /// Answers the card that waits (`waiting`).
    @ObservationIgnored private var answering: CheckedContinuation<ApprovalDecision, Never>?
    /// The person's last answer, to tell an "Always" that could not be kept.
    @ObservationIgnored private var lastAnswer: ApprovalDecision?
    private let credentials: any AgentCredentialStore
    private let makeClient: @Sendable (AgentCredential) -> any ModelProvider
    private var conversationID: String?
    private var running: Task<Void, Never>?
    /// When a failed model call is made again on its own (tests turn it off).
    @ObservationIgnored var retryPolicy = RetryPolicy()
    /// When older turns are summarised (tests make it small).
    @ObservationIgnored var compaction = Compaction()
    /// How many exchanges the model was sent when a summary last failed.
    /// No summary is tried before the model is sent this many exchanges:
    /// after one failed, a few more, so a model that cannot summarise is not
    /// sent a doomed call before every turn.
    @ObservationIgnored private var nextCompaction = 0
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
            // The newest summary whose last turn is still here.
            // Each summary reaches further than the one before it.
            let order = Dictionary(turns.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { a, _ in a })
            summary = try summaries().compactMap(Summary.init(record:))
                .filter { order[$0.through] != nil }
                .max { order[$0.through]! < order[$1.through]! }
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

    /// A scheduled automation's result, arriving on its own
    /// (`docs/phases/12-automations.md`): kept as the agent's, named for the
    /// automation, and counted unread while the chat is not on screen. It
    /// answers no message, so a reply streaming now is not disturbed.
    public func deliver(_ text: String, from automation: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !closed else { return }
        let turn = AgentTurn(id: UUID().uuidString.lowercased(), author: .agent, text: text, date: .now,
                             automation: automation)
        turns.append(save(turn, answering: nil))
        if !isShown { unread += 1 }
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
        willRun?()
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
        // What the model sees: the summary, then each later message and the
        // words that answered it (what a relaunch rebuilds).
        let earlier = Self.exchanges(of: unsummarised)
        let id = UUID()
        runID = id
        loop.approver = RunApprover(session: self, run: id)
        reply = AgentTurn(id: UUID().uuidString.lowercased(), author: .agent, text: "", date: .now)
        paragraphDue = false
        // Holds the session until the turn ends, which Stop makes prompt.
        running = Task {
            loop.summary = summary?.text
            var history = earlier.flatMap(\.messages)
            // Before the turn, never in the middle of a reply.
            if earlier.count >= nextCompaction, compaction.isDue(summary: loop.summary, history: history),
               let (made, kept) = await compact(earlier, with: loop, run: id) {
                loop.summary = made
                history = kept.flatMap(\.messages)
            }
            let result = await loop.run(history: history, message: turn.text) { event in
                await self.apply(event, run: id)
            }
            finish(result, answering: turn, run: id)
        }
    }

    /// Summarises the older of `exchanges` into a new `summary`, kept as a
    /// record, and returns it with the recent exchanges kept word for word;
    /// nil when there is nothing old enough or the summary failed, and the
    /// model is then sent what it was before (the window keeps what fits).
    private func compact(
        _ exchanges: [Exchange], with loop: AgentLoop, run: UUID
    ) async -> (summary: String, kept: [Exchange])? {
        // Every exchange is a message and its reply, so a cut between two
        // is where the person typed.
        let cut = compaction.split(exchanges.map(\.messages))
        guard cut > 0 else { return nil }
        let through = exchanges[cut - 1].through
        let older = exchanges[..<cut]
        let text: String
        do {
            text = try await compaction.summarise(
                summary: loop.summary, older: older.flatMap(\.messages), provider: loop.provider, model: loop.model)
        } catch {
            if !(error is CancellationError) { nextCompaction = exchanges.count + 3 }
            return nil
        }
        // The turns it newly covers: from the last summary's end to `through`.
        let unsummarised = unsummarised
        guard runID == run, !closed else { return nil }
        guard let end = unsummarised.firstIndex(where: { $0.id == through }),
              let saved = saveSummary(text, through: through, covering: unsummarised[...end].map(\.id))
        else {
            // Not kept: a summary made only to be lost is not made again each turn.
            nextCompaction = exchanges.count + 3
            return nil
        }
        summary = saved
        nextCompaction = 0
        return (text, Array(exchanges[cut...]))
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
        case .toolFinished(let id, _, let summary, let row, let duration, let failed):
            updateTool(id) {
                $0.summary = summary
                $0.row = row
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
        // What the model sees next is this reply's words, not the tool
        // results (copies of chats Peel keeps); a reply that needs one names it.
        let saved = save(shown, answering: turn.id)
        streamedAs[saved.id] = shown.id
        turns.append(saved)
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

    /// Reads the rules again, after a card outside this chat remembered one.
    public func reloadRules() {
        approvalRules = (try? rules.all()) ?? approvalRules
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
        let kept = try summaries().map(\.refId)
        // The conversation first: once it is forgotten nothing reads its
        // turns, so a failure part way leaves no old chat to come back.
        if let conversationID { try store.forget(conversationID, reason: "cleared") }
        let ids = turns.map(\.id)
        conversationID = nil
        turns = []
        streamedAs = [:]
        summary = nil
        nextCompaction = 0
        problem = nil
        for id in kept { try store.forget(id, reason: "cleared") }
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
        static let summary = "Summary"
    }

    enum LinkType {
        static let turn = "turn"
        static let toolCall = "tool_call"
        static let summary = "summary"
        static let covers = "covers"
    }

    /// The conversation's summaries, the newest and those it replaced.
    private func summaries() throws -> [Record] {
        guard let conversationID else { return [] }
        return try store.walk(conversationID, edgeTypes: [LinkType.summary], direction: .outgoing, depth: 1,
                              limit: Int.max).map(\.record)
    }

    /// Keeps a summary as a `Summary` record linked from the conversation
    /// and to each turn it newly covers (and the summary it replaces).
    private func saveSummary(_ text: String, through: String, covering turnIDs: [String]) -> Summary? {
        guard let conversationID else { return nil }
        let author = AgentTurn.Author.agent.rawValue
        var id: String?
        do {
            let made = try store.add(type: RecordType.summary, name: "Summary of the earlier conversation", body: text,
                                     props: ["through": .string(through)], createdBy: author, source: through)
            id = made
            for covered in turnIDs + (summary.map { [$0.id] } ?? []) {
                try store.link(made, LinkType.covers, covered, createdBy: author)
            }
            // Last, so a relaunch never finds one half written.
            try store.link(conversationID, LinkType.summary, made, createdBy: author)
            return Summary(id: made, text: text, through: through, date: .now)
        } catch {
            if let id { try? store.forget(id, reason: "not saved whole") }
            notice = "Could not save the agent chat: \(error.localizedDescription)"
            return nil
        }
    }

    /// The turns after the summary, which the model is sent word for word.
    private var unsummarised: ArraySlice<AgentTurn> {
        guard let through = summary?.through, let index = turns.firstIndex(where: { $0.id == through }) else {
            return turns[...]
        }
        return turns[(index + 1)...]
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

    /// The app's record of the actions a reply asked to take and how each
    /// came out, under a fixed heading; nil for a reply that asked none.
    static func actionRecord(of tools: [ToolActivity]) -> String? {
        let lines = tools.compactMap { tool -> String? in
            guard let approval = tool.approval, let outcome = approval.outcome else { return nil }
            let result =
                switch outcome {
                case .denied: "declined by the person, not done"
                case .stopped: "stopped by the person, not done"
                case _ where tool.failed: "allowed, but it failed: not done"
                case .allowedOnce, .alwaysAllowed, .allowedByRule: "allowed and done"
                }
            return "- \(approval.intent.action): \(result)"
        }
        return lines.isEmpty ? nil : ([Self.actionRecordHeading] + lines).joined(separator: "\n")
    }

    static let actionRecordHeading = "(Peel's actions this turn, as the app recorded them:)"

    /// A message and its reply, as the model is sent them, with the reply's id.
    typealias Exchange = (through: String, messages: [ModelMessage])

    /// What the model sees of `turns`, by exchange: each message and the
    /// reply to it, with the reply's id; without replies that are empty or
    /// were declined.
    static func exchanges(of turns: some Sequence<AgentTurn>) -> [Exchange] {
        var exchanges: [Exchange] = []
        var asked: AgentTurn?
        for turn in turns {
            switch turn.author {
            case .user:
                asked = turn
            case .agent:
                if let automation = turn.automation {
                    // Delivered on its own: its own exchange, never the reply
                    // to a message the person is still waiting on.
                    let note = "(The scheduled automation \"\(automation)\" ran on its own and told the person:)"
                    exchanges.append((turn.id, [.user(note), ModelMessage(role: .assistant, content: [.text(turn.text)])]))
                    continue
                }
                guard let question = asked, turn.ending != .declined else { continue }
                // What its actions came to goes first, where no cut reaches it,
                // so a "no" stays a "no" in the model's view and in a summary.
                let words = turn.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : turn.text
                let reply = [actionRecord(of: turn.tools), words].compactMap { $0 }.joined(separator: "\n\n")
                guard !reply.isEmpty else { continue }
                exchanges.append((turn.id, [.user(question.text), ModelMessage(role: .assistant, content: [.text(reply)])]))
                asked = nil
            }
        }
        return exchanges
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
            ending: props["ending"]?.string.flatMap(Ending.init(rawValue:)),
            automation: props["automation"]?.string)
    }

    var props: [String: JSONValue] {
        var props: [String: JSONValue] = [:]
        if let ending { props["ending"] = .string(ending.rawValue) }
        if let automation { props["automation"] = .string(automation) }
        return props
    }
}

extension AgentSession.Summary {
    /// A `Summary` record: its text as the body, the last turn it covers.
    init?(record: Record) {
        guard let through = record.props["through"]?.string else { return nil }
        self.init(id: record.refId, text: record.body ?? "", through: through,
                  date: Date(timeIntervalSince1970: Double(record.createdMs) / 1000))
    }
}

extension ToolActivity {
    /// A `ToolCall` record: the tool's name, the summary of its result as
    /// the body, what it was asked, how long it took and whether it failed.
    /// What it returned in full is not kept: it is a copy of chats Peel
    /// already stores. Only a row a tool chose to keep is (`row`).
    init(record: Record) {
        let props = JSONValue.object(record.props)
        let ms: Double? = if case .number(let ms)? = props["ms"] { ms } else { nil }
        self.init(id: props["call_id"]?.string ?? record.refId, name: record.name, input: props["input"] ?? .object([:]),
                  summary: record.body, duration: .milliseconds(Int64(ms ?? 0)), failed: props["failed"] == .bool(true),
                  approval: props["approval"].flatMap { try? $0.decoded(as: ToolApproval.self) }, row: props["row"])
    }

    var props: [String: JSONValue] {
        var props: [String: JSONValue] = ["call_id": .string(id), "input": input, "failed": .bool(failed)]
        if let duration { props["ms"] = .number((duration / .milliseconds(1)).rounded()) }
        if let approval, let json = try? JSONValue(encoding: approval) { props["approval"] = json }
        if let row { props["row"] = row }
        return props
    }
}
