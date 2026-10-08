import Foundation
import PeelCore

extension Invocation {
    /// Runs `command` if it is a call command. False if it is not one.
    mutating func calls(_ command: String) async throws -> Bool {
        switch command {
        case "call-start":
            guard let pubkey = arguments.next() else { throw PeelError("call-start needs a pubkey") }
            let session = try await Session(load()).connect(insecure: insecure)
            let call = try await session.engine.startCall(in: pubkey, audioOnly: audioOnly)
            print("call: \(call.link.url.absoluteString)")
            try await session.finish(after: wait)

        case "call-ticket", "call-who":
            guard let target = arguments.next() else { throw PeelError("\(command) needs a message id or a call link") }
            let engine = try await load()
            let (link, chat) = try await callLink(target, engine: engine)
            if command == "call-ticket" {
                // The token is a bearer credential: never printed, only whether there is one.
                let ticket = try await engine.callTicket(for: link, in: chat)
                print("server: \(ticket.serverURL.absoluteString)")
                print("room: \(ticket.room)")
                print("identity: \(ticket.identity)")
                print("expires: \(ticket.expires.formatted(.iso8601)) (in \(Int(ticket.expires.timeIntervalSinceNow)) s)")
                print("room admin: \(ticket.roomAdmin ? "yes" : "no")")
                print("token: obtained (\(ticket.token.utf8.count) bytes, not shown)")
            } else {
                let presence = try await engine.callPresence(of: link)
                let printer = Task {
                    for await state in presence { print(describe(state)) }
                }
                try await Task.sleep(for: .seconds(wait))
                printer.cancel()
            }
            await engine.close()

        default:
            return false
        }
        return true
    }
}

/// The call a stored message links to (with its chat), or a link given
/// as is, checked against the account's call server.
func callLink(_ target: String, engine: Engine) async throws -> (CallLink, String?) {
    if let id = Int64(target) {
        guard let message = try engine.storage.message(id: id), let link = await engine.callLink(in: message) else {
            throw PeelError("message \(id) is not a call on this account's call server")
        }
        return (link, message.chat)
    }
    guard let link = try await CallLink(message: target, server: engine.callServer()) else {
        throw PeelError("not a call link on this account's call server")
    }
    return (link, nil)
}

func describe(_ presence: CallPresence) -> String {
    switch presence {
    case .unknown: "presence: not known"
    case .ended: "presence: call ended"
    case .live(let people) where people.isEmpty: "presence: no one on the call"
    case .live(let people):
        "presence: \(people.count) on the call: "
            + people.map { "\($0.nickname.isEmpty ? "?" : $0.nickname) (\($0.identity)\($0.avatarURL.map { ", \($0.absoluteString)" } ?? ""))" }
            .joined(separator: ", ")
    }
}
