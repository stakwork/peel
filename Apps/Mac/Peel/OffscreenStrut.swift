#if os(macOS) && DEBUG
import Foundation
import Network
import os
import PeelCore

/// Offscreen only: a workspace's strut standing in on this Mac for the
/// driver's `proposal` steps (`OffscreenDriver`), with the proposals
/// strut's `GET /proposals?status=pending`, `GET /proposals/:id` and
/// `POST /proposals/:id/decide` answer (specs/API.md §12), over fixture
/// records of every shape a card draws: strut's card with a warning field,
/// one from before a card, a record whose fields leave the input out, and
/// another person's, which must never show. An accept applies the record
/// (or fails one, so Failed is drawn); a reject rejects it; one decided in
/// Stadeum meanwhile answers 409 with the record.
final class OffscreenStrut: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var records: [String: String]
    /// The ids in the order the fixtures list them.
    private let order: [String]
    private(set) var port: UInt16 = 0

    /// The person every fixture but `kates` is proposed for.
    static let actor = "tom"

    /// One listening on a free port of this Mac, holding the fixtures.
    static func start() throws -> OffscreenStrut {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let strut = OffscreenStrut(listener: try NWListener(using: parameters))
        try strut.listen()
        return strut
    }

    private init(listener: NWListener) {
        self.listener = listener
        // Ids of this run's own, so what a development profile kept of an
        // earlier run's fixtures never stands for these.
        let run = String(UUID().uuidString.prefix(6).lowercased())
        let fixtures = Self.fixtures.map { (id: "\($0.id)-\(run)", json: $0.json.replacingOccurrences(of: "\"id\":\"\($0.id)\"", with: "\"id\":\"\($0.id)-\(run)\"")) }
        order = fixtures.map(\.id)
        records = Dictionary(uniqueKeysWithValues: fixtures.map { ($0.id, $0.json) })
    }

    private func listen() throws {
        let listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            guard let strut = self else { return connection.cancel() }
            connection.start(queue: .global())
            Self.read(connection, Data()) { request in
                let text = String(decoding: request, as: UTF8.self)
                let (status, body) = strut.answer(text)
                let reply = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: application/json\r\n"
                    + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
                connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        let ready = DispatchSemaphore(value: 0)
        let bound = OSAllocatedUnfairLock<UInt16>(initialState: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                bound.withLock { $0 = listener.port?.rawValue ?? 0 }
                ready.signal()
            } else if case .failed = state {
                ready.signal()
            }
        }
        listener.start(queue: .global())
        ready.wait()
        port = bound.withLock { $0 }
        guard port != 0 else { throw PeelError("the stand-in strut could not listen") }
    }

    func stop() { listener.cancel() }

    private static func read(_ connection: NWConnection, _ sofar: Data, _ done: @escaping @Sendable (Data) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            var request = sofar
            if let data { request.append(data) }
            let text = String(decoding: request, as: UTF8.self)
            if let headEnd = text.range(of: "\r\n\r\n") {
                let head = text[..<headEnd.lowerBound]
                let length = head.split(separator: "\r\n").lazy.compactMap { line -> Int? in
                    let parts = line.split(separator: ":", maxSplits: 1)
                    guard parts.count == 2, parts[0].lowercased() == "content-length" else { return nil }
                    return Int(parts[1].trimmingCharacters(in: .whitespaces))
                }.first ?? 0
                if text[headEnd.upperBound...].utf8.count >= length || isComplete || error != nil { return done(request) }
            } else if isComplete || error != nil {
                return done(request)
            }
            read(connection, request, done)
        }
    }

    /// strut's answer to one request.
    private func answer(_ request: String) -> (Int, String) {
        let line = request.prefix { $0 != "\r" }
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return (400, "{}") }
        let body = request[(request.range(of: "\r\n\r\n")?.upperBound ?? request.endIndex)...]
        return lock.withLock {
            if parts[0] == "GET", parts[1].hasPrefix("/proposals?status=pending") {
                let pending = order.compactMap { records[$0] }.filter { $0.contains(#""status":"pending""#) }
                return (200, #"{"proposals":[\#(pending.joined(separator: ","))]}"#)
            }
            let path = parts[1].split(separator: "/").map(String.init)
            guard path.count >= 2, path[0] == "proposals", let record = records[path[1]] else { return (404, #"{"error":"No proposal"}"#) }
            if parts[0] == "GET" { return (200, record) }
            guard parts[0] == "POST", path.count == 3, path[2] == "decide" else { return (404, "{}") }
            guard record.contains(#""status":"pending""#) else { return (409, #"{"error":"decided","proposal":\#(record)}"#) }
            let accept = body.contains(#""action":"accept""#)
            var after: String
            if path[1].hasPrefix("install-pkg-02") {
                // Decided in Stadeum first, as far as this strut is concerned.
                after = record.replacingOccurrences(of: #""status":"pending""#, with: #""status":"rejected""#)
                records[path[1]] = after
                return (409, #"{"error":"Proposal is rejected","proposal":\#(after)}"#)
            }
            if accept, path[1].hasPrefix("delete-node-03") {
                after = record.replacingOccurrences(of: #""status":"pending""#, with: #""status":"failed""#)
                    .replacingOccurrences(of: #""createdAt""#, with: #""result":{"error":"graph/delete-node: node n1 is referenced by 3 edges strut could not delete","at":"2026-10-31T10:06:00Z"},"createdAt""#)
            } else {
                after = record.replacingOccurrences(of: #""status":"pending""#, with: #""status":"\#(accept ? "applied" : "rejected")""#)
                    .replacingOccurrences(of: #""createdAt""#, with: #""decision":{"action":"\#(accept ? "accept" : "reject")","by":"tom","at":"2026-10-31T10:05:00Z"},"result":{"at":"2026-10-31T10:05:03Z"},"createdAt""#)
            }
            records[path[1]] = after
            return (200, after)
        }
    }

    /// The fixture records, as strut writes them (`src/proposals.ts`).
    private static let fixtures: [(id: String, json: String)] = [
        ("install-pkg-01", #"""
        {"id":"install-pkg-01","step":"package/install","input":{"package":"acme/linear"},
         "rationale":"You asked to track Linear issues from here.","title":"Install the package acme/linear",
         "summary":"acme/linear 1.0.0 (MIT) from acme — key abcdefgh…uvwxyz, listed by the index main; digest 3f9a1c2b7d4e.\nIt brings 1 app (Linear), 2 workflows, 1 step — TypeScript that runs inside this strut.\nIt can act (a step changes something outside the run); run code (its own TypeScript, or exec).\nIt needs the secret LINEAR_KEY.",
         "card":{"v":1,"title":"Install the package acme/linear","fields":[
            {"label":"Version and license","value":"1.0.0 (MIT)"},{"label":"Publisher key","value":"abcdefgh…uvwxyz","kind":"code"},
            {"label":"Brings","value":"1 app (Linear), 2 workflows, 1 step"},{"label":"Needs","value":"LINEAR_KEY"},
            {"label":"Runs code","value":"Yes: its own TypeScript, or exec","danger":true}],
          "actions":{"accept":"Install","reject":"Don't install"},"full":true},
         "status":"pending","createdAt":"2026-10-31T10:00:00Z",
         "by":{"workflow":"orchestrator","runId":"r1","path":"orchestrator/agent/t3","actor":"tom"}}
        """#),
        ("install-pkg-02", #"""
        {"id":"install-pkg-02","step":"app/grant","input":{"name":"todo"},
         "title":"Let app todo talk to the assistant as whoever opens it",
         "card":{"v":1,"title":"Let app todo talk to the assistant as whoever opens it","fields":[
            {"label":"App","value":"todo","kind":"ref","danger":true},{"label":"Runs","value":"orchestrator, as whoever opens the app","danger":true}],
          "actions":{"accept":"Grant","reject":"Don't grant"},"full":true},
         "status":"pending","createdAt":"2026-10-31T10:01:00Z",
         "by":{"workflow":"orchestrator","runId":"r2","path":"orchestrator/agent/t1","actor":"tom"}}
        """#),
        ("delete-node-03", #"""
        {"id":"delete-node-03","step":"graph/delete-node","input":{"ref_id":"n1"},
         "rationale":"The Concept is a duplicate of Rate limits.","title":"Delete node Throttling",
         "card":{"v":1,"title":"Delete node Throttling","fields":[
            {"label":"Node","value":"Throttling","kind":"ref","danger":true},{"label":"Edges","value":"Every edge it has is deleted too","danger":true}],
          "actions":{"accept":"Delete","reject":"Keep"},"full":true},
         "status":"pending","createdAt":"2026-10-31T10:02:00Z",
         "by":{"workflow":"orchestrator","runId":"r3","path":"orchestrator/agent/t2","actor":"tom"}}
        """#),
        ("old-concept-04", #"""
        {"id":"old-concept-04","step":"graph/create-node",
         "input":{"node_type":"Concept","node_data":{"name":"Rate limits","description":"How the API throttles callers","docs":"\#(String(repeating: "The window is sixty seconds; a burst above the limit is answered 429 and retried with backoff. ", count: 8))"}},
         "rationale":"You asked me to write down what we learned about the API.","title":"Create a node in the strut knowledge graph.",
         "status":"pending","createdAt":"2026-10-31T10:03:00Z",
         "by":{"workflow":"orchestrator","runId":"r4","path":"orchestrator/agent/t5","actor":"tom"}}
        """#),
        ("kates-record-05", #"""
        {"id":"kates-record-05","step":"package/install","input":{"package":"acme/secret"},"title":"Install the package acme/secret",
         "status":"pending","createdAt":"2026-10-31T10:04:00Z",
         "by":{"workflow":"orchestrator","runId":"r5","path":"orchestrator/agent/t1","actor":"kate"}}
        """#),
    ]
}
#endif
