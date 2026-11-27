import Foundation

/// A worker's invite as a link, in the forms it reaches Peel in
/// (docs/phases/13-worker-invite-iphone.md; Android's `InviteLink`, which
/// this mirrors): `peel://join?action=i&d=…&c=…&a=…` when strut's join page
/// opens Peel, or the same invite on the clipboard (strut's join page copies
/// it, since nothing carries a tapped link across an install) as a whole
/// `sphinx.chat://?action=i&…` link or strut's own join link
/// (`https://<strut>/public/join#action=i&…`). Whatever the form, the text
/// handed on is the `sphinx.chat://?…` link the official apps and the core
/// read (`Engine.parseInvite`, `ContactCode`), so the core sees on the iPhone
/// what it sees on Android. `a=<address>` names the strut app (the employer's
/// Tasks) to open once the account is ready; it lives in the link alone, which
/// the core passes over.
///
/// Peel does not register `sphinx.chat`: the Sphinx app registers it too, and
/// iOS does not say which app opens a scheme two apps claim.
///
/// Only text is read here, never stored or logged: an invite is a secret
/// until it is used.
public enum InviteLink {
    /// Longer than any invite can be: what a QR code holds at most
    /// (`ContactCode.maxLength`).
    static let maxLength = ContactCode.maxLength

    /// The official apps' scheme, which the core's invite reader takes.
    static let scheme = "sphinx.chat"

    /// What every `sphinx.chat` invite link starts with.
    private static let linkPrefix = "\(scheme)://?"

    /// Strut's join page path (stakwork/strut `src/public-join.ts`): the
    /// invite rides after its `#`.
    private static let joinPath = "/public/join"

    /// The strut join page Stadeum's "Invite worker" flow uses today
    /// (stakwork/strut `src/public-join.ts`). A shared invite is an https
    /// link on it, since a `sphinx.chat://` link is not a link in most chat
    /// apps and opens nothing for someone without the app. Change it here to
    /// move the page.
    public static let joinHost = "https://strut.stadeum.stakwork.ai"

    /// The section of a worker's invite link that names the app to open.
    private static let appSection = "a="

    /// The invite in `peel://join?action=i&d=…`, as the `sphinx.chat://?…`
    /// link with the same query; nil for any other link, or one that is not an
    /// invite (exactly one `action=i`, a non-empty `d=`). No path, user or
    /// fragment: any page can open a `peel:` link.
    public static func fromPeelLink(_ url: URL) -> String? {
        guard url.scheme?.lowercased() == "peel", url.host?.lowercased() == "join",
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.path.isEmpty || parts.path == "/", parts.user == nil, parts.password == nil, parts.fragment == nil,
              let query = parts.percentEncodedQuery else { return nil }
        return invite(linkPrefix + query)
    }

    /// An invite link on the clipboard: a whole `sphinx.chat://?action=i&…`
    /// link, or strut's join link (`fromJoinLink`), which is taken as the same
    /// link; or, when the text is a message around one (what `InviteShare`
    /// writes), the first invite in it (`find(in:)`). Anything else someone
    /// copied is nil, so it never lands in the invite field. The message is
    /// capped at a few invites' length so a huge copy is never searched.
    public static func fromClipboard(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.utf16.count <= maxLength * 4 else { return nil }
        if let whole = wholeLink(trimmed) { return whole }
        // Text that opens with an invite link and goes on is someone's mangled link, not a message about one.
        if let first = trimmed.split(whereSeparator: \.isWhitespace).first,
           first.lowercased().hasPrefix(linkPrefix) || wholeLink(String(first)) != nil { return nil }
        return find(in: trimmed)
    }

    /// The first invite in free text: the first piece between whitespace (with
    /// the punctuation a sentence puts around a link taken off) that is an
    /// invite link, as the `sphinx.chat://?…` link. Nil when there is none.
    public static func find(in text: String) -> String? {
        let edges = CharacterSet(charactersIn: "<>()[]\"'`.,;:!")
        for piece in text.split(whereSeparator: \.isWhitespace) {
            let token = String(piece)
            if let link = wholeLink(token) { return link }
            if let link = wholeLink(token.trimmingCharacters(in: edges)) { return link }
        }
        return nil
    }

    /// The link a share carries: `link` (a `sphinx.chat://?action=i&…` link)
    /// as an https link on strut's join page, `<host>/public/join#action=i&…`,
    /// which any chat app makes tappable and which sends someone without Peel
    /// to get it. Mirrors strut's `joinLink` (`src/payments/invites.ts`): no
    /// `a=` is added. Nil unless `link` is an invite with no `#` or
    /// whitespace to break the address.
    public static func joinLink(_ link: String, host: String = joinHost) -> String? {
        var query = link.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.lowercased().hasPrefix(linkPrefix) { query.removeFirst(linkPrefix.count) }
        guard query.hasPrefix("action=i&"), !query.contains("#"), !query.contains(where: \.isWhitespace),
              query.split(separator: "&", omittingEmptySubsequences: false)
                  .contains(where: { $0.hasPrefix("d=") && $0.count > 2 }) else { return nil }
        var base = host
        while base.hasSuffix("/") { base.removeLast() }
        return "\(base)\(joinPath)#\(query)"
    }

    /// `text`, all of it, when it is one invite link (either form), as the
    /// `sphinx.chat://?…` link.
    private static func wholeLink(_ text: String) -> String? {
        if text.lowercased().hasPrefix(linkPrefix) { return invite(text) }
        return fromJoinLink(text).flatMap(invite)
    }

    /// The invite in strut's join link,
    /// `https://<strut>/public/join[?lang=…]#action=i&d=…&c=…&a=…`, as the
    /// `sphinx.chat://?action=i&…` link the page itself opens Peel with; nil
    /// for any other text. https only, no user info, the path exactly the join
    /// page's; the part after `#` is taken as the page takes it (a
    /// `sphinx.chat://?` before it dropped).
    static func fromJoinLink(_ text: String) -> String? {
        guard let hash = text.firstIndex(of: "#"),
              let page = URLComponents(string: String(text[..<hash])),
              page.scheme?.lowercased() == "https", !(page.host ?? "").isEmpty,
              page.user == nil, page.password == nil, page.percentEncodedPath == joinPath else { return nil }
        var invite = String(text[text.index(after: hash)...])
        if invite.lowercased().hasPrefix(linkPrefix) { invite.removeFirst(linkPrefix.count) }
        return linkPrefix + invite
    }

    /// The public strut app a worker's invite link names,
    /// `…&a=<percent-encoded address>`, to open once the account is ready. Held
    /// to a `peel://open?url=` link's rules (`PublicAppLink.init(_:)`); nil
    /// when there is no `a=`, more than one, or it fails them, and the invite
    /// is read as before. The sections are read as the core reads them, from
    /// whatever follows the first `?` or `#` (strut's join link carries the
    /// invite after `#`), or the whole text when it has neither (a bare
    /// `d=…&a=…`).
    public static func appOf(_ link: String) -> PublicAppLink? {
        let sections = link.firstIndex { $0 == "?" || $0 == "#" }
            .map { link[link.index(after: $0)...] } ?? link[...]
        let named = sections.split(separator: "&", omittingEmptySubsequences: false).filter { $0.hasPrefix(appSection) }
        guard named.count == 1, let first = named.first,
              let address = String(first.dropFirst(appSection.count)).removingPercentEncoding,
              let url = URL(string: address) else { return nil }
        return PublicAppLink(url)
    }

    /// `link` when it is an invite link: short, one piece of text, with exactly
    /// one `action=i` and a `d=` that says something.
    private static func invite(_ link: String) -> String? {
        guard !link.isEmpty, link.utf16.count <= maxLength, !link.contains(where: \.isWhitespace),
              link.lowercased().hasPrefix(linkPrefix) else { return nil }
        let sections = link.dropFirst(linkPrefix.count).split(separator: "&", omittingEmptySubsequences: false)
        guard sections.filter({ $0 == "action=i" }).count == 1,
              sections.contains(where: { $0.hasPrefix("d=") && $0.count > 2 }) else { return nil }
        return link
    }
}
