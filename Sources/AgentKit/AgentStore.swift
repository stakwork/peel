import Foundation

/// One of the agent's records: a conversation, a turn, a memory, a person.
/// Shaped like a graph node so moving to the graph is an import, not a
/// redesign (docs/agent-architecture.md, "Storage before the graph").
public struct Record: Sendable, Equatable {
    public var refId: String
    public var type: String
    public var name: String
    public var body: String?
    public var props: [String: JSONValue]
    /// The user or the agent.
    public var createdBy: String
    /// What it came from: a turn's or a message's id.
    public var source: String?
    public var createdMs: Int64
    public var updatedMs: Int64
    public var deletedMs: Int64?
}

/// A typed edge from one record to another.
public struct Link: Sendable, Equatable {
    public var refId: String
    public var type: String
    public var from: String
    public var to: String
    public var props: [String: JSONValue]
    public var createdBy: String
    public var createdMs: Int64
    public var deletedMs: Int64?
}

/// A search result: enough to choose one to `read`.
public struct SearchHit: Sendable, Equatable {
    public var refId: String
    public var type: String
    public var name: String
    /// Part of the body, around the match when the body matched; nil without a body.
    public var snippet: String?
}

/// A record reached by `walk`, the link it was reached by, and how many
/// links from the start.
public struct WalkStep: Sendable, Equatable {
    public var record: Record
    public var link: Link
    public var depth: Int
}

public enum WalkDirection: Sendable {
    case outgoing, incoming, both
}

/// A record or link type in use, and how many there are.
public struct TypeCount: Sendable, Equatable {
    public enum Kind: String, Sendable { case record, link }
    public var kind: Kind
    public var type: String
    public var count: Int
}

public enum AgentStoreError: Error, Equatable {
    /// An event in a newer format than this build reads.
    case unsupportedVersion(Int)
    /// An event without an event_id or ref_id, or whose `device` is not its stamp's.
    case malformedEvent
}

/// Where the agent keeps its records. Every write is an `Event`; reads leave
/// out forgotten records and removed links unless asked.
public protocol AgentStore: Sendable {
    /// This device's id, stamped on the events it makes.
    var device: String { get }
    /// The stamp for the next local event.
    func stamp() -> HLC
    /// Applies `event`; false if it was already applied.
    @discardableResult func write(_ event: Event) throws -> Bool
    func read(_ refId: String, includeDeleted: Bool) throws -> Record?
    func search(_ query: String, type: String?, limit: Int, includeDeleted: Bool) throws -> [SearchHit]
    /// Records linked to `refId`, nearest first, each once; `depth` is at most `maxWalkDepth`.
    func walk(
        _ refId: String, edgeTypes: Set<String>?, direction: WalkDirection, depth: Int, limit: Int,
        includeDeleted: Bool
    ) throws -> [WalkStep]
    func ontology() throws -> [TypeCount]
}

public let maxWalkDepth = 2

extension AgentStore {
    public func read(_ refId: String) throws -> Record? {
        try read(refId, includeDeleted: false)
    }

    public func search(_ query: String, type: String? = nil, limit: Int = 20) throws -> [SearchHit] {
        try search(query, type: type, limit: limit, includeDeleted: false)
    }

    public func walk(
        _ refId: String, edgeTypes: Set<String>? = nil, direction: WalkDirection = .both, depth: Int = 1,
        limit: Int = 50
    ) throws -> [WalkStep] {
        try walk(refId, edgeTypes: edgeTypes, direction: direction, depth: depth, limit: limit, includeDeleted: false)
    }
}

// MARK: - Writes from plain arguments

extension AgentStore {
    /// Adds a record; returns its ref_id.
    @discardableResult
    public func add(
        type: String, name: String, body: String? = nil, props: [String: JSONValue] = [:], createdBy: String,
        source: String? = nil
    ) throws -> String {
        let refId = UUID().uuidString.lowercased()
        var fields: [String: JSONValue] = ["type": .string(type), "name": .string(name),
                                           "created_by": .string(createdBy), "props": .object(props)]
        if let body { fields["body"] = .string(body) }
        if let source { fields["source"] = .string(source) }
        try write(Event(op: .add, refId: refId, fields: fields, ts: stamp()))
        return refId
    }

    /// Changes only what is given; a props key set to `.null` is removed.
    public func update(
        _ refId: String, name: String? = nil, body: String? = nil, props: [String: JSONValue] = [:]
    ) throws {
        var fields: [String: JSONValue] = [:]
        if let name { fields["name"] = .string(name) }
        if let body { fields["body"] = .string(body) }
        if !props.isEmpty { fields["props"] = .object(props) }
        guard !fields.isEmpty else { return }
        try write(Event(op: .update, refId: refId, fields: fields, ts: stamp()))
    }

    /// Links `from` to `to`; returns the link's ref_id.
    @discardableResult
    public func link(
        _ from: String, _ type: String, _ to: String, props: [String: JSONValue] = [:], createdBy: String
    ) throws -> String {
        let refId = UUID().uuidString.lowercased()
        let fields: [String: JSONValue] = ["type": .string(type), "from": .string(from), "to": .string(to),
                                           "created_by": .string(createdBy), "props": .object(props)]
        try write(Event(op: .link, refId: refId, fields: fields, ts: stamp()))
        return refId
    }

    /// Removes a link, kept in the log and readable with `includeDeleted`.
    public func unlink(_ linkRefId: String) throws {
        try write(Event(op: .unlink, refId: linkRefId, ts: stamp()))
    }

    /// Soft-deletes a record; `restore` brings it back.
    public func forget(_ refId: String, reason: String? = nil) throws {
        try write(Event(op: .forget, refId: refId, fields: reason.map { ["reason": .string($0)] } ?? [:],
                        ts: stamp()))
    }

    public func restore(_ refId: String) throws {
        try write(Event(op: .update, refId: refId, fields: ["deleted_ms": .null], ts: stamp()))
    }
}
