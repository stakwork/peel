import Foundation

/// Decrypts the child index a push carries. The real one is the core's
/// `decryptChildIndex` (`PeelPushCrypto`); tests inject their own.
public protocol ChildIndexDecrypting: Sendable {
    func decrypt(child: String, pushKey: String) throws -> UInt64
}

/// Names for the child indexes, kept by the app in the shared app group for
/// the extension to read, in sphinx-ios-v2's format: a JSON object of
/// `contact-<index>` and `tribe-<index>` to a name, sealed under the push key
/// (RNCryptor v3, base64; `PushNameDirectoryWriter`, `RNCryptorSealer`) and
/// kept in the group's UserDefaults under `defaultsKey`. `<index>` is the
/// core's `my_idx`, the child key this account uses for a contact or tribe.
public struct PushNameDirectory: Equatable, Sendable {
    /// sphinx-ios-v2's key (`kChildIndexesStorageKey`); the group is Peel's own.
    public static let defaultsKey = "childIndexesStorageKey"
    private static let longest = 100

    public let contacts: [UInt64: String]
    public let tribes: [UInt64: String]

    public init(contacts: [UInt64: String] = [:], tribes: [UInt64: String] = [:]) {
        self.contacts = contacts
        self.tribes = tribes
    }

    /// Entries as the writer is given them; names are cleaned here, and one
    /// left with nothing is dropped. The last of a kind and index wins.
    public init(entries: [PushNameEntry]) {
        var contacts: [UInt64: String] = [:], tribes: [UInt64: String] = [:]
        for entry in entries {
            guard let name = Self.clean(entry.name) else { continue }
            switch entry.kind {
            case .contact: contacts[entry.index] = name
            case .tribe: tribes[entry.index] = name
            }
        }
        self.init(contacts: contacts, tribes: tribes)
    }

    /// The JSON object, keys sorted so the same names give the same text.
    public func encoded() -> Data? {
        var map: [String: String] = [:]
        for (index, name) in contacts { map["contact-\(index)"] = name }
        for (index, name) in tribes { map["tribe-\(index)"] = name }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(map)
    }

    /// Nil for anything that is not a JSON object of strings.
    public init?(json: Data) {
        guard let map = try? JSONDecoder().decode([String: String].self, from: json) else { return nil }
        var contacts: [UInt64: String] = [:], tribes: [UInt64: String] = [:]
        for (key, name) in map {
            if key.hasPrefix("contact-"), let index = UInt64(key.dropFirst("contact-".count)) {
                contacts[index] = name
            } else if key.hasPrefix("tribe-"), let index = UInt64(key.dropFirst("tribe-".count)) {
                tribes[index] = name
            }
        }
        self.init(contacts: contacts, tribes: tribes)
    }

    /// A name as one short line, or nil when nothing is left of it.
    static func clean(_ name: String) -> String? {
        let line = name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let text = String(String.UnicodeScalarView(line)).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : String(text.prefix(longest))
    }

    func name(forIndex index: UInt64) -> (name: String, isTribe: Bool)? {
        if let name = contacts[index].flatMap(Self.clean) { return (name, false) }
        if let name = tribes[index].flatMap(Self.clean) { return (name, true) }
        return nil
    }
}

/// What the extension shows.
public enum PushNotificationContent: Equatable, Sendable {
    /// Replace the notification's title and body.
    case text(title: String, body: String)
    /// Show the notification as the server sent it (a Hive link's).
    case asSent

    public static let generic = PushNotificationContent.text(title: "Peel", body: "You have new messages")
}

public enum PushNotificationResolver {
    /// `aps.custom_data.child`, as sphinx-ios-v2 reads it.
    public static func encryptedChild(from userInfo: [AnyHashable: Any]) -> String? {
        let aps = userInfo["aps"] as? [String: Any]
        let custom = aps?["custom_data"] as? [String: Any]
        guard let child = custom?["child"] as? String, !child.isEmpty else { return nil }
        return child
    }

    /// A Hive link rides in the same field (`workspace/feature:ID` or
    /// `workspace/task:ID`) and its notification is worded by the server.
    static func isHiveLink(_ child: String) -> Bool {
        let parts = child.split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { return false }
        return parts[1].hasPrefix("feature:") || parts[1].hasPrefix("task:")
    }

    /// The words for a push. Any failure (no key, no child, a refused
    /// decrypt, no name) falls back as far as it must: the child's name, or
    /// the generic line. Never throws, never leaves the push empty.
    public static func resolve(
        userInfo: [AnyHashable: Any], pushKey: String?, decryptor: any ChildIndexDecrypting,
        names: PushNameDirectory?
    ) -> PushNotificationContent {
        guard let child = encryptedChild(from: userInfo) else { return .generic }
        if isHiveLink(child) { return .asSent }
        guard let pushKey, !pushKey.isEmpty,
              let index = try? decryptor.decrypt(child: child, pushKey: pushKey),
              let found = names?.name(forIndex: index)
        else { return .generic }
        return .text(
            title: "Peel",
            body: found.isTribe ? "You have new messages in \(found.name)" : "You have new messages from \(found.name)")
    }
}
