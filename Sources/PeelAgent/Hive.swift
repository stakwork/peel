import AgentKit
import Foundation
import PeelCore

// The Mac's side of a Hive pairing (PeelCore's `HiveClient`, `HiveLink`):
// one peer record per org put on Peel's strut (docs/connectors-and-authoring.md,
// "Peers"; strut's specs/DESKTOP.md §2). The org's own assistant is then
// one `strut/run-workflow` away, behind a card on the Mac (`PeerRequest`).

/// A call to an org's assistant waiting on the person: a `strut/run-workflow`
/// proposal, read from strut's own record.
public struct PeerRequest: Sendable, Equatable {
    public let peer: String
    /// The org as the person knows it: its peer record's label.
    public let name: String
    public let workflow: String
    /// The message the org's assistant is sent.
    public let prompt: String?
    /// Whether the call's input holds anything but the message and its
    /// thread, which the card could not show.
    public var more = false
}

extension AutomationsClient {
    /// Makes strut's peers exactly `kept`: each put (`PUT /peers/:id`
    /// replaces the record), any other taken off (an org left; one already
    /// gone is fine). Peel puts no peers but Hive's.
    public func syncPeers(_ kept: [HivePeer]) async throws {
        let there = try await call("GET", "peers", what: "the workspaces")["peers"]?.array?.compactMap { $0["id"]?.string } ?? []
        for peer in kept {
            var body: [String: AgentKit.JSONValue] = ["baseUrl": .string(peer.baseUrl), "token": .string(peer.token)]
            if let label = peer.label { body["label"] = .string(label) }
            if let description = peer.description { body["description"] = .string(description) }
            if let repos = peer.repos { body["repos"] = .array(repos.map(AgentKit.JSONValue.string)) }
            _ = try await call("PUT", "peers/\(try Self.peerID(peer.id))", .object(body), what: "the workspace \(peer.name)")
        }
        for id in there where !kept.contains(where: { $0.id == id }) {
            let (status, data) = try await request("DELETE", "peers/\(try Self.peerID(id))", nil, what: "the workspace \(id)")
            if status != 404 { _ = try Self.read(status, data) }
        }
    }

    /// The peer call proposal `id` waits for, from strut's record; nil for
    /// a proposal of another step. Throws when it cannot be read, is no
    /// longer pending, or names a peer strut has not got: the card is then
    /// refused, never shown in other words.
    public func peerRequest(proposal id: String) async throws -> PeerRequest? {
        guard id.range(of: #"^[A-Za-z0-9_-]{1,64}$"#, options: .regularExpression) != nil else {
            throw PeelError("That is not a proposal id strut gives.")
        }
        let proposal = try await call("GET", "proposals/\(id)", what: "the proposal")
        guard proposal["status"] == "pending" else { throw PeelError("strut's proposal is no longer waiting.") }
        guard proposal["step"]?.string == DeviceActions.peerTool else { return nil }
        guard let peer = proposal["input"]?["peer"]?.string else { throw PeelError("strut's proposal names no workspace.") }
        let peers = try await call("GET", "peers", what: "the workspaces")["peers"]?.array ?? []
        guard let record = peers.first(where: { $0["id"]?.string == peer }) else {
            throw PeelError("strut has no workspace \u{201C}\(TextLine.clean(peer, max: 40))\u{201D}.")
        }
        let input = proposal["input"]?["input"]
        return PeerRequest(peer: peer, name: HivePeer.name(label: record["label"]?.string, id: peer),
                           workflow: proposal["input"]?["workflow"]?.string ?? "orchestrator",
                           prompt: input?["prompt"]?.string,
                           more: !Set(input?.object?.keys ?? [:].keys).subtracting(["prompt", "session"]).isEmpty
                               || !Set(proposal["input"]?.object?.keys ?? [:].keys).subtracting(Self.peerCallKeys).isEmpty)
    }

    /// What a call to an org may hold beside its message for the card to
    /// show it all: not `params`, `version` or a `job` there.
    static let peerCallKeys: Set<String> = ["peer", "workflow", "input", "wait", "room"]

    /// A peer id as one path segment: strut's own form.
    static func peerID(_ id: String) throws -> String {
        guard AgentArtifact.Handle.isPeerID(id) else {
            throw PeelError("\u{201C}\(TextLine.clean(id, max: 40))\u{201D} is not a workspace id Peel can use.")
        }
        return id
    }
}
