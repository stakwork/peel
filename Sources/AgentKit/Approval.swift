import Foundation

/// What a tool that acts is about to do, in words a person can approve:
/// what happens, the exact content, what it costs and what an "Always
/// allow" would cover. A tool works it out before anything is done
/// (`Tool.Plan.action`), so what runs is what was shown.
public struct ToolIntent: Sendable, Hashable, Codable {
    /// What will happen, in plain words: "Send to Kate".
    public var action: String
    /// The exact content: a message's text.
    public var content: String?
    /// More of what will happen, a line each: "In reply to Kate: 'lunch?'".
    public var details: [String]
    /// What it costs, in words ("Costs 3 sats"). An action that costs
    /// anything is asked about every time: no "always" rule covers it.
    public var cost: String?
    /// What an "Always allow" covers besides the tool (a chat); nil for the
    /// tool as a whole.
    public var target: Target?

    public struct Target: Sendable, Hashable, Codable {
        /// What the rule matches: a chat id.
        public var id: String
        /// What a person reads: "Kate".
        public var name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    public init(action: String, content: String? = nil, details: [String] = [], cost: String? = nil, target: Target? = nil) {
        self.action = action
        self.content = content
        self.details = details
        self.cost = cost
        self.target = target
    }

    /// For a tool that says nothing of its own: its name and arguments.
    static func generic(_ tool: String, input: JSONValue) -> ToolIntent {
        ToolIntent(action: "Run \(tool)", content: input == .object([:]) ? nil : input.jsonString)
    }

    /// Whether an "Always allow" may cover it: one that costs nothing and
    /// names its target. A tool that says only its name and arguments
    /// (`generic`) is asked every time, since a rule for it would cover any
    /// arguments.
    public var mayBeAlwaysAllowed: Bool { cost == nil && target != nil }

    /// What a card says under the action: the details, then the cost.
    public var lines: [String] { details + [cost].compactMap { $0 } }

    /// "Always allow for Kate", or for the tool as a whole.
    public var alwaysLabel: String { target.map { "Always allow for \($0.name)" } ?? "Always allow" }

    /// Whether `text` shows on a card as all it is: no control character
    /// but a line break and a tab, and nothing that draws nothing (format
    /// characters, variation selectors, fillers: every default-ignorable
    /// code point) except the joiner and the emoji selector right after an
    /// emoji. A tool refuses content that is not, so what a person allows
    /// is what is done and nothing can ride along unseen.
    public static func isShowable(_ text: String) -> Bool {
        var previous: Unicode.Scalar?
        for scalar in text.unicodeScalars {
            defer { previous = scalar }
            let properties = scalar.properties
            if properties.generalCategory == .control, scalar != "\n", scalar != "\t" { return false }
            guard properties.isDefaultIgnorableCodePoint || properties.generalCategory == .format else { continue }
            let afterEmoji = previous.map { $0.properties.isEmoji || $0 == "\u{FE0F}" } ?? false
            guard (scalar == "\u{200D}" || scalar == "\u{FE0F}"), afterEmoji else { return false }
        }
        return true
    }
}

/// One action waiting on a person: a device request's card.
public struct ApprovalRequest: Sendable, Hashable {
    /// The device request's id.
    public let callID: String
    public let tool: String
    public let intent: ToolIntent

    public init(callID: String, tool: String, intent: ToolIntent) {
        self.callID = callID
        self.tool = tool
        self.intent = intent
    }
}

/// What a person answers.
public enum ApprovalDecision: Sendable, Hashable {
    case allowOnce
    /// Allow, and from now on this tool for this target without asking.
    case alwaysAllow
    case deny
}

/// How a call that needed approval went.
public enum ApprovalOutcome: String, Sendable, Hashable, Codable {
    case allowedOnce = "allowed_once"
    /// Allowed, and remembered for next time.
    case alwaysAllowed = "always_allowed"
    /// Allowed without asking, by a rule remembered before.
    case allowedByRule = "allowed_by_rule"
    case denied
    /// Stopped while it waited.
    case stopped

    public var allows: Bool {
        switch self {
        case .allowedOnce, .alwaysAllowed, .allowedByRule: true
        case .denied, .stopped: false
        }
    }
}

/// The approval every front end shares: a remembered "always" rule allows
/// at once; anything else is asked of the person (`ask`), and their
/// "Always allow" is remembered. An action with a cost is always asked. An
/// `ask` that comes back with no answer (its card taken down) is `stopped`.
public struct ApprovalGate: Sendable {
    public let rules: ApprovalRules
    let ask: @Sendable (ApprovalRequest) async -> ApprovalDecision?

    public init(rules: ApprovalRules, ask: @escaping @Sendable (ApprovalRequest) async -> ApprovalDecision?) {
        self.rules = rules
        self.ask = ask
    }

    public func approve(_ request: ApprovalRequest) async -> ApprovalOutcome {
        if (try? rules.allows(request)) == true { return .allowedByRule }
        guard let decision = await ask(request), !Task.isCancelled else { return .stopped }
        switch decision {
        case .deny:
            return .denied
        case .allowOnce:
            return .allowedOnce
        case .alwaysAllow:
            // Not remembered (a cost, or the store failed): this once only.
            guard request.intent.mayBeAlwaysAllowed, (try? rules.remember(request)) != nil else { return .allowedOnce }
            return .alwaysAllowed
        }
    }
}

/// A remembered "Always allow": one tool, for one target or for all of it.
public struct ApprovalRule: Sendable, Hashable, Identifiable {
    /// The record's ref_id.
    public let id: String
    public let tool: String
    public let target: ToolIntent.Target?
}

/// The account's "always" rules, kept as `ApprovalRule` records in its
/// agent store (never the Keychain), so they last across launches and an
/// Account screen can list and revoke them.
public struct ApprovalRules: Sendable {
    let store: any AgentStore

    static let recordType = "ApprovalRule"

    public init(store: any AgentStore) {
        self.store = store
    }

    /// Every rule, oldest first.
    public func all() throws -> [ApprovalRule] {
        try store.records(type: Self.recordType, limit: Int.max).map { record in
            let props = JSONValue.object(record.props)
            let target = props["target"]?.string.map { ToolIntent.Target(id: $0, name: props["target_name"]?.string ?? $0) }
            return ApprovalRule(id: record.refId, tool: record.name, target: target)
        }
    }

    /// Whether a rule allows `request` without asking: the same tool and
    /// target, and nothing to pay.
    public func allows(_ request: ApprovalRequest) throws -> Bool {
        guard request.intent.mayBeAlwaysAllowed else { return false }
        return try all().contains { $0.tool == request.tool && $0.target?.id == request.intent.target?.id }
    }

    /// Remembers `request`'s tool and target.
    func remember(_ request: ApprovalRequest) throws {
        var props: [String: JSONValue] = [:]
        if let target = request.intent.target {
            props["target"] = .string(target.id)
            props["target_name"] = .string(target.name)
        }
        try store.add(type: Self.recordType, name: request.tool, props: props, createdBy: "user")
    }

    /// Forgets a rule: that tool asks again.
    public func revoke(_ rule: ApprovalRule) throws {
        try store.forget(rule.id, reason: "revoked")
    }
}

/// A send grant (docs/agent-on-strut.md, "Sends as you"): one automation
/// may post as you to its chats, a message at a time up to its sats cap,
/// without a card. Made only from your own click on an `approve` card.
public struct SendGrant: Sendable, Hashable, Identifiable {
    /// The record's ref_id.
    public let id: String
    /// The automation's id in strut.
    public let automation: String
    /// The automation's name, as the card showed it.
    public let name: String?
    public let chats: [ToolIntent.Target]
    /// The most one message may pay (a tribe's price), in sats.
    public let maxPriceSats: Int
    /// The `approve` request that made it, so that request, asked again,
    /// finds it rather than a second card.
    public var request: String?
    /// When it was kept; nil before.
    public var created: Date?

    /// A grant to keep (`SendGrants.keep`): its id is the record's, once kept.
    public init(automation: String, name: String?, chats: [ToolIntent.Target], maxPriceSats: Int) {
        self.init(id: "", automation: automation, name: name, chats: chats, maxPriceSats: maxPriceSats)
    }

    init(
        id: String, automation: String, name: String?, chats: [ToolIntent.Target], maxPriceSats: Int, request: String? = nil,
        created: Date? = nil
    ) {
        self.request = request
        self.created = created
        self.id = id
        self.automation = automation
        self.name = name
        self.chats = chats
        self.maxPriceSats = maxPriceSats
    }

    /// "Hive and Kate, up to 10 sats a message": where it may post, and for how much.
    public var summary: String {
        let chats = ListFormatter.localizedString(byJoining: chats.map(\.name))
        return maxPriceSats > 0 ? "\(chats), up to \(maxPriceSats) sats a message" : chats
    }
}

/// The account's send grants, kept as `SendGrant` records in the agent
/// store beside the "always" rules, so Account can list and revoke them.
public struct SendGrants: Sendable {
    let store: any AgentStore

    static let recordType = "SendGrant"

    /// In the store `rules` keeps its rules in.
    public init(beside rules: ApprovalRules) {
        store = rules.store
    }

    /// Every grant, oldest first.
    public func all() throws -> [SendGrant] {
        try store.records(type: Self.recordType, limit: Int.max).map { record in
            let props = JSONValue.object(record.props)
            let ids = props["chats"]?.array?.compactMap(\.string) ?? []
            let names = props["chat_names"]?.array?.compactMap(\.string) ?? []
            return SendGrant(
                id: record.refId, automation: record.name, name: props["automation_name"]?.string,
                chats: ids.enumerated().map { ToolIntent.Target(id: $1, name: $0 < names.count ? names[$0] : $1) },
                maxPriceSats: max(props["max_price_sats"]?.int ?? 0, 0), request: props["request"]?.string,
                created: Date(timeIntervalSince1970: TimeInterval(record.createdMs) / 1000)
            )
        }
    }

    /// `automation`'s grant, if it has one.
    public func grant(for automation: String) throws -> SendGrant? {
        try all().last { $0.automation == automation }
    }

    /// Keeps `grant`, in place of any its automation had.
    public func keep(_ grant: SendGrant) throws {
        try revoke(automation: grant.automation)
        var props: [String: JSONValue] = [
            "chats": .array(grant.chats.map { .string($0.id) }),
            "chat_names": .array(grant.chats.map { .string($0.name) }),
            "max_price_sats": .number(Double(grant.maxPriceSats)),
        ]
        if let name = grant.name { props["automation_name"] = .string(name) }
        if let request = grant.request { props["request"] = .string(request) }
        try store.add(type: Self.recordType, name: grant.automation, props: props, createdBy: "user")
    }

    public func revoke(_ grant: SendGrant) throws {
        try store.forget(grant.id, reason: "revoked")
    }

    /// Revokes `automation`'s grants: it is deleted, or granted anew.
    public func revoke(automation: String) throws {
        for grant in try all() where grant.automation == automation { try revoke(grant) }
    }

    /// Revokes the grants of automations that are gone: every grant whose
    /// automation is not in `kept` (the keys strut's automations hold), unless
    /// it was kept after `cutoff`, since strut makes an automation only
    /// once its card is allowed. Returns how many it revoked.
    @discardableResult
    public func revoke(allBut kept: Set<String>, keptBefore cutoff: Date) throws -> Int {
        let gone = try all().filter { !kept.contains($0.automation) && ($0.created ?? .distantPast) < cutoff }
        for grant in gone { try revoke(grant) }
        return gone.count
    }
}
