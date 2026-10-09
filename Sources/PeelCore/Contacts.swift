import Foundation
import GRDB

/// What a scanned or pasted code is, for adding a contact: someone's
/// contact info (bare, or in the official apps' `share_contact` link), an
/// invite (whose inviter is the one added: the code itself is for a new
/// account), or a tribe link (joined elsewhere). Anything else is refused.
public enum ContactCode: Sendable, Equatable {
    /// `pubkey_lsp_scid`, checked and in lower case.
    case contact(info: String)
    case invite(Engine.Invite)
    case tribe(TribeLink)

    /// Longer than any of these can be: what a QR code holds at most.
    static let maxLength = 3000

    /// Reads what a QR code or the clipboard held. Strict: contact info is
    /// three parts (two keys and a channel id) and nothing more; a
    /// `sphinx.chat://` link is read only for the actions below.
    public static func read(_ text: String) throws -> ContactCode {
        // A whole pasted document is refused before it is walked.
        guard text.utf8.count <= maxLength * 4 else { throw Engine.Failure.notAContactCode }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= maxLength else { throw Engine.Failure.notAContactCode }
        if text.lowercased().hasPrefix("sphinx.chat://") {
            return try link(text)
        }
        if let info = contactInfo(text) { return .contact(info: info) }
        if text.isPubkey { throw Engine.Failure.keyWithoutRoute }
        // An invite without its prefix, as the core also reads them.
        if text.hasPrefix("d="), let invite = try? Engine.parseInvite(text) { return try inviter(invite) }
        throw Engine.Failure.notAContactCode
    }

    private static func link(_ text: String) throws -> ContactCode {
        guard let components = URLComponents(string: text), components.scheme?.lowercased() == "sphinx.chat",
              (components.host ?? "").isEmpty, components.path.isEmpty else {
            throw Engine.Failure.notAContactCode
        }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        switch value("action") {
        case "i":
            guard let invite = try? Engine.parseInvite(text) else { throw Engine.Failure.notAContactCode }
            return try inviter(invite)
        case "share_contact":
            // The official apps write `pubKey`; its value may be a whole contact info.
            guard let key = value("pubKey") ?? value("pubkey") else { throw Engine.Failure.notAContactCode }
            if let info = contactInfo(key) { return .contact(info: info) }
            throw key.isPubkey ? Engine.Failure.keyWithoutRoute : Engine.Failure.notAContactCode
        case "tribeV2":
            guard let link = TribeLink(text) else { throw Engine.Failure.notAContactCode }
            return .tribe(link)
        default:
            throw Engine.Failure.notAContactCode
        }
    }

    private static func inviter(_ invite: Engine.Invite) throws -> ContactCode {
        guard invite.inviterContactInfo.flatMap(contactInfo) != nil else { throw Engine.Failure.inviteWithoutInviter }
        return .invite(invite)
    }

    /// `pubkey_lsp_scid` with both keys compressed points in hex and the
    /// channel id a number, lower-cased; nil for anything else.
    static func contactInfo(_ text: String) -> String? {
        let parts = text.split(separator: "_", omittingEmptySubsequences: false).map { $0.lowercased() }
        guard parts.count == 3, isKey(parts[0]), isKey(parts[1]),
              parts[2].count <= 20, parts[2].allSatisfy(\.isASCIIDigit), UInt64(parts[2]) != nil else { return nil }
        return parts.joined(separator: "_")
    }

    private static func isKey(_ text: String) -> Bool {
        text.isPubkey && (text.hasPrefix("02") || text.hasPrefix("03"))
    }

    /// Who would be added: the contact info and the name it comes with.
    public var contactInfo: String? {
        switch self {
        case .contact(let info): info
        case .invite(let invite): invite.inviterContactInfo.flatMap(Self.contactInfo)
        case .tribe: nil
        }
    }

    /// The name an invite gives its inviter.
    public var inviterName: String? {
        guard case .invite(let invite) = self else { return nil }
        return invite.inviterAlias?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    /// Of the codes in one picture, the first that names someone to add,
    /// else the first; nil when there are none.
    public static func likeliest(in codes: [String]) -> String? {
        codes.first { (try? read($0))?.contactInfo != nil } ?? codes.first
    }

    /// The contact's public key, the conversation's id once added.
    public var pubkey: String? {
        contactInfo.map { String($0.prefix(66)) }
    }
}

/// A tribe or contact link in a message's text, drawn as a card under it.
/// Only what the Join and Add forms take (`ContactCode.read`): a `tribeV2`
/// link, a `share_contact` link, or bare contact info. Invites are left
/// out: they are a code for a new account, not someone to add.
public enum MessageLink: Sendable, Equatable {
    case tribe(TribeLink)
    /// `pubkey_lsp_scid`, checked and in lower case.
    case contact(info: String)

    /// The tribe's or the person's key.
    public var pubkey: String {
        switch self {
        case .tribe(let link): link.pubkey
        case .contact(let info): String(info.prefix(66))
        }
    }

    /// The first in `text`, if any. Each word is read on its own, from a
    /// `sphinx.chat://` in it (so a Markdown `[label](link)` counts) and
    /// without the brackets, quotes and punctuation around it.
    public static func first(in text: String) -> MessageLink? {
        for word in text.split(whereSeparator: \.isWhitespace) {
            let candidate: Substring
            if let scheme = word.range(of: "sphinx.chat://", options: .caseInsensitive) {
                candidate = word[scheme.lowerBound...]
            } else if word.count >= minContactInfoLength, word.contains("_") {
                candidate = word
            } else {
                continue
            }
            let trimmed = candidate.trimmingCharacters(in: around)
            switch try? ContactCode.read(trimmed) {
            case .tribe(let link): return .tribe(link)
            case .contact(let info): return .contact(info: info)
            default: continue
            }
        }
        return nil
    }

    /// Two 66-character keys, two underscores and a channel id.
    private static let minContactInfoLength = 66 * 2 + 3
    /// What wraps a link in prose or Markdown: never part of one, which
    /// ends in a host, a port or a channel id.
    private static let around = CharacterSet(charactersIn: "()[]<>{}\"'`*_.,;:!?")
}

extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

/// An invite made here with sats (`Engine.makeInvite`). The core keeps no
/// record of invites, and the server only the code and its sats, so this is
/// the only list of them. The nickname and message are for this account
/// alone: they go nowhere on the wire, as in the official apps.
public struct InviteRecord: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "invite"

    public enum Status: String, Codable, Sendable {
        /// The payment that funds it is on its way to the server.
        case sending
        /// The server holds its sats: the code can be shared.
        case ready
        /// The payment failed: no sats moved and the code is worth nothing.
        case failed
        /// Asked the server for the sats back; not answered yet.
        case cancelling
        /// The server sent the sats back.
        case cancelled
        /// Someone joined with it and added this account (`usedBy`).
        case used
    }

    /// The code the server knows it by: 64 hex characters.
    public var code: String
    /// The whole invite (`sphinx.chat://?action=i&…`), for the QR code and
    /// to copy. Like the words, never logged.
    public var link: String
    /// What was paid into it; the server may keep part as its fee.
    public var amountMsat: Int64
    public var nickname: String?
    public var message: String?
    /// The funding payment's tag, which the server confirms.
    public var tag: String?
    public var status: Status
    /// Milliseconds since 1970.
    public var createdAt: Int64
    /// The pubkey of whoever joined with it.
    public var usedBy: String?

    public var id: String { code }
    public var created: Date { Date(millisecondsSince1970: createdAt) }

    /// Still waiting to be used: listed, and may be cancelled.
    public var isPending: Bool { Self.pendingStatuses.contains(status) }
    static let pendingStatuses: [Status] = [.sending, .ready, .cancelling]

    static let maxNicknameLength = 100
    static let maxMessageLength = 500
}
