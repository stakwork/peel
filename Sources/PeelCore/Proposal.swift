import Foundation

// A strut proposal (strut's plans/proposals.md, specs/API.md §12): a tool
// call an agent made that a person must approve. strut records it and runs
// nothing; the person's accept runs the step in code. Peel shows one as a
// card in the agent chat: Peel's own strut's, which the bridge relays as an
// `approve` device request (`proposal:<id>`, `DeviceActions`), and the
// person's own on each Stadeum workspace's strut, read and decided with the
// person token Peel holds (`HivePeer`). The record is strut's; every word in
// it was written by a model or another host, so it is read bounded and
// cleaned, and nothing in it is acted on but by the person's click.

/// strut's record of one proposal, as Peel reads it.
public struct ProposalRecord: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable, CaseIterable {
        case pending
        /// Briefly, while the step runs after an accept.
        case accepted
        case rejected
        case applied
        /// The step ran and failed; strut lets it be accepted again.
        case failed

        /// Nothing more will happen to it.
        public var isFinal: Bool { self == .rejected || self == .applied || self == .failed }
    }

    /// Who proposed it.
    public struct By: Codable, Sendable, Equatable {
        public var workflow: String
        public var runId: String
        /// The person a run spoke for (`<person>/<org>`'s person on an org's
        /// strut): only their own token may decide it.
        public var actor: String?

        public init(workflow: String, runId: String, actor: String? = nil) {
            self.workflow = workflow
            self.runId = runId
            self.actor = actor
        }
    }

    public struct Decision: Codable, Sendable, Equatable {
        public var accepted: Bool
        public var by: String?
        public var at: Date?
        /// A reject's reason, when one was given.
        public var reason: String?

        public init(accepted: Bool, by: String? = nil, at: Date? = nil, reason: String? = nil) {
            self.accepted = accepted
            self.by = by
            self.at = at
            self.reason = reason
        }
    }

    /// How the step went once accepted.
    public struct Outcome: Codable, Sendable, Equatable {
        public var error: String?
        public var at: Date?

        public init(error: String? = nil, at: Date? = nil) {
            self.error = error
            self.at = at
        }
    }

    public var id: String
    /// The registry step type: `package/install`, `graph/create-node`.
    public var step: String
    public var title: String
    /// What the step read at proposal time, plain text with its lines.
    public var summary: String?
    /// The model's reason, in its own words: shown apart, never as a fact.
    public var rationale: String?
    /// The card as strut computed it; nil on a record from before strut#404,
    /// drawn from the title, the summary and the input instead (`shownCard`).
    public var card: ProposalCard?
    public var status: Status
    public var createdAt: Date?
    public var by: By
    public var decision: Decision?
    public var result: Outcome?
    /// What will run, as the step's schema parsed it; nil when it is more
    /// than Peel keeps of one (`inputCut`), or the record had none.
    public var input: JSONValue?
    /// Whether `input` was left out for its size.
    public var inputCut = false
    /// The record has a `card` this Peel cannot read (another version, no
    /// title): the input stands in, and the card is never accepted by a
    /// key, since what it warned of cannot be seen.
    public var cardUnreadable = false

    /// The most of an input kept, as JSON: a Concept's docs fit; a dump does not.
    public static let maxInputBytes = 64 * 1024

    public init(
        id: String, step: String, title: String, summary: String? = nil, rationale: String? = nil,
        card: ProposalCard? = nil, status: Status, createdAt: Date? = nil, by: By, decision: Decision? = nil,
        result: Outcome? = nil, input: JSONValue? = nil, inputCut: Bool = false, cardUnreadable: Bool = false
    ) {
        self.id = id
        self.step = step
        self.title = title
        self.summary = summary
        self.rationale = rationale
        self.card = card
        self.status = status
        self.createdAt = createdAt
        self.by = by
        self.decision = decision
        self.result = result
        self.input = input
        self.inputCut = inputCut
        self.cardUnreadable = cardUnreadable
    }

    /// The step that hands a request to an org's assistant (`strut/run-workflow`),
    /// whose card the Mac words itself (`DeviceActions.peerCall`) and whose
    /// yes is when that org may propose something of its own.
    public static let handOffStep = "strut/run-workflow"

    /// strut's id form: 1 to 64 of base64url's characters (`src/proposals.ts`).
    public static func isID(_ id: String) -> Bool {
        id.range(of: #"^[A-Za-z0-9_-]{1,64}\z"#, options: .regularExpression) != nil
    }

    /// The record as strut answers `GET /proposals/:id` (or lists one), read
    /// bounded: an id, step, title, status and `by` it must have, in the
    /// shapes strut gives them; a status Peel does not know is refused
    /// rather than guessed; every text cleaned; unknown keys ignored.
    public init(strut data: Data) throws {
        guard case .object(let fields)? = JSONValue(data: data) else { throw PeelError("strut's proposal is not a record.") }
        try self.init(strut: fields)
    }

    /// Whether it hands a request to a workspace's assistant (`handOffStep`):
    /// its card is the Mac's own (`DeviceActions.peerCall`), never the generic one.
    public var isHandOff: Bool { step == Self.handOffStep }

    init(strut fields: [String: JSONValue]) throws {
        guard let id = fields["id"]?.string, Self.isID(id) else { throw PeelError("strut's proposal has no id.") }
        guard let step = fields["step"]?.string.map({ TextLine.clean($0, max: 128) }), !step.isEmpty else {
            throw PeelError("strut's proposal names no step.")
        }
        guard let status = fields["status"]?.string.flatMap(Status.init(rawValue:)) else {
            throw PeelError("strut's proposal has a status Peel does not know.")
        }
        // Always written by strut; read leniently, since a record with none names no actor and so is no one's to decide.
        var by: [String: JSONValue] = [:]
        if case .object(let given)? = fields["by"] { by = given }
        let line = { (value: JSONValue?, max: Int) -> String? in
            value?.string.map { TextLine.clean($0, max: max) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        let block = { (value: JSONValue?, max: Int) -> String? in
            value?.string.map { TextLine.block($0, max: max) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        let when = { (value: JSONValue?) -> Date? in value?.string.flatMap(Date.init(iso8601:)) }
        var decision: Decision?
        if case .object(let decided)? = fields["decision"], let action = decided["action"]?.string, ["accept", "reject"].contains(action) {
            decision = Decision(accepted: action == "accept", by: line(decided["by"], 120), at: when(decided["at"]),
                                reason: block(decided["reason"], 500))
        }
        var result: Outcome?
        if case .object(let ended)? = fields["result"] {
            result = Outcome(error: block(ended["error"], 1000), at: when(ended["at"]))
        }
        var input = fields["input"]
        var inputCut = false
        if let given = input, given != .null {
            if let size = try? given.text.utf8.count, size > Self.maxInputBytes {
                input = nil
                inputCut = true
            }
        } else {
            input = nil
        }
        let card = fields["card"].flatMap(ProposalCard.init(strut:))
        let cardGiven = fields["card"].map { $0 != .null } ?? false
        self.init(
            id: id, step: step, title: line(fields["title"], 200) ?? step, summary: block(fields["summary"], 4000),
            rationale: block(fields["rationale"], 1000), card: card,
            status: status, createdAt: when(fields["createdAt"]),
            by: By(workflow: line(by["workflow"], 120) ?? "", runId: line(by["runId"], 120) ?? "", actor: line(by["actor"], 120)),
            decision: decision, result: result, input: input, inputCut: inputCut, cardUnreadable: cardGiven && card == nil
        )
    }

    /// Whether it still waits on someone, or runs.
    public var isOpen: Bool { !status.isFinal }

    /// The card drawn for it: strut's, else one from the title, the summary
    /// and the input, as strut builds a generic one; never whole when strut's
    /// card could not be read.
    public var shownCard: ProposalCard {
        card ?? ProposalCard.generic(title: title, summary: summary, input: input, cut: inputCut || cardUnreadable)
    }

    /// Whether a key may accept it: only a card Peel read whole, with
    /// nothing in it that warns; the rest take a click.
    public var acceptsByKey: Bool { !cardUnreadable && !shownCard.hasDanger }

    /// The input as a person reads it: JSON over lines, keys in order,
    /// capped (`ProposalCard.maxShownInput`); nil when there is none.
    public var inputText: String? {
        guard let input else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(input) else { return nil }
        return TextLine.block(String(decoding: data, as: UTF8.self), max: ProposalCard.maxShownInput)
    }
}

/// What a person decides on, as data a host draws without knowing the step
/// (strut's `src/proposal-card.ts`, version 1): a title, a summary, up to
/// twelve labelled values, the two buttons' words, and whether the fields
/// cover all that will run.
public struct ProposalCard: Codable, Sendable, Equatable {
    public struct Field: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable {
            case text, code, markdown, ref
        }

        public var label: String
        public var value: String
        /// `markdown` and `ref` read as text for now; `code` is monospaced.
        public var kind: Kind
        /// A field whose value is lost or let loose by the step (a delete,
        /// a grant): drawn with a warning tint.
        public var danger: Bool

        public init(label: String, value: String, kind: Kind = .text, danger: Bool = false) {
            self.label = label
            self.value = value
            self.kind = kind
            self.danger = danger
        }
    }

    public var title: String
    public var summary: String?
    public var fields: [Field]
    /// The buttons' words: "Install" and "Don't install", else Accept and Reject.
    public var accept: String
    public var reject: String
    /// False when the fields leave out part of what will run (a value cut,
    /// a key dropped): the card then offers the whole input, and still Accept.
    public var full: Bool

    /// The version this Peel reads.
    public static let version = 1
    /// strut's caps, which Peel holds a card to whoever made it.
    public static let maxFields = 12
    public static let maxValue = 500
    /// The most of an input shown whole, as text.
    public static let maxShownInput = 20_000
    /// What strut appends to a value it cut.
    public static let cutMarker = "… (see full input)"
    public static let acceptWord = "Accept"
    public static let rejectWord = "Reject"

    public init(title: String, summary: String? = nil, fields: [Field], accept: String = acceptWord, reject: String = rejectWord,
                full: Bool = true) {
        self.title = title
        self.summary = summary
        self.fields = fields
        self.accept = accept
        self.reject = reject
        self.full = full
    }

    /// strut's `card`: nil for another version or shape, so the record's
    /// title, summary and input stand in. Fields that are not a label and a
    /// value are skipped, a kind not known reads as text, extras are ignored.
    init?(strut value: JSONValue) {
        guard case .object(let card) = value, card["v"]?.wholeNumber == UInt64(Self.version),
              let title = card["title"]?.string.map({ TextLine.clean($0, max: 200) }), !title.isEmpty else { return nil }
        var fields: [Field] = []
        if case .array(let given)? = card["fields"] {
            for item in given.prefix(Self.maxFields) {
                guard case .object(let field) = item, let label = field["label"]?.string, let value = field["value"]?.string else { continue }
                fields.append(Field(
                    label: TextLine.clean(label, max: 120), value: TextLine.block(value, max: Self.maxValue),
                    kind: field["kind"]?.string.flatMap(Field.Kind.init(rawValue:)) ?? .text, danger: field["danger"]?.flag ?? false
                ))
            }
        }
        let word = { (value: JSONValue?, fallback: String) -> String in
            let word = value?.string.map { TextLine.clean($0, max: 40) } ?? ""
            return word.isEmpty ? fallback : word
        }
        let summary = card["summary"]?.string.map { TextLine.block($0, max: 4000) }.flatMap { $0.isEmpty ? nil : $0 }
        self.init(title: title, summary: summary, fields: fields,
                  accept: word(card["actions"]?["accept"], Self.acceptWord), reject: word(card["actions"]?["reject"], Self.rejectWord),
                  full: card["full"]?.flag ?? false)
    }

    /// A card for a record with none (strut before #404), as strut builds
    /// its generic one: one field per top-level key of the input, strings
    /// as they are, anything else as JSON; a value over the cap cut with
    /// the marker; the first twelve keys; `full` false when anything was
    /// cut or left out, or the input is more than Peel keeps. The keys come
    /// A–Z (a decoded object keeps no order), where strut's own UI keeps the
    /// input's.
    public static func generic(title: String, summary: String?, input: JSONValue?, cut: Bool = false) -> ProposalCard {
        var fields: [Field] = []
        var full = !cut
        func field(_ label: String, _ value: JSONValue, kind given: Field.Kind? = nil) -> Field {
            var text: String
            var kind = Field.Kind.text
            if case .string(let string) = value {
                text = string
            } else {
                text = (try? value.text) ?? ""
                kind = .code
            }
            if let given { kind = given }
            if text.count > maxValue {
                text = String(text.prefix(maxValue - cutMarker.count)).trimmingCharacters(in: .whitespacesAndNewlines) + cutMarker
                full = false
            }
            return Field(label: TextLine.clean(label, max: 120), value: TextLine.block(text, max: maxValue), kind: kind)
        }
        switch input {
        case .object(let object)?:
            let keys = object.keys.sorted()
            for key in keys.prefix(maxFields) {
                guard let value = object[key], value != .null else { continue }
                fields.append(field(key, value))
            }
            if keys.count > maxFields { full = false }
        case nil, .null?:
            break
        case let value?:
            // Not an object: the whole input as one field, as code, as strut shows it.
            fields.append(field("input", value, kind: .code))
        }
        return ProposalCard(title: title, summary: summary, fields: fields, full: full)
    }

    /// Whether any field warns.
    public var hasDanger: Bool { fields.contains(where: \.danger) }
}

/// Where a proposal is: on Peel's own strut (through the bridge's card), or
/// on one of the person's Stadeum workspaces (by its peer id).
public enum ProposalSource: Hashable, Sendable {
    case local
    case org(String)

    /// As stored: "" for Peel's own strut.
    public var rawValue: String {
        switch self {
        case .local: ""
        case .org(let peer): peer
        }
    }

    public init(rawValue: String) {
        self = rawValue.isEmpty ? .local : .org(rawValue)
    }

    public var peer: String? {
        if case .org(let peer) = self { peer } else { nil }
    }
}

/// One proposal and where it is.
public struct ProposalKey: Hashable, Sendable {
    public let source: ProposalSource
    public let id: String

    public init(source: ProposalSource, id: String) {
        self.source = source
        self.id = id
    }
}

// MARK: - On a workspace's strut

/// How a read of one proposal on an org's strut ended.
public enum ProposalRead: Sendable, Equatable {
    case record(ProposalRecord)
    /// strut has no such proposal, or not for this person (404).
    case gone
    /// Not this person's to see (403).
    case forbidden
}

/// A workspace's strut refused a request outright, by status: a token it
/// no longer takes (401, 403), or a failure of its own. Not "no answer".
public struct StrutRefusal: Error, LocalizedError, Equatable {
    public let status: Int
    /// The workspace, as the person knows it.
    public let name: String

    /// Whether the person's token was the trouble: the pairing renews it.
    public var isAuth: Bool { status == 401 || status == 403 }

    public var errorDescription: String? { "\(name) refused (HTTP \(status))." }
}

/// How a decision on an org's strut ended.
public enum ProposalDecided: Sendable, Equatable {
    /// 200: the record after the decision (the step has run on an accept).
    case decided(ProposalRecord)
    /// 409: not to be decided now, with strut's words: decided already (in
    /// Stadeum, or twice), or waiting on another proposal first; the record
    /// as it stands, if strut sent it.
    case alreadyDecided(ProposalRecord?, String)
    /// 403: not this person's to decide, or an org's strut from before a person could.
    case notYours(String)
    /// 400: strut refused the decision; the proposal stays pending.
    case invalid(String)
    /// 404.
    case gone
}

extension HivePeer {
    /// The person's own pending proposals on this workspace's strut, read
    /// with their token (strut#404: a person token sees only its actor's),
    /// and filtered here by `actor` too, since a strut from before it
    /// answers with everyone's: another person's is never shown. `others`
    /// counts those left out, which tells such a strut apart.
    public func pendingProposals(actor: String) async throws -> (mine: [ProposalRecord], others: Int) {
        var components = try URLComponents(url: strut.appending(path: "proposals"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "status", value: "pending")]
        guard let url = components?.url else { throw PeelError("\(name)'s address could not be read.") }
        let (status, data) = try await Web.requestStrut("GET", url, bearer: token, limit: Self.proposalsLimit,
                                                        what: "\(name)'s proposals", timeout: 30)
        guard status == 200 else { throw StrutRefusal(status: status, name: name) }
        guard case .object(let json)? = JSONValue(data: data), case .array(let listed)? = json["proposals"] else {
            throw PeelError("\(name)'s proposals could not be read.")
        }
        var mine: [ProposalRecord] = []
        var others = 0
        for item in listed {
            guard case .object(let fields) = item, let record = try? ProposalRecord(strut: fields) else { continue }
            if record.by.actor == actor { mine.append(record) } else { others += 1 }
        }
        return (mine, others)
    }

    /// One proposal on this workspace's strut, with the person's token.
    public func proposal(_ id: String) async throws -> ProposalRead {
        guard ProposalRecord.isID(id) else { throw PeelError("That is not a proposal id strut gives.") }
        let (status, data) = try await Web.requestStrut("GET", try strut.appending(path: "proposals/\(id)"), bearer: token,
                                                        limit: Self.proposalsLimit, what: "\(name)'s proposal", timeout: 30)
        switch status {
        case 200: return .record(try Self.checked(try ProposalRecord(strut: data), is: id, from: name))
        case 403: return .forbidden
        case 404: return .gone
        default: throw StrutRefusal(status: status, name: name)
        }
    }

    /// `record` when it is the one asked for; a strut answering for another is not read.
    static func checked(_ record: ProposalRecord, is id: String, from name: String) throws -> ProposalRecord {
        guard record.id == id else { throw PeelError("\(name) answered for another proposal.") }
        return record
    }

    /// Decides proposal `id` on this workspace's strut as the person, with
    /// their token: an accept runs the step there and then. Never with an
    /// edit to the input: what the card showed is what runs.
    public func decide(_ id: String, accept: Bool, reason: String? = nil) async throws -> ProposalDecided {
        guard ProposalRecord.isID(id) else { throw PeelError("That is not a proposal id strut gives.") }
        var body: [String: JSONValue] = ["action": .string(accept ? "accept" : "reject")]
        if let reason, !reason.isEmpty { body["reason"] = .string(reason) }
        let (status, data) = try await Web.requestStrut(
            "POST", try strut.appending(path: "proposals/\(id)/decide"), json: Data(try JSONValue.object(body).text.utf8),
            bearer: token, limit: Self.proposalsLimit, what: "\(name)'s proposal", timeout: 120
        )
        let json = JSONValue(data: data) ?? .null
        let words = { TextLine.clean(json["error"]?.string ?? "HTTP \(status)", max: 300) }
        switch status {
        case 200: return .decided(try Self.checked(try ProposalRecord(strut: data), is: id, from: name))
        case 409:
            var read: ProposalRecord?
            if case .object(let record)? = json["proposal"] { read = try? Self.checked(try ProposalRecord(strut: record), is: id, from: name) }
            return .alreadyDecided(read, words())
        case 403: return .notYours(words())
        case 400: return .invalid(words())
        case 404: return .gone
        default: throw StrutRefusal(status: status, name: name)
        }
    }

    /// The most a proposals answer may be: the records carry their inputs.
    static let proposalsLimit = 4 * 1024 * 1024

    /// The workspace's strut, as a URL Peel may send its token to.
    var strut: URL {
        get throws {
            guard let url = URL(string: baseUrl), Web.isStrut(url) else { throw PeelError("\(name)'s address could not be read.") }
            return url
        }
    }
}

extension JSONValue {
    /// `key` of an object; nil for anything else.
    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { object[key] } else { nil }
    }

    /// A reply's bytes as JSON; nil for anything else.
    init?(data: Data) {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        self = value
    }
}
