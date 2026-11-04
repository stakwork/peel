import CryptoKit
import Foundation

/// Moving a call between this account's devices: the newest device on a
/// call keeps it, and any other device on the same account leaves.
///
/// A device that connects says so on `topic` (a LiveKit text stream), with a
/// MAC over the room and its own identity there, keyed from the account's
/// seed. The LiveKit server stamps every packet with its sender's identity,
/// which the call server chose, so a device that checks the MAC against that
/// identity knows the sender is on this account. Others on the call learn
/// nothing of the account from it, and cannot replay it: under their own
/// identity it no longer checks.
public struct CallHandoff: Sendable {
    /// The text stream topic the announcement goes on, apart from the chat's.
    public static let topic = "peel-handoff"
    /// How long to wait before each try again of an announcement that could
    /// not be sent: both devices staying on the call is what it prevents.
    public static let retryDelays: [Duration] = [.seconds(1), .seconds(2)]

    private let key: SymmetricKey

    init(seed: String) {
        key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(seed.utf8)),
            info: Data("peel call handoff v1".utf8),
            outputByteCount: 32
        )
    }

    /// What a device that has just connected to `room` as `identity` sends:
    /// the MAC alone. With `stay`, the device says it is keeping both: the
    /// MAC is over a different message, so no build (this one's `shouldLeave`
    /// or an older one) takes it for a plain announcement and leaves.
    public func announcement(room: String, identity: String, stay: Bool = false) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Self.message(room: room, identity: identity, stay: stay), using: key))
    }

    /// Whether `data` proves `sender`, on `room`, is another device on this
    /// account (a plain announcement): the MAC checks
    /// under the sender's identity, which the server stamps, and it is not
    /// this device's own. Says nothing of who joined first.
    public func isOtherDevice(_ data: Data, room: String, sender: String, me: String) -> Bool {
        sender != me
            && HMAC<SHA256>.isValidAuthenticationCode(
                data, authenticating: Self.message(room: room, identity: sender, stay: false), using: key)
    }

    /// Whether this device, on `room` as `me`, should leave on `data` from
    /// `sender`: it must come from another device on this account that
    /// joined after this one did. A join time unknown on either side counts
    /// the sender as newer (it has only just announced); the same time is
    /// settled by identity, so two devices joining at once never both leave.
    public func shouldLeave(
        _ data: Data, room: String, sender: String, senderJoinedAt: Date?, me: String, myJoinedAt: Date?
    ) -> Bool {
        // A stay announcement is over another message and never checks here.
        guard isOtherDevice(data, room: room, sender: sender, me: me) else { return false }
        guard let senderJoinedAt, let myJoinedAt else { return true }
        return senderJoinedAt == myJoinedAt ? sender > me : senderJoinedAt > myJoinedAt
    }

    /// The room and identity, length-prefixed so no two pairs read alike.
    private static func message(room: String, identity: String, stay: Bool) -> Data {
        Data("\(stay ? "stay:" : "")\(room.utf8.count):\(room)\(identity.utf8.count):\(identity)".utf8)
    }
}
