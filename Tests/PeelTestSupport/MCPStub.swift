import Foundation
import Synchronization

/// A stand-in MCP server over Streamable HTTP (JSON answers, no stream), as
/// strut's MCP client speaks to one: `initialize`, `tools/list` with one
/// read-only tool and one that writes, and `tools/call`, each call recorded
/// with the bearer it came with. For Connections' tests and journeys.
final class MCPStub: Sendable {
    let http: HTTPStub
    private final class Calls: Sendable {
        let list = Mutex<[(tool: String, arguments: String, bearer: String?)]>([])
    }
    private let made = Calls()
    var port: UInt16 { http.port }
    var url: URL { URL(string: "http://127.0.0.1:\(http.port)/mcp")! }
    /// Each `tools/call`: the tool, its arguments as JSON, and the bearer.
    var calls: [(tool: String, arguments: String, bearer: String?)] { made.list.withLock { $0 } }
    /// Every request's bearer, in order.
    var bearers: [String?] {
        http.requests.map { request in
            request.split(separator: "\r\n").first { $0.lowercased().hasPrefix("authorization: bearer ") }.map { String($0.dropFirst(22)) }
        }
    }

    init() async throws {
        let made = made
        http = try await HTTPStub { _, request in
            guard request.hasPrefix("POST ") else { return (405, "") }
            let body = String(request[(request.range(of: "\r\n\r\n")?.upperBound ?? request.endIndex)...])
            guard let message = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
                  let method = message["method"] as? String else { return (400, "{}") }
            guard let id = message["id"] else { return (202, "") }
            let params = message["params"] as? [String: Any] ?? [:]
            let result: Any
            switch method {
            case "initialize":
                result = ["protocolVersion": params["protocolVersion"] ?? "2025-03-26", "capabilities": ["tools": [:]],
                          "serverInfo": ["name": "stand-in", "version": "1"]]
            case "tools/list":
                result = ["tools": [
                    ["name": "list_issues", "description": "Your open issues", "inputSchema": ["type": "object", "properties": [:]],
                     "annotations": ["readOnlyHint": true]],
                    ["name": "create_issue", "description": "Make an issue",
                     "inputSchema": ["type": "object", "properties": ["title": ["type": "string"]], "required": ["title"]]],
                ]]
            case "tools/call":
                let name = params["name"] as? String ?? ""
                let arguments = (try? JSONSerialization.data(withJSONObject: params["arguments"] ?? [:])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                let bearer = request.split(separator: "\r\n").first { $0.lowercased().hasPrefix("authorization: bearer ") }.map { String($0.dropFirst(22)) }
                made.list.withLock { $0.append((name, arguments, bearer)) }
                result = ["content": [["type": "text", "text": name == "list_issues" ? "PEEL-1 Ship the Connections screen" : "Made PEEL-2"]]]
            default:
                return (200, Self.json(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "no \(method)"]]))
            }
            return (200, Self.json(["jsonrpc": "2.0", "id": id, "result": result]))
        }
    }

    func stop() { http.stop() }

    private static func json(_ object: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: object)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
