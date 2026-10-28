import Foundation

/// What an `OrgPageRequest`'s web view may save, and how it words a page
/// that did not load: plain rules, without WebKit's types, which the iPhone's
/// sheet applies (`OrgPageSheet`).
public enum OrgPageRules {
    /// Whether a navigation may become a download: only strut's own page
    /// (the main frame, started by the main frame, on the org's strut's UI),
    /// never a frame in it, which holds what the org or an agent wrote.
    public static func mayDownload(isMainFrame: Bool, sourceIsMainFrame: Bool, served: Bool) -> Bool {
        isMainFrame && sourceIsMainFrame && served
    }

    /// The name a download is saved as: what a server suggested, cut to its
    /// last path component, so it cannot leave its folder; `download` when
    /// nothing usable is left.
    public static func filename(_ suggested: String) -> String {
        let last = suggested
            .split(whereSeparator: { $0 == "/" || $0 == "\\" })
            .last
            .map { String($0.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }) }?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return last.isEmpty || last == "." || last == ".." ? "download" : String(last.prefix(200))
    }

    /// Why a main-frame answer with this HTTP `status` is not shown, or nil
    /// when it is one the page may show.
    public static func failure(status: Int) -> String? {
        guard status >= 400 else { return nil }
        switch status {
        case 401, 403: return "The workspace did not let this device open it (HTTP \(status))."
        case 404: return "The workspace has nothing there (HTTP 404)."
        case 500...: return "The workspace had a problem answering (HTTP \(status))."
        default: return "The workspace answered with HTTP \(status)."
        }
    }
}
