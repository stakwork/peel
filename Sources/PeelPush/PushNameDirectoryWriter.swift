import Foundation

/// One name for the notification extension: a contact's or a tribe's, by the
/// core's child index for it (`Engine.Contact.childIndex`, `my_idx`).
public struct PushNameEntry: Equatable, Sendable {
    public enum Kind: Sendable { case contact, tribe }

    public let kind: Kind
    public let index: UInt64
    public let name: String

    public init(kind: Kind, index: UInt64, name: String) {
        self.kind = kind
        self.index = index
        self.name = name
    }
}

/// Seals text under the push key. The real one is sphinx-ios-v2's
/// (`RNCryptorSealer`); tests inject their own.
public protocol PushSealing: Sendable {
    func seal(_ text: String, key: String) throws -> String
    func open(_ sealed: String, key: String) throws -> String
}

/// Where the sealed names are kept: the app group's UserDefaults.
public protocol PushNameStoring: Sendable {
    func read() -> String?
    func write(_ sealed: String?)
}

/// The app group's UserDefaults under `PushNameDirectory.defaultsKey`.
public struct UserDefaultsPushNameStore: PushNameStoring {
    private let suiteName: String

    public init(suiteName: String) {
        self.suiteName = suiteName
    }

    public func read() -> String? {
        UserDefaults(suiteName: suiteName)?.string(forKey: PushNameDirectory.defaultsKey)
    }

    public func write(_ sealed: String?) {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        if let sealed {
            defaults.set(sealed, forKey: PushNameDirectory.defaultsKey)
        } else {
            defaults.removeObject(forKey: PushNameDirectory.defaultsKey)
        }
    }
}

/// Keeps the names map the extension reads. Never logs a name or the key.
public enum PushNameDirectoryWriter {
    /// Seals the entries' names under the push key and keeps them. Returns
    /// false, keeping nothing, when the key is not a push key or sealing
    /// fails. A map that already holds exactly these names is left as it is.
    @discardableResult
    public static func write(
        _ entries: [PushNameEntry], pushKey: String, sealer: some PushSealing, store: some PushNameStoring
    ) -> Bool {
        guard PushKey.isValid(pushKey) else { return false }
        let directory = PushNameDirectory(entries: entries)
        if PushNameDirectory.read(from: store, pushKey: pushKey, sealer: sealer) == directory { return true }
        guard let json = directory.encoded(),
              let sealed = try? sealer.seal(String(decoding: json, as: UTF8.self), key: pushKey)
        else { return false }
        store.write(sealed)
        return true
    }

    /// Forgets every name (the account closed or was forgotten).
    public static func clear(store: some PushNameStoring) {
        store.write(nil)
    }
}

extension PushNameDirectory {
    /// The kept names, or nil when none are kept, the key is not a push key,
    /// the blob does not open under it, or what opens is not a names map.
    public static func read(from store: some PushNameStoring, pushKey: String?, sealer: some PushSealing) -> PushNameDirectory? {
        guard let pushKey, PushKey.isValid(pushKey), let sealed = store.read(),
              let json = try? sealer.open(sealed, key: pushKey)
        else { return nil }
        return PushNameDirectory(json: Data(json.utf8))
    }
}
