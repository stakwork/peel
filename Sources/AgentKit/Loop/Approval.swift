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

/// One tool call waiting on a person.
public struct ApprovalRequest: Sendable, Hashable {
    /// The model's id for the call, which the tool row shows under.
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

    /// What the model is told, and whether it is an error, when `outcome`
    /// (nil: no one to ask) does not let the action run; nil when it does.
    static func refusal(_ outcome: ApprovalOutcome?, of intent: ToolIntent) -> (String, Bool)? {
        switch outcome {
        case nil: ("Not run: this tool needs the user's approval, and there is no one to ask here.", true)
        case .stopped?: ("Not run: stopped by the user.", true)
        case .denied?: ("The user declined: \(intent.action). Nothing was done; do not try again unless they ask.", false)
        case _ where Task.isCancelled: ("Not run: stopped by the user.", true)
        default: nil
        }
    }
}

/// Decides whether a tool call that acts may run. The loop asks it before
/// every call of a tool whose effect asks (`Tool.Effect.asks`) and waits; a task
/// cancelled meanwhile (Stop) ends the wait as `.stopped`.
public protocol ToolApprover: Sendable {
    func approve(_ request: ApprovalRequest) async -> ApprovalOutcome
}

/// The approval every front end shares: a remembered "always" rule allows
/// at once; anything else is asked of the person (`ask`), and their
/// "Always allow" is remembered. An action with a cost is always asked.
public struct ApprovalGate: ToolApprover {
    public let rules: ApprovalRules
    let ask: @Sendable (ApprovalRequest) async -> ApprovalDecision

    public init(rules: ApprovalRules, ask: @escaping @Sendable (ApprovalRequest) async -> ApprovalDecision) {
        self.rules = rules
        self.ask = ask
    }

    public func approve(_ request: ApprovalRequest) async -> ApprovalOutcome {
        if (try? rules.allows(request)) == true { return .allowedByRule }
        let decision = await ask(request)
        if Task.isCancelled { return .stopped }
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
