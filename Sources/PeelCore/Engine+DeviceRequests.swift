import Foundation

// The device side of the device channel (docs/agent-on-strut.md, "The device
// channel"): the agent asks this device for what only it can do with a
// `request` in the agent's DM; the device stores it, acks it, does it once
// through the handler the app gives it, and sends the `result`. A repeat of
// the request is answered from the ledger (`deviceRequest`), never done
// again. Only requests from the agent contact (`Setting.deviceAgent`) that
// name this device are answered; anything else gets nothing back.

/// What a device request came to: its status, and the text of its result
/// or why there is none.
public struct DeviceAnswer: Sendable, Equatable {
    public var status: ControlEnvelope.Status
    public var text: String?
    public var error: String?

    init(status: ControlEnvelope.Status, text: String? = nil, error: String? = nil) {
        self.status = status
        self.text = text
        self.error = error
    }

    public static func done(_ text: String) -> Self { Self(status: .done, text: text) }
    public static func failed(_ error: String) -> Self { Self(status: .failed, error: error) }
    static let expired = Self(status: .expired)
}

/// Does one request, of `kind` with `args`, and says how it went. It
/// decides which kinds it knows: one it does not is `failed`, said plainly,
/// since the bridge passes any kind on.
public typealias DeviceRequestHandler = @Sendable (_ kind: String, _ args: JSONValue) async -> DeviceAnswer

extension Engine {
    /// The most a result's envelope may take, as JSON (open question 4): a
    /// catch-up is 10 to 20 KB. Larger is answered `failed`, never cut,
    /// so the chat data's end marker always arrives.
    static let maxResultBytes = 32 * 1024
    /// How long a request is remembered after it expires: the agent asks
    /// again only until then.
    static let deviceRequestsKept: Int64 = 7 * 24 * 3600

    /// Answers the agent's device requests with `handler` from now on; nil,
    /// none. Only the Mac answers in Phase 1.
    public func answerDeviceRequests(with handler: DeviceRequestHandler?) {
        deviceRequestHandler = handler
    }

    /// Sets the agent contact whose requests this device answers; nil or
    /// empty, none.
    public func setDeviceAgent(_ pubkey: String?) throws {
        try storage.set(pubkey ?? "", for: .deviceAgent)
    }

    public var deviceAgent: String? {
        (try? storage.value(for: .deviceAgent))?.nilIfEmpty
    }

    /// A message just stored in the agent's DM: answered if it is the
    /// agent's request to this device, signed by the agent. One for another
    /// device, or anything else, is left alone, with nothing sent back. A
    /// copy seen before (history brings stored messages back) is not
    /// answered again; a new copy of a done request gets its stored answer.
    func answerDeviceRequest(in message: Message, from agent: String) async {
        guard deviceRequestHandler != nil, !message.fromMe, tribes[message.chat] == nil, message.chat == agent,
              message.senderInfo?.pubkey == agent, let uuid = message.uuid else { return }
        let now = Date()
        let fresh: DeviceRequestRow
        switch message.control {
        case .envelope(let request) where request.op == .request && request.device == deviceID:
            guard let id = request.id, let kind = request.kind, let notAfter = request.notAfter,
                  Self.isRequestID(id), Self.isKind(kind),
                  let args = try? (request.args ?? .object([:])).text else { return }
            let expired = notAfter < Int64(now.timeIntervalSince1970)
            fresh = DeviceRequestRow(
                agent: agent, id: id, kind: kind, args: args, notAfter: notAfter, state: expired ? .done : .received,
                status: expired ? .expired : nil, receivedAt: now.millisecondsSince1970
            )
        case .unsupported:
            // A version or shape this Peel does not read: it says so rather
            // than guess, and does nothing.
            guard let id = Self.unreadableRequestID(in: message.body, device: deviceID) else { return }
            fresh = DeviceRequestRow(
                agent: agent, id: id, kind: "", args: "{}", notAfter: Int64(now.timeIntervalSince1970), state: .done,
                status: .failed, error: "unsupported", receivedAt: now.millisecondsSince1970
            )
        default:
            return
        }
        do {
            let (row, newCopy) = try storage.admit(fresh, copy: uuid)
            guard newCopy else { return }
            // Stored, then acked, then done, off the inbound queue; one
            // stored already is answered as it stands: its result once done,
            // an ack while not.
            if row.state == .done {
                try await sendAnswer(row)
                return
            }
            _ = try await sendDeviceControl(ControlEnvelope(op: .ack, re: row.id), text: Self.ackLine, to: agent)
            startRequest(row.id, of: agent)
        } catch {
            reportRequestError(error)
        }
    }

    /// Does a stored request in the background, unless it is being done
    /// already here.
    private func startRequest(_ id: String, of agent: String) {
        guard deviceRequestHandler != nil, answeringRequests.insert(id).inserted else { return }
        Self.background { [weak self] in await self?.run(id, of: agent) }
    }

    /// Claims the request, does it through the handler (or answers `expired`
    /// past its time), records the answer and sends it.
    private func run(_ id: String, of agent: String) async {
        defer { answeringRequests.remove(id) }
        do {
            guard let handler = deviceRequestHandler, let row = try storage.claimDeviceRequest(id, of: agent) else { return }
            let answer = row.notAfter < Int64(Date().timeIntervalSince1970)
                ? .expired
                : Self.fitted(await handler(row.kind, JSONValue(text: row.args) ?? .object([:])), re: id)
            guard let done = try storage.finishDeviceRequest(id, of: agent, with: answer) else { return }
            try await sendAnswer(done)
        } catch {
            reportRequestError(error)
        }
    }

    /// Sends a done request's answer, and records that it went.
    private func sendAnswer(_ row: DeviceRequestRow) async throws {
        let status = row.status ?? .unknown
        let envelope = Self.result(re: row.id, status: status, text: row.result, error: row.error)
        if try await sendDeviceControl(envelope, text: Self.line(for: status), to: row.agent), !row.sent {
            try storage.markDeviceRequestSent(row.id, of: row.agent)
        }
    }

    /// A control message the device sends by itself, and whether it went:
    /// a send that failed is stored as failed rather than thrown.
    private func sendDeviceControl(_ envelope: ControlEnvelope, text: String, to agent: String) async throws -> Bool {
        guard isContact(agent) else { throw Failure.notAContact }
        let tag = try await deliver(body: try Self.controlBody(envelope, text: text), to: agent, replacing: nil, auto: true)
        return try tag.flatMap { try storage.message(tag: $0) }.map { $0.delivery != .failed } ?? false
    }

    /// After the connection comes back, on that connection: finishes the
    /// current agent's requests a stop cut short (stored, never done;
    /// `run` answers `expired` for those past their time), sends the
    /// answers that did not go, and forgets old requests. Reads are safe to
    /// do again; a send found running will need `unknown` instead (PR 3).
    func answerOwedDeviceRequests(on connection: Transport) async {
        guard deviceRequestHandler != nil, let agent = deviceAgent else { return }
        try? storage.forgetDeviceRequests(expiredBefore: Int64(Date().timeIntervalSince1970) - Self.deviceRequestsKept)
        guard let owed = try? storage.owedDeviceRequests(of: agent) else { return }
        for row in owed {
            guard transport === connection, !Task.isCancelled else { return }
            if row.state != .done {
                startRequest(row.id, of: agent)
                continue
            }
            do {
                try await sendAnswer(row)
            } catch {
                reportRequestError(error)
            }
        }
    }

    private func reportRequestError(_ error: any Error) {
        emit.yield(.coreError("answering the agent's request: \(PeelError.readable(error))"))
    }

    // MARK: - The envelope

    static func result(re id: String, status: ControlEnvelope.Status, text: String?, error: String?) -> ControlEnvelope {
        ControlEnvelope(op: .result, re: id, status: status, result: text.map { .object(["text": .string($0)]) }, error: error)
    }

    /// `answer`, or a failure when its result is too large to send.
    static func fitted(_ answer: DeviceAnswer, re id: String) -> DeviceAnswer {
        // Escaped, a byte takes at most six: well under, nothing to measure.
        guard (answer.text?.utf8.count ?? 0) * 6 > maxResultBytes else { return answer }
        let envelope = result(re: id, status: answer.status, text: answer.text, error: answer.error)
        guard let size = try? JSONEncoder().encode(envelope).count, size > maxResultBytes else { return answer }
        return .failed("the result is too large to send (\(size / 1024) KB); ask for less: one chat, or a lower limit")
    }

    /// The bridge's own rules (runner `device.rs`, `valid_id` and
    /// `valid_kind`): a request it would not send is not the agent's.
    static func isRequestID(_ id: String) -> Bool { isToken(id, max: 128, punctuation: "-_.:/") }

    static func isKind(_ kind: String) -> Bool { isToken(kind, max: 64, punctuation: "._-") }

    /// One to `max` ASCII letters, digits and `punctuation`.
    private static func isToken(_ text: String, max: Int, punctuation: String) -> Bool {
        (1...max).contains(text.utf8.count) && text.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || punctuation.unicodeScalars.contains($0))
        }
    }

    /// The id of a request this Peel cannot read (`ControlMessage.unsupported`)
    /// that names this device, so it can say it does not read it.
    static func unreadableRequestID(in body: String?, device: String) -> String? {
        guard let peel = ControlMessage.peel(in: body), peel["op"]?.string == "request", peel["device"]?.string == device,
              let id = peel["id"]?.string, isRequestID(id) else { return nil }
        return id
    }

    // MARK: - The lines the official apps show

    static let ackLine = "Peel on your Mac is on it"

    static func line(for status: ControlEnvelope.Status) -> String {
        switch status {
        case .done: "Peel on your Mac answered"
        case .denied: "You said no on your Mac"
        case .expired: "Peel on your Mac: too late, nothing done"
        case .failed: "Peel on your Mac could not do it"
        case .unknown: "Peel on your Mac cannot tell whether it was done"
        }
    }
}
