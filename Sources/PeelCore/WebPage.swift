import Foundation

/// What the app's web pane may open, and where each profile keeps the
/// pane's website data. The pane itself is in the app (`WebPane`); see the
/// design README, "Web pane".
public enum WebPage {
    /// An address the pane opens: http or https with a host, and no user
    /// name or password, so `https://google.com@evil.example` is not shown
    /// as if it were Google. Anything else (mailto, `sphinx.chat://`, a
    /// file) is not for the pane and keeps its usual handling.
    public static func address(_ url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }

    /// The same for an address someone typed into a record, such as a
    /// tribe's `app_url`: trimmed, nil when empty or not for the pane.
    public static func address(_ text: String?) -> URL? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
              let url = URL(string: trimmed) else { return nil }
        return address(url)
    }

    /// What someone typed into the pane's address field: a web address, or
    /// else a DuckDuckGo search for the words. Only http and https ever
    /// load: any other scheme typed out (`javascript:`, `file:`, `data:`,
    /// `about:`) is refused with nil, never searched for or run. A bare
    /// name gets https, or http for this machine (`localhost:3000`); one
    /// that does not read as a host name ("swift tabs", "hello") is a search.
    public static func typed(_ text: String) -> URL? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let scheme = scheme(of: text)
        if scheme == "http" || scheme == "https" { return URL(string: text).flatMap(address) }
        // Otherwise words with spaces are a search, whatever the first one looks like.
        if text.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains) {
            return search(text)
        }
        guard scheme == nil else { return nil }
        guard let url = URL(string: "https://" + text), let host = url.host?.lowercased(), isHostName(host),
              let page = address(url) else { return search(text) }
        guard ServerAddress.isLoopback(host: host), var parts = URLComponents(url: page, resolvingAgainstBaseURL: false)
        else { return page }
        parts.scheme = "http"
        return parts.url
    }

    /// A DuckDuckGo search for `words`.
    static func search(_ words: String) -> URL? {
        // `+` would read as a space and `&`, `=`, `#` would end the query.
        let query = words.addingPercentEncoding(withAllowedCharacters: queryAllowed)
        return query.flatMap { URL(string: "https://duckduckgo.com/?q=" + $0) }
    }

    private static let queryAllowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&=#"))

    /// The scheme `text` starts with, lowercased: letters, digits, `+`, `-`
    /// and `.` after a letter, then a colon. A colon followed by a port
    /// (`localhost:3000`, `example.com:8080/x`) is a host, not a scheme.
    private static func scheme(of text: String) -> String? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let name = text[..<colon]
        guard let first = name.unicodeScalars.first, CharacterSet.letters.contains(first), name.unicodeScalars.allSatisfy({
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "+-.".unicodeScalars.contains($0))
        }) else { return nil }
        let rest = text[text.index(after: colon)...]
        let port = rest.prefix { $0.isASCII && $0.isNumber }
        let afterPort = rest.dropFirst(port.count).first
        if !port.isEmpty, afterPort.map({ "/?#".contains($0) }) ?? true { return nil }
        return name.lowercased()
    }

    /// Reads as a host someone meant to visit: this machine, an IP
    /// address, or dotted labels ending in a name of two or more characters
    /// with a letter in it (`example.com`, not `3.14` or `notes.`).
    private static func isHostName(_ host: String) -> Bool {
        if ServerAddress.isLoopback(host: host) || host.contains(":") { return true }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count > 1, labels.allSatisfy({ !$0.isEmpty }), let last = labels.last else { return false }
        if labels.count == 4, labels.allSatisfy({ UInt8($0) != nil }) { return true }
        return last.count >= 2 && last.contains(where: \.isLetter)
    }

    /// The identifier of this profile's website data store, made the first
    /// time and kept in the profile's folder (`web-store`), so each profile
    /// has its own cookies and sign-ins and forgetting the profile can
    /// remove them. Nil when `create` is false and there is none yet.
    public static func storeIdentifier(in directory: URL, create: Bool = true) throws -> UUID? {
        let file = directory.appendingPathComponent("web-store", isDirectory: false)
        if let text = try? String(contentsOf: file, encoding: .utf8),
           let id = UUID(uuidString: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return id
        }
        guard create else { return nil }
        let id = UUID()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(id.uuidString.utf8).write(to: file, options: .atomic)
        return id
    }
}
