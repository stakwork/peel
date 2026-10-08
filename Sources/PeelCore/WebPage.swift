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
