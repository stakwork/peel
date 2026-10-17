import AgentKit
import Foundation
import PeelCore

/// The device requests that act as you (docs/agent-on-strut.md, "Sends as
/// you" and "Approvals"), on the Mac: `send`, planned by today's send tool
/// and allowed on its card in the agent's DM (or by an "Always allow" rule),
/// or, for an automation, by its send grant; and `approve`, the card alone,
/// which may make a send grant. The card is today's: the same gate and
/// rules (`ApprovalGate`), and what runs is what it showed. A card past the
/// request's time closes itself as `expired`. Every other kind is a read
/// (`DeviceReads`).
public struct DeviceActions: Sendable {
    /// Puts the card up in the agent's DM and waits for your answer; nil
    /// when it was taken down unanswered (the account closed), so the
    /// request is asked again once it is open. Cancelled, it is taken down.
    public typealias Ask = @Sendable (DeviceRequest, ApprovalRequest) async -> ApprovalDecision?

    let engine: Engine
    let tools: SphinxTools
    let reads: DeviceReads
    let rules: ApprovalRules
    let grants: SendGrants
    let ask: Ask
    /// A card remembered an "Always allow" or kept a send grant.
    let changed: @Sendable () -> Void

    /// The prefix an automation's message starts with, added here (decision 1
    /// of automations-and-jobs.md).
    static let agentPrefix = "[Agent] "
    /// The most a request may say a message pays, or a grant allow.
    static let maxPriceSats = 1_000_000
    /// How far ahead an automation's send may expire: the spec's fire time
    /// plus 10 minutes, with room for the clocks. A send naming an automation
    /// and expiring later is no automation's run.
    static let automationWindow: TimeInterval = 15 * 60
    /// The send tool's name, so today's "Always allow" rules cover these sends.
    static let sendTool = "send_sphinx_message"

    public init(
        engine: Engine, rules: ApprovalRules, ask: @escaping Ask, changed: @escaping @Sendable () -> Void = {}
    ) {
        self.engine = engine
        tools = SphinxTools(storage: engine.storage)
        reads = DeviceReads(storage: engine.storage)
        self.rules = rules
        grants = SendGrants(beside: rules)
        self.ask = ask
        self.changed = changed
    }

    /// The handler `Engine.answerDeviceRequests` takes.
    public var handler: DeviceRequestHandler {
        { request in await answer(request) }
    }

    func answer(_ request: DeviceRequest) async -> DeviceAnswer? {
        guard ["send", "approve"].contains(request.kind) else { return await reads.answer(request.kind, request.args) }
        guard case .object = request.args, let args = try? AgentKit.JSONValue(encoding: request.args) else {
            return .failed("args must be a JSON object")
        }
        return request.kind == "send" ? await send(request, args) : await approve(request, args)
    }

    // MARK: - send

    /// `chat`, `text`, `thread_uuid?`, `reply_to_uuid?`, `max_price_sats`
    /// (0 when left out: a contact, never a tribe) and `automation?`.
    private func send(_ request: DeviceRequest, _ args: AgentKit.JSONValue) async -> DeviceAnswer? {
        guard let maxPriceSats = Self.sats(args["max_price_sats"]) else {
            return .failed("max_price_sats must be a whole number of sats from 0 to \(Self.maxPriceSats)")
        }
        var input: [String: AgentKit.JSONValue] = [:]
        for key in ["chat", "text", "thread_uuid", "reply_to_uuid"] { input[key] = args[key] }
        let automation = SphinxTools.optional("automation", in: args)
        var cap = maxPriceSats
        if let automation {
            guard request.deadline.timeIntervalSinceNow <= Self.automationWindow else {
                return .denied("A send for an automation expires within \(Int(Self.automationWindow / 60)) minutes of its run; nothing was sent.")
            }
            guard let grant = try? grants.grant(for: automation) else {
                return .denied("No send grant for this automation: it may not post as you. Ask the user to allow it again.")
            }
            cap = min(cap, grant.maxPriceSats)
            if let text = SphinxTools.optional("text", in: args), !text.hasPrefix(Self.agentPrefix) {
                input["text"] = .string(Self.agentPrefix + text)
            }
            return await planned(request, .object(input), cap: cap) { intent, run in
                guard let chat = intent.target, grant.chats.contains(where: { $0.id == chat.id }) else {
                    return .denied("This automation's grant does not cover \(intent.target?.name ?? "that chat"); nothing was sent.")
                }
                return await sent(request, run)
            }
        }
        return await planned(request, .object(input), cap: cap) { intent, run in
            if let refusal = await decide(request, tool: Self.sendTool, intent: intent) { return refusal.answer }
            return await sent(request, run)
        }
    }

    /// The send tool's plan for `input`, then `act` on its card and run; a
    /// plan with nothing to approve (a name that matches two chats, a price
    /// over `cap`) is the answer, as `failed`.
    private func planned(
        _ request: DeviceRequest, _ input: AgentKit.JSONValue, cap: Int,
        act: (ToolIntent, @Sendable () async throws -> Tool.Output) async -> DeviceAnswer?
    ) async -> DeviceAnswer? {
        let plan: Tool.Plan
        do {
            plan = try await tools.send(through: engine, for: request, maxPriceSats: cap).plan(input)
        } catch {
            return .failed(error.localizedDescription)
        }
        switch plan {
        case .result(let output): return .failed(output.text)
        case .action(let intent, let run): return await act(intent, run)
        }
    }

    /// Runs an allowed send. Past the request's time it was refused before
    /// anything was made: `expired`. A failure once the message was stored
    /// the engine answers `unknown`.
    private func sent(_ request: DeviceRequest, _ run: @Sendable () async throws -> Tool.Output) async -> DeviceAnswer {
        do {
            return .done(try await run().text)
        } catch {
            return Date() > request.deadline ? .expired : .failed(error.localizedDescription)
        }
    }

    // MARK: - approve

    /// `intent` (a `ToolIntent`: `action`, `content?`, `details?`, `cost?`)
    /// and `grant?` (`automation`, `name?`, `chats`, `max_price_sats`). The
    /// intent is the agent's words, shown as they are; a grant's chats and
    /// cap are worded here, from this Mac's chats. "Always allow" is never
    /// offered: the intent names no target.
    private func approve(_ request: DeviceRequest, _ args: AgentKit.JSONValue) async -> DeviceAnswer? {
        var intent: ToolIntent
        var grant: SendGrant?
        do {
            intent = try Self.intent(args["intent"])
            if let asked = args["grant"] {
                grant = try await self.grant(asked)
            }
        } catch {
            return .failed(error.localizedDescription)
        }
        // Allowed before, and Peel stopped before it answered: the grant stands.
        if let grant, (try? grants.grant(for: grant.automation))?.request == request.id {
            return .done("Allowed. The automation may post to \(grant.summary).")
        }
        if let grant {
            let who = grant.name.map { "the automation \u{201C}\($0)\u{201D}" } ?? "this automation"
            let names = ListFormatter.localizedString(byJoining: grant.chats.map(\.name))
            let prefix = Self.agentPrefix.trimmingCharacters(in: .whitespaces)
            // The Mac's own words first, before the agent's.
            intent.details.insert("Lets \(who) post as you to \(names) without asking, each message starting with \u{201C}\(prefix)\u{201D}", at: 0)
            // Always a cost, so a grant is only made by a click, never by Return.
            intent.cost = grant.maxPriceSats > 0
                ? "Up to \(grant.maxPriceSats) sats a message, paid from your balance."
                : "No sats: only chats that cost nothing to post in."
        }
        if let refusal = await decide(request, tool: "approve", intent: intent) { return refusal.answer }
        guard var grant else { return .done("Allowed.") }
        grant.request = request.id
        do {
            try grants.keep(grant)
        } catch {
            return .failed("Allowed, but the send grant could not be kept: \(error.localizedDescription)")
        }
        changed()
        return .done("Allowed. The automation may post to \(grant.summary).")
    }

    /// The card's words from the request, each one shown in full.
    static func intent(_ value: AgentKit.JSONValue?) throws -> ToolIntent {
        func text(_ key: String, max: Int, in value: AgentKit.JSONValue) throws -> String? {
            guard let field = value[key] else { return nil }
            guard let text = field.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
                  text.count <= max, ToolIntent.isShowable(text) else {
                throw ToolFailure(errorDescription: "intent.\(key) must be showable text of at most \(max) characters")
            }
            return text
        }
        guard let value, case .object = value, let action = try text("action", max: 200, in: value) else {
            throw ToolFailure(errorDescription: "intent is required, with an action")
        }
        let details = value["details"]?.array ?? []
        guard details.count <= 10 else { throw ToolFailure(errorDescription: "intent.details takes at most 10 lines") }
        return ToolIntent(
            action: action, content: try text("content", max: SphinxTools.maxMessage, in: value),
            details: try details.map { try text("line", max: 300, in: ["line": $0]) ?? "" },
            cost: try text("cost", max: 200, in: value)
        )
    }

    /// A grant's automation, name, chats (each found on this Mac) and cap.
    private func grant(_ value: AgentKit.JSONValue) async throws -> SendGrant {
        guard let automation = SphinxTools.optional("automation", in: value), automation.count <= 128 else {
            throw ToolFailure(errorDescription: "grant.automation is required")
        }
        let name = SphinxTools.optional("name", in: value)
        guard name.map({ $0.count <= 200 && !$0.contains(where: \.isNewline) && ToolIntent.isShowable($0) }) != false else {
            throw ToolFailure(errorDescription: "grant.name must be one showable line of at most 200 characters")
        }
        guard let asked = value["chats"]?.array?.compactMap(\.string), (1...20).contains(asked.count) else {
            throw ToolFailure(errorDescription: "grant.chats must name 1 to 20 chats")
        }
        guard let cap = Self.sats(value["max_price_sats"]) else {
            throw ToolFailure(errorDescription: "grant.max_price_sats must be a whole number of sats from 0 to \(Self.maxPriceSats)")
        }
        let all = try await tools.chats()
        var chats: [ToolIntent.Target] = []
        for query in asked {
            let chat: Conversation
            do {
                chat = try tools.resolve(query, among: all)
            } catch let notFound as SphinxTools.NotFound {
                throw ToolFailure(errorDescription: notFound.text)
            }
            if !chats.contains(where: { $0.id == chat.chat }) {
                chats.append(ToolIntent.Target(id: chat.chat, name: ChatData.clean(chat.name, max: ChatData.maxName)))
            }
        }
        return SendGrant(automation: automation, name: name, chats: chats, maxPriceSats: cap)
    }

    /// Whole sats from 0 to `maxPriceSats`; nil (left out) is 0.
    static func sats(_ value: AgentKit.JSONValue?) -> Int? {
        guard let value else { return 0 }
        guard case .number(let number) = value, number == number.rounded(), (0...Double(maxPriceSats)).contains(number) else {
            return nil
        }
        return Int(number)
    }

    // MARK: - The card

    /// Why a card did not allow: its answer, nil when it was taken down
    /// unanswered (asked again once the account is open).
    struct Refusal {
        let answer: DeviceAnswer?
    }

    /// Asks through today's gate (an "Always allow" rule, or the card), until
    /// the request's time: a card still up then closes itself, and a click
    /// after it does nothing. Nil when allowed.
    private func decide(_ request: DeviceRequest, tool: String, intent: ToolIntent) async -> Refusal? {
        let gate = ApprovalGate(rules: rules) { approval in await ask(request, approval) }
        let approval = ApprovalRequest(callID: request.id, tool: tool, intent: intent)
        let outcome = await withTaskGroup(of: ApprovalOutcome?.self) { group in
            group.addTask { await gate.approve(approval) }
            group.addTask {
                try? await Task.sleep(for: .seconds(max(request.deadline.timeIntervalSinceNow, 0)))
                return nil
            }
            defer { group.cancelAll() }
            return await group.next() ?? nil
        }
        guard let outcome, Date() <= request.deadline else {
            // Cancelled before its time (the work stopped): asked again later.
            return Refusal(answer: Task.isCancelled ? nil : .expired)
        }
        if outcome == .alwaysAllowed { changed() }
        switch outcome {
        case .allowedOnce, .alwaysAllowed, .allowedByRule: return nil
        case .denied: return Refusal(answer: .denied())
        case .stopped: return Refusal(answer: nil)
        }
    }
}
