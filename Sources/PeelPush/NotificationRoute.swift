import Foundation

/// Where a tapped push should go. Platform-neutral: parsed from a
/// notification's `userInfo`, held by `PendingNavigation` until the app can
/// open it.
///
/// The server's payload carries only the encrypted child index
/// (`aps.custom_data.child`), so the notification service extension, which
/// can decrypt it, writes the resolved reference into the delivered
/// content's `userInfo` (`userInfo(into:)`, under `userInfoKey`) and sets
/// the thread to `threadIdentifier`. The app turns a child into a chat id
/// once the account is open (`Engine.Contact.childIndex` → the contact's
/// key, which is the chat id).
public enum NotificationRoute: Equatable, Sendable {
    public enum ChildKind: String, Sendable { case contact, tribe }

    /// A chat by its id, when the payload already names it.
    case chat(String)
    /// A contact or tribe by the core's child index, as the extension resolved it.
    case child(kind: ChildKind, index: UInt64)

    /// The key the extension stores the child reference under.
    public static let userInfoKey = "peelChild"
    /// A payload (or a future server) naming the chat id outright.
    public static let chatKey = "peelChat"

    /// The thread identifier groups a chat's notifications; stable per child.
    public static func threadIdentifier(kind: ChildKind, index: UInt64) -> String {
        "child-\(kind.rawValue)-\(index)"
    }

    /// Adds the child reference to a content's userInfo, keeping what is there.
    public static func userInfo(into existing: [AnyHashable: Any], kind: ChildKind, index: UInt64) -> [AnyHashable: Any] {
        var info = existing
        info[userInfoKey] = ["kind": kind.rawValue, "index": String(index)]
        return info
    }

    /// The route in a notification's userInfo, or nil when there is none or
    /// it is malformed. Never throws; a payload that is not ours is ignored.
    public init?(userInfo: [AnyHashable: Any]) {
        if let chat = userInfo[Self.chatKey] as? String, !chat.isEmpty {
            self = .chat(chat)
            return
        }
        guard let child = userInfo[Self.userInfoKey] as? [String: Any],
              let kind = (child["kind"] as? String).flatMap(ChildKind.init(rawValue:)),
              let index = Self.index(child["index"])
        else { return nil }
        self = .child(kind: kind, index: index)
    }

    private static func index(_ value: Any?) -> UInt64? {
        switch value {
        case let text as String: UInt64(text)
        case let number as NSNumber:
            number.int64Value >= 0 && number.doubleValue == Double(number.int64Value) ? UInt64(number.int64Value) : nil
        default: nil
        }
    }
}

/// A tapped push waiting for the app: the delegate hands it over, the UI
/// takes it once an account is open and the router exists. One route at a
/// time (the latest tap wins); a notification delivered twice (same
/// request id) is taken once; `take` hands a route out once.
public final class PendingNavigation: @unchecked Sendable {
    /// Posted (on any thread) when a route is submitted.
    public static let didChange = Notification.Name("PeelPendingNavigationDidChange")
    public static let shared = PendingNavigation()

    private let lock = NSLock()
    private var route: NotificationRoute?
    private var lastID: String?

    public init() {}

    /// Keeps a route to open. Returns false for one already submitted under
    /// the same notification id.
    @discardableResult
    public func submit(_ route: NotificationRoute, id: String? = nil) -> Bool {
        lock.lock()
        if let id {
            guard id != lastID else { lock.unlock(); return false }
            lastID = id
        }
        self.route = route
        lock.unlock()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
        return true
    }

    /// Parses and keeps; nil userInfo of no route keeps nothing.
    @discardableResult
    public func submit(userInfo: [AnyHashable: Any], id: String? = nil) -> Bool {
        guard let route = NotificationRoute(userInfo: userInfo) else { return false }
        return submit(route, id: id)
    }

    public var hasPending: Bool {
        lock.lock(); defer { lock.unlock() }
        return route != nil
    }

    /// The pending route, which is then gone.
    public func take() -> NotificationRoute? {
        lock.lock(); defer { lock.unlock() }
        defer { route = nil }
        return route
    }

    /// Drops what is waiting (the account was forgotten).
    public func clear() {
        lock.lock(); defer { lock.unlock() }
        route = nil
    }
}
