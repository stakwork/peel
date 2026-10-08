import Foundation
import PeelCore

extension Invocation {
    /// Runs `command` if it is a contacts command: adding by code or QR
    /// picture, and invites with sats. False if it is not one.
    mutating func contacts(_ command: String) async throws -> Bool {
        switch command {
        case "add":
            guard let input = arguments.next() else { throw PeelError("add needs contact info, a link or a picture") }
            let code = try Self.code(in: input)
            let session = try await Session(load()).connect(insecure: insecure)
            let (pubkey, added) = try await session.engine.addContact(code: code, alias: arguments.next())
            print(added ? "adding \(pubkey)" : "already a contact: \(pubkey)")
            try await session.finish(after: wait)

        case "scan":
            guard let path = arguments.next() else { throw PeelError("scan needs a picture") }
            let codes = try QRImage.codes(inFile: URL(fileURLWithPath: path))
            if codes.isEmpty { print("no QR code found") }
            for text in codes {
                print(Self.describe(text))
            }

        case "invite":
            guard let msat = try arguments.next().map(satsArgument) else { throw PeelError("invite needs an amount in sats") }
            let session = try await Session(load()).connect(insecure: insecure)
            var made: InviteRecord?
            try await confirming(confirmed) {
                made = try await session.engine.makeInvite(
                    amountMsat: msat, nickname: nickname, message: inviteMessage, confirmedMsat: $0
                )
            }
            if let made {
                print("invite \(made.code.prefix(12)) for \(Sats.format(msat: made.amountMsat)) (the server may keep a fee)")
                print(made.link)
            }
            try await session.finish(after: wait)

        case "invites":
            let storage = try readOnlyStorage()
            let invites = try storage.listPendingInvites()
            if invites.isEmpty { print("no invites waiting") }
            for invite in invites {
                let name = invite.nickname.map { "  \($0)" } ?? ""
                print("\(invite.code)  \(invite.status.rawValue)  \(Sats.format(msat: invite.amountMsat))\(name)")
            }

        case "invite-cancel":
            guard let code = arguments.next() else { throw PeelError("invite-cancel needs an invite's code") }
            let session = try await Session(load()).connect(insecure: insecure)
            let invite = try await session.engine.cancelInvite(code: code)
            print("cancelled; \(Sats.format(msat: invite.amountMsat)) back, less any fee the server kept")
            try await session.finish(after: wait)

        default:
            return false
        }
        return true
    }

    /// What `add` was given: a code, or a picture holding one (with several,
    /// the first that names someone, as the app takes).
    private static func code(in input: String) throws -> String {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: input, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return input
        }
        guard let code = ContactCode.likeliest(in: try QRImage.codes(inFile: URL(fileURLWithPath: input))) else {
            throw PeelError("no QR code found in \(input)")
        }
        return code
    }

    /// One scanned code: what it is and who it names, never an invite's code.
    private static func describe(_ text: String) -> String {
        do {
            let code = try ContactCode.read(text)
            switch code {
            case .contact(let info): return "contact info: \(info)"
            case .invite:
                return "invite from \(code.inviterName ?? "someone"): adds \(code.contactInfo ?? "")"
            case .tribe(let link): return "tribe link: \(link.pubkey) on \(link.host)"
            }
        } catch {
            return "not addable: \(PeelError.readable(error))"
        }
    }
}
