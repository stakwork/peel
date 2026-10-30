import Foundation

// An app's versions and releases on the strut it lives on (strut's
// plans/app-releases.md, `GET /apps/:name/versions`): which version everyone
// opens, whether the app follows its latest publish or is held at a release,
// and what a held app's release locked that has moved on since. Strut decides
// all of it; Peel reads it and asks strut to change what is live
// (`AppLiveTarget`, `PUT /apps/:name/active`).

/// `GET /apps/:name/versions`, as Peel shows it.
public struct AppVersions: Sendable, Equatable {
    public struct Version: Sendable, Equatable, Identifiable {
        /// `v9`.
        public let label: String
        public let createdAt: Date?
        public var id: String { label }
    }

    /// A version made live, with the workflows it calls locked at the
    /// versions they had then.
    public struct Release: Sendable, Equatable, Identifiable {
        /// `r3`.
        public let id: String
        /// The page: a version label.
        public let version: String
        public let createdAt: Date?
    }

    /// A workflow or step the live release locked whose version has moved on.
    public struct Drift: Sendable, Equatable {
        public let name: String
        public let locked: String
        /// Nil when it no longer exists.
        public let current: String?
    }

    /// The version everyone opens.
    public let active: String
    /// Newest first.
    public let versions: [Version]
    /// The live release's id; nil while the app follows its latest publish.
    public let release: String?
    /// Newest first.
    public let releases: [Release]
    /// What the live release locked that has moved on since; none while following.
    public let behind: [Drift]

    public var held: Bool { release != nil }

    /// A version newer than the live one while the app is held: built, and
    /// waiting for a person to make it live. Following, there are none.
    public func isWaiting(_ label: String) -> Bool {
        held && Self.isNewer(label, than: active)
    }

    /// The newest version waiting, the one "Make live" offers.
    public var newestWaiting: String? {
        versions.first { isWaiting($0.label) }?.label
    }

    /// `v12` → 12; nil for a label strut would not give.
    static func number(_ label: String) -> Int? {
        guard label.first == "v" else { return nil }
        return Int(label.dropFirst())
    }

    /// Whether version `label` came after `other` (`v10` after `v9`);
    /// never for a label strut would not give.
    static func isNewer(_ label: String, than other: String) -> Bool {
        guard let mine = number(label), let theirs = number(other) else { return false }
        return mine > theirs
    }

    /// `labels` newest first, leaving out any strut would not give.
    static func newestFirst(_ labels: [String]) -> [String] {
        labels.filter { number($0) != nil }.sorted { isNewer($0, than: $1) }
    }
}

extension AppVersions {
    /// strut's reply, or nil for one without an active version.
    public init?(reply: Data) {
        guard case .object(let json)? = try? JSONDecoder().decode(JSONValue.self, from: reply),
              let active = json["active"]?.string, Self.number(active) != nil else { return nil }
        func date(_ value: JSONValue?) -> Date? { value?.string.flatMap { Date(iso8601: $0) } }
        /// The objects in the list `key`.
        func objects(_ key: String) -> [[String: JSONValue]] {
            guard case .array(let all)? = json[key] else { return [] }
            return all.compactMap { if case .object(let one) = $0 { one } else { nil } }
        }
        self.active = active
        // A map by label, `{ vN: { createdAt } }`.
        let all: [String: JSONValue] = if case .object(let all)? = json["versions"] { all } else { [:] }
        versions = Self.newestFirst(Array(all.keys)).map { label in
            if case .object(let info)? = all[label] { Version(label: label, createdAt: date(info["createdAt"])) }
            else { Version(label: label, createdAt: nil) }
        }
        // `latest` while following, else the live release's id.
        let live = json["live"]?.string
        release = live == "latest" ? nil : live
        // strut lists them oldest first.
        releases = objects("releases").compactMap { one in
            guard let id = one["id"]?.string, let version = one["version"]?.string else { return nil }
            return Release(id: id, version: version, createdAt: date(one["createdAt"]))
        }.reversed()
        behind = objects("behind").compactMap { one in
            guard let name = one["name"]?.string, let locked = one["locked"]?.string else { return nil }
            return Drift(name: name, locked: locked, current: one["current"]?.string)
        }
    }
}

/// What a person makes live (`PUT /apps/:name/active`).
public enum AppLiveTarget: Sendable, Equatable {
    /// A new release of this version, with the workflows it calls locked as
    /// they are now; the app is held there. The live version again takes the
    /// workflows as they are now.
    case version(String)
    /// An earlier release, made live again.
    case release(String)
    /// Every publish goes live again.
    case latest

    /// The request's body.
    public var body: [String: String] {
        switch self {
        case .version(let label): ["version": label]
        case .release(let id): ["release": id]
        case .latest: ["version": "latest"]
        }
    }
}
