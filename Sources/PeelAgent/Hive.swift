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

    /// One of Peel's own strut's proposals, as strut records it: the card
    /// the Mac draws for the bridge's `proposal:<id>` request; gone when
    /// strut has none. Throws when strut does not answer, or answers with
    /// what is not that record.
    public func readProposal(_ id: String) async throws -> ProposalRead {
        guard ProposalRecord.isID(id) else { throw PeelError("That is not a proposal id strut gives.") }
        let (status, data) = try await request("GET", "proposals/\(id)", nil, what: "the proposal")
        switch status {
        case 404: return .gone
        case 403: return .forbidden
        case 200..<300: break
        default: _ = try Self.read(status, data)
        }
        let record = try ProposalRecord(strut: data)
        guard record.id == id else { throw ProposalRefused("strut answered for another proposal.") }
        return .record(record)
    }

    /// The call a hand-off `proposal` (`ProposalRecord.isHandOff`) makes,
    /// worded for its card: the org by its record's label on this strut
    /// (`GET /peers`). Throws for one naming a peer strut has not got.
    public func peerRequest(from proposal: ProposalRecord) async throws -> PeerRequest {
        guard case .object(let call)? = proposal.input, let peer = call["peer"]?.string else {
            throw PeelError("strut's proposal names no workspace.")
        }
        let peers = try await self.call("GET", "peers", what: "the workspaces")["peers"]?.array ?? []
        guard let record = peers.first(where: { $0["id"]?.string == peer }) else {
            throw PeelError("strut has no workspace \u{201C}\(TextLine.clean(peer, max: 40))\u{201D}.")
        }
        var inputKeys: Set<String> = []
        var prompt: String?
        if case .object(let input)? = call["input"] {
            inputKeys = Set(input.keys)
            prompt = input["prompt"]?.string
        }
        return PeerRequest(peer: peer, name: HivePeer.name(label: record["label"]?.string, id: peer),
                           workflow: call["workflow"]?.string ?? "orchestrator",
                           prompt: prompt,
                           more: !inputKeys.subtracting(["prompt", "session"]).isEmpty
                               || !Set(call.keys).subtracting(Self.peerCallKeys).isEmpty)
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
