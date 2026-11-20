import Foundation
import PeelCore

/// When a page Peel opened may ask for the person's location, and what a
/// kept decision does. Pure rules; the iPhone's page sheet applies them
/// (`PageLocationAuthorizer` asks the system). The site is always the one
/// Peel loaded, never what WebKit reports for the frame.
public enum PageLocation {
    /// What to do with a request once the rules and decisions are known.
    public enum Decision: Equatable, Sendable {
        case ask, allow, deny
    }

    /// The site to attribute a request to, as `origin` Peel loaded
    /// (`PublicPage.origin`-style: scheme://host[:port]), or nil to deny with
    /// no prompt.
    ///
    /// - `frameIsMain`: the request comes from the page's main frame.
    /// - `frameURL`: the address WebKit gives the requesting frame.
    /// - `frameOriginIsOpaque`: the frame's origin is opaque (a sandboxed
    ///   `srcdoc` frame, strut's app frame).
    /// - `pageURL`: the address Peel loaded.
    /// - `pageVisible`, `appActive`: the sheet is on screen and the app in front.
    public static func mayAsk(
        frameIsMain: Bool, frameURL: URL?, frameOriginIsOpaque: Bool, pageURL: URL, pageVisible: Bool, appActive: Bool
    ) -> String? {
        guard pageVisible, appActive, isSecure(pageURL), let origin = OrgPageRequest.origin(of: pageURL) else { return nil }
        if frameIsMain {
            guard let frameURL, OrgPageRequest.origin(of: frameURL) == origin else { return nil }
            return origin
        }
        // Only the page's own sandboxed frame; any other frame is another site's.
        if frameOriginIsOpaque, frameURL?.absoluteString == "about:srcdoc" { return origin }
        return nil
    }

    /// Secure as `PublicApp` takes a page: https, or http to this machine.
    public static func isSecure(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https": true
        case "http": Web.isThisMac(url)
        default: false
        }
    }

    /// A kept decision wins; "allow once" counts as an allow for this sheet
    /// only; nothing kept asks. A kept deny is never overridden by a once.
    public static func decide(stored: SiteLocationGrant?, allowOnce: Bool) -> Decision {
        if let stored { return stored.allowed ? .allow : .deny }
        return allowOnce ? .allow : .ask
    }

    /// The site's line in Site location.
    public static func summary(_ grant: SiteLocationGrant) -> String {
        grant.allowed
            ? (grant.precise ? String(localized: "Allowed · precise", table: "Shared") : String(localized: "Allowed · approximate", table: "Shared"))
            : String(localized: "Blocked", table: "Shared")
    }
}
