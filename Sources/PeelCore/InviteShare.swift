import Foundation

/// The text someone shares or copies for an invite they made: a short message
/// with context and an https join link (`InviteLink.joinLink`), in place of
/// the bare `sphinx.chat://` link, which most chat apps do not make tappable
/// and which means nothing to someone without Peel. The QR code keeps the raw
/// link. The message is read back by `InviteLink.find(in:)`, so pasting all of
/// it into Peel finds the invite.
public enum InviteShare {
    /// `link` (the invite's `sphinx.chat://?…` link) in its message: the
    /// invite's personal `note` first, then who invited them (`inviterAlias`,
    /// the account's own), then the three steps. A link that cannot be made an
    /// https one goes in raw.
    public static func message(link: String, inviterAlias: String?, note: String?) -> String {
        let shared = InviteLink.joinLink(link) ?? link
        let name = inviterAlias?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let intro = name.map { String(localized: "\($0) invited you to Peel, a private chat and wallet app.", table: "Shared") }
            ?? String(localized: "You're invited to Peel, a private chat and wallet app.", table: "Shared")
        var paragraphs: [String] = []
        if let note = note?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty { paragraphs.append(note) }
        paragraphs.append(intro)
        paragraphs.append([
            String(localized: "1. Open this link on your phone and tap \"Get Peel\" (or \"Open in Peel\" if you have it):", table: "Shared"),
            shared,
            String(localized: "2. Open Peel. Your invite fills in by itself.", table: "Shared"),
            String(localized: "3. If it doesn't, tap \"Join with an invite\" and paste this whole message.", table: "Shared"),
        ].joined(separator: "\n"))
        return paragraphs.joined(separator: "\n\n")
    }
}
