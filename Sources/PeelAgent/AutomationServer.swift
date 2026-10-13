import Foundation
import Security
import NIOCore
import NIOHTTP1
import NIOPosix
import PeelCore

/// Where strut reaches Peel when an automation fires
/// (`docs/phases/12-automations.md`): `POST /automations/run` on this Mac
/// only, with the bearer token it is given (one per account open, in memory
/// only), which strut keeps in its encrypted secret store
/// (`AutomationsClient.install`). Each request is one run,
/// answered when it ends; runs of different automations may overlap
/// (strut never overlaps two of the same one).
public final class AutomationServer: Sendable {
    public typealias Handler = @Sendable (AutomationRequest) async -> AutomationReply

    public let port: Int
    /// What strut must send as `Authorization: Bearer …`.
    public let token: String
    private let channel: any Channel

    /// The most a request may be: a prompt and a few short fields.
    static let requestLimit = 64_000
    static let path = "/automations/run"

    private init(channel: any Channel, port: Int, token: String) {
        self.channel = channel
        self.port = port
        self.token = token
    }

    /// Listens on 127.0.0.1 at `port` (0 for any free one) until `stop`.
    public static func start(port: Int, token: String, handler: @escaping Handler) async throws -> AutomationServer {
        guard !token.isEmpty else { throw PeelError("The automation server needs a token.") }
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                    try channel.pipeline.syncOperations.addHandler(RequestHandler(token: token, handler: handler))
                }
            }
            .bind(host: "127.0.0.1", port: port).get()
        return AutomationServer(channel: channel, port: channel.localAddress?.port ?? port, token: token)
    }

    public func stop() async {
        try? await channel.close()
    }

    /// 32 random bytes as hex: a token, or a strut's keys (`BundledStrut`).
    public static func newKey() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw PeelError("could not make a key")
        }
        return bytes.hex
    }

    /// The reply to a request already read whole, before any run: nil when
    /// it is a run to start.
    static func refusal(method: String, uri: String, authorization: String?, token: String,
                        bodySize: Int) -> (status: Int, reply: AutomationReply)? {
        guard uri == path else { return (404, .failed("Nothing here but POST \(path).")) }
        guard method == "POST" else { return (405, .failed("Only POST.")) }
        guard let authorization, matches(authorization, "Bearer " + token) else {
            return (401, .failed("The token is missing or wrong."))
        }
        guard bodySize <= requestLimit else { return (413, .failed("The request is too large.")) }
        return nil
    }

    /// Compares in time that does not depend on where they differ.
    static func matches(_ given: String, _ expected: String) -> Bool {
        let a = Array(given.utf8), b = Array(expected.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// The HTTP status for how a run ended: strut fails a run on any other
    /// than 2xx, so a failed run shows as one in its history.
    static func status(of reply: AutomationReply) -> Int {
        reply.status == .failed ? 500 : 200
    }
}

/// One connection's requests, one at a time: the head and body read whole,
/// then the run, then the reply, and the connection closed.
private final class RequestHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let token: String
    private let handler: AutomationServer.Handler
    private var head: HTTPRequestHead?
    private var body = ByteBuffer()
    private var bodySize = 0

    init(token: String, handler: @escaping AutomationServer.Handler) {
        self.token = token
        self.handler = handler
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            self.head = head
            body.clear()
            bodySize = 0
        case .body(var part):
            bodySize += part.readableBytes
            // Past the limit nothing more is kept; the end refuses it.
            if bodySize <= AutomationServer.requestLimit { body.writeBuffer(&part) }
        case .end:
            guard let head else { return }
            self.head = nil
            if let (status, reply) = AutomationServer.refusal(
                method: head.method.rawValue, uri: head.uri, authorization: head.headers.first(name: "Authorization"),
                token: token, bodySize: bodySize) {
                return respond(context, status, reply)
            }
            guard let request = try? JSONDecoder().decode(AutomationRequest.self, from: Data(buffer: body)) else {
                return respond(context, 400, .failed("The request is not an automation run."))
            }
            let handler = handler
            let promise = context.eventLoop.makePromise(of: AutomationReply.self)
            promise.completeWithTask { await handler(request) }
            promise.futureResult.assumeIsolated().whenSuccess { reply in
                self.respond(context, AutomationServer.status(of: reply), reply)
            }
        }
    }

    private func respond(_ context: ChannelHandlerContext, _ status: Int, _ reply: AutomationReply) {
        let data = (try? JSONEncoder().encode(reply)) ?? Data("{}".utf8)
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
        headers.add(name: "Content-Length", value: String(data.count))
        headers.add(name: "Connection", value: "close")
        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: HTTPResponseStatus(statusCode: status), headers: headers))), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(context.channel.allocator.buffer(bytes: data)))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).assumeIsolated().whenComplete { _ in
            context.close(promise: nil)
        }
    }
}
