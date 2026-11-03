import Foundation
import LiveKit
import PeelCore

/// The LiveKit half of `CallHandoff`, for both apps' call sessions.
///
/// It goes as a text stream, not a data packet: a stream handler is given
/// the sender's identity from the outer packet, which the LiveKit server
/// stamps, while `RoomDelegate`'s data callback looks the sender up from the
/// inner packet's, which current servers leave empty, so it names nobody.
extension CallHandoff {
    /// Tells this account's other devices on `room` that this one joined as
    /// `identity`, trying again on `retryDelays` until it is sent or
    /// `leaving` says the call is over.
    @MainActor
    func announce(
        on room: Room, roomName: String, identity: String, stay: Bool = false, topic: String? = nil,
        leaving: @escaping @MainActor () -> Bool
    ) async {
        let text = announcement(room: roomName, identity: identity, stay: stay).base64EncodedString()
        for delay in [nil] + Self.retryDelays.map(Optional.some) {
            if let delay { try? await Task.sleep(for: delay) }
            if leaving() { return }
            if (try? await room.localParticipant.sendText(text, for: topic ?? Self.topic)) != nil { return }
        }
    }

    /// Answers other devices' probes on `room` (as `me`), and calls `found`
    /// on the main actor for an answer to this device's own. Set up before
    /// the room connects. The caller decides whether an answer still counts.
    func listenForDevices(
        on room: Room, roomName: String, me: String, found: @escaping @Sendable @MainActor () -> Void
    ) async {
        try? await room.registerTextStreamHandler(for: Self.probeTopic) { reader, sender in
            guard let text = try? await reader.readAll(), text.utf8.count <= 64,
                  let data = Data(base64Encoded: text),
                  isOtherDevice(data, room: roomName, sender: sender.stringValue, me: me)
            else { return }
            Task { @MainActor in
                await announce(on: room, roomName: roomName, identity: me, topic: Self.hereTopic) { false }
            }
        }
        try? await room.registerTextStreamHandler(for: Self.hereTopic) { reader, sender in
            guard let text = try? await reader.readAll(), text.utf8.count <= 64,
                  let data = Data(base64Encoded: text),
                  isOtherDevice(data, room: roomName, sender: sender.stringValue, me: me)
            else { return }
            await found()
        }
    }

    /// Listens on `room` (as `me`) for another device on this account that
    /// joined after this one, and calls `leave` on the main actor if one
    /// does. Set up before the room connects.
    func listen(on room: Room, roomName: String, me: String, leave: @escaping @Sendable @MainActor () -> Void) async {
        try? await room.registerTextStreamHandler(for: Self.topic) { reader, sender in
            guard let text = try? await reader.readAll(), text.utf8.count <= 64,
                  let data = Data(base64Encoded: text)
            else { return }
            // The announcement comes before the room has added its sender
            // (seconds later, on a local server under load), and their join
            // time settles two devices joining at once, so it waits for them
            // for up to 10 s; in a task of its own, since LiveKit cancels the
            // handler's once the stream ends. Unknown after that, the sender
            // counts as newer.
            Task {
                var joinedAt = room.remoteParticipants[sender]?.joinedAt
                for _ in 0..<100 where joinedAt == nil {
                    try? await Task.sleep(for: .milliseconds(100))
                    joinedAt = room.remoteParticipants[sender]?.joinedAt
                }
                let leaves = shouldLeave(
                    data, room: roomName, sender: sender.stringValue, senderJoinedAt: joinedAt,
                    me: me, myJoinedAt: room.localParticipant.joinedAt
                )
                if leaves { await leave() }
            }
        }
    }
}
