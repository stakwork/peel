import Foundation
import LiveKit
import PeelCore

/// A call room's end-to-end encryption, the same for Talk and group calls
/// on the phone and the Mac (docs/talk.md; docs/hive-calls.md, "From a box").
enum CallRoom {
    /// The key provider for a call's key: the key string as the link or the
    /// home has it, shared by everyone on the call. The SDK keys with its
    /// UTF-8 bytes, as meet and a box's voice service do.
    static func encryption(key: String) -> EncryptionOptions {
        EncryptionOptions(keyProvider: BaseKeyProvider(isSharedKey: true, sharedKey: key))
    }

    /// The microphone on an encrypted call: no Opus RED, which the server
    /// can't repackage for an encrypted track and this SDK leaves on under
    /// encryption, and no DTX, so packets keep a steady rate through silence.
    static let encryptedAudio = AudioPublishOptions(dtx: false, red: false)

    /// A group call's room options for `link`. A link with a key (a box's
    /// Jamie is in the call) is joined encrypted: `encryptionOptions`, never
    /// the deprecated `e2eeOptions`, so the call's chat and Jamie's replies
    /// on the data channel are encrypted as well as the media. A call in
    /// the clear joins as before.
    static func options(for link: CallLink) -> RoomOptions {
        guard let key = link.encryptionKey else { return RoomOptions(adaptiveStream: true, dynacast: true) }
        return RoomOptions(
            defaultAudioPublishOptions: encryptedAudio, adaptiveStream: true, dynacast: true,
            encryptionOptions: encryption(key: key)
        )
    }
}

/// Hears a room's encryption (a `RoomDelegate`, which LiveKit calls on its
/// own queues) and hands each change to its session on the main queue, in
/// order.
final class CallEncryptionWatch: NSObject, RoomDelegate, Sendable {
    enum Change: Sendable {
        /// A track's state, by publication id: `failed` for a missing key or
        /// frames that will not encrypt or decrypt; `local` for this side's own.
        case track(String, local: Bool, failed: Bool)
        /// A data packet would not decrypt.
        case data
    }

    private let onChange: @MainActor @Sendable (Change) -> Void

    init(_ onChange: @escaping @MainActor @Sendable (Change) -> Void) {
        self.onChange = onChange
    }

    func room(_ room: Room, trackPublication: TrackPublication, didUpdateE2EEState state: E2EEState) {
        let failed = [.missing_key, .encryption_failed, .decryption_failed, .internal_error].contains(state)
        send(.track(trackPublication.sid.stringValue, local: trackPublication is LocalTrackPublication, failed: failed))
    }

    func room(_ room: Room, didFailToDecryptDataWithEror error: LiveKitError) {
        send(.data)
    }

    private func send(_ change: Change) {
        let onChange = onChange
        DispatchQueue.main.async { MainActor.assumeIsolated { onChange(change) } }
    }
}

extension Room {
    /// The name of whoever publishes the track `sid` on this room, for an
    /// encryption notice; nil for this side's own, or a track gone.
    func publisherName(ofTrack sid: String) -> String? {
        remoteParticipants.values.first { $0.trackPublications.keys.contains { $0.stringValue == sid } }?.name
    }
}
