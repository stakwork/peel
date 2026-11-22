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

    /// An invite link on the clipboard: only a whole `sphinx.chat://?action=i&…`
    /// link, or strut's join link (`fromJoinLink`), which is taken as the same
    /// link. Anything else someone copied is nil, so it never lands in the
    /// invite field. The whole text must be the link: no whitespace inside.
    public static func fromClipboard(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let link: String
        if trimmed.lowercased().hasPrefix(linkPrefix) {
            link = trimmed
        } else if let joined = fromJoinLink(trimmed) {
            link = joined
        } else {
            return nil
        }
        return invite(link)
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
