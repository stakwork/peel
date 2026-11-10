import Foundation
import PeelCore

/// What the bolt in Chats says about the connection, truthfully: a
/// connection that is up (`connected`) has not yet fetched what came while
/// the app was away, and until it has (`synced`) it is `syncing`. Derived
/// from the engine's `.connection` and `.caughtUp` events; reset when the
/// connection goes.
public enum ConnectionHealth: Sendable, Equatable {
    case offline, syncing, synced

    public init(connection: Engine.ConnectionState, caughtUp: Bool) {
        self = connection == .connected ? (caughtUp ? .synced : .syncing) : .offline
    }

    public var label: String {
        switch self {
        case .offline: "Offline"
        case .syncing: "Syncing…"
        case .synced: "Connected"
        }
    }
}

/// The notices in chats that tell of a connection failing at the time
/// (`Engine.connectionFailedNotice`: "the payment may have gone"). Stored
/// until the next send, they would show up on entering the chat long after
/// the connection came back, so such a notice is dropped on entering the
/// chat once it is `staleAfter` old or the connection is synced.
struct ConnectionNotices {
    static let staleAfter: TimeInterval = 60

    private var stamps: [String: (shown: String, at: Date)] = [:]

    /// `message` came for `chat` and `shown` is what was stored for it.
    mutating func noted(_ message: String, shown: String, in chat: String, at now: Date = .now) {
        stamps[chat] = message.hasPrefix(Engine.connectionFailedNotice) ? (shown, now) : nil
    }

    /// Whether the notice `shown` for `chat` is a stale one of the connection's, to drop now.
    /// A notice that was replaced since (it is not the one noted) is left to be.
    mutating func isStale(_ shown: String?, in chat: String, synced: Bool, at now: Date = .now) -> Bool {
        guard let stamp = stamps[chat] else { return false }
        guard stamp.shown == shown else {
            stamps[chat] = nil
            return false
        }
        guard synced || now.timeIntervalSince(stamp.at) > Self.staleAfter else { return false }
        stamps[chat] = nil
        return true
    }
}
