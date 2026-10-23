import Foundation
import Network
import os

/// A loopback HTTP server that answers every request with one cacheable,
/// cookie-setting JSON reply (200, or the `status` given), or one made from
/// the request, and records each whole request (head and body). Serves the call server's tickets and the tribes registry in the
/// PeelCore tests, and strut's endpoints in the PeelAgent tests.
final class HTTPStub: Sendable {
    private let listener: NWListener
    private let heads = OSAllocatedUnfairLock(initialState: [String]())
    let port: UInt16

    /// Every request so far, in the order each arrived whole.
    var requests: [String] { heads.withLock { $0 } }

    convenience init(status: Int = 200, body: @escaping @Sendable (UInt16) -> String) async throws {
        try await self.init(status: status, reply: { port, _ in body(port) })
    }

    /// One that answers each request by what it asked (`reply` is given
    /// the port and the whole request), as `contentType`.
    convenience init(status: Int = 200, contentType: String = "application/json",
                     reply body: @escaping @Sendable (UInt16, String) -> String) async throws {
        try await self.init(contentType: contentType, respond: { port, request in (status, body(port, request)) })
    }

    /// One whose answer to each request, its status too, is made from what
    /// it asked: an API whose refusals are statuses (Hive's).
    init(contentType: String = "application/json",
         respond: @escaping @Sendable (UInt16, String) -> (status: Int, body: String)) async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let record: @Sendable (String) -> Void = { [heads] head in heads.withLock { $0.append(head) } }
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            Self.read(connection, Data()) { request in
                let text = String(decoding: request, as: UTF8.self)
                record(text)
                let (status, body) = respond(listener.port?.rawValue ?? 0, text)
                let response = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Refused")\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.utf8.count)\r\n"
                    + "Cache-Control: max-age=3600\r\nSet-Cookie: stub=1; Path=/\r\nConnection: close\r\n\r\n" + body
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        port = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: .global())
        }
        self.listener = listener
    }

    func stop() { listener.cancel() }

    /// Reads until the head and as much body as its Content-Length says
    /// have come (a client may send them apart), or the connection ends.
    private static func read(_ connection: NWConnection, _ sofar: Data, then: @escaping @Sendable (Data) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
            let request = sofar + (data ?? Data())
            if complete || error != nil || isWhole(request) { return then(request) }
            read(connection, request, then: then)
        }
    }

    private static func isWhole(_ request: Data) -> Bool {
        guard let end = request.range(of: Data("\r\n\r\n".utf8)) else { return false }
        let head = String(decoding: request[..<end.lowerBound], as: UTF8.self).lowercased()
        let length = head.components(separatedBy: "\r\n").first { $0.hasPrefix("content-length:") }
            .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
        return request.count - end.upperBound >= length
    }
}
