import AVFoundation
import Combine
import LiveKit
import PeelCore
import PeelUI

/// A Talk call's room (docs/talk.md), on the phone and the Mac: the LiveKit
/// room an org's home named for a call with its agent, the microphone, and
/// what the call screen shows of it, the agent's state and the live text
/// (`TalkPhase`, `TalkTranscript`). The ticket's token goes to LiveKit and is
/// not kept.
///
/// Apple's voice processing stays on, as for every call (LiveKit's default,
/// and on the phone a `.voiceChat` audio session, `IOSCallSession`'s), so
/// the agent never hears itself and the member interrupts it just by
/// speaking. Mute is for talking to someone else in the room.
@MainActor @Observable
final class TalkSession: TalkMedia {
    let home: TalkHome
    private(set) var phase = TalkPhase.connecting
    private(set) var transcript = TalkTranscript()
    private(set) var micOn = false
    /// The system refused the microphone: the agent cannot hear the member.
    private(set) var micRefused = false
    /// Something that went wrong with the microphone, said quietly.
    private(set) var notice: String?

    @ObservationIgnored private let identity: String
    @ObservationIgnored private let agent: String
    /// Step 2 joins with `RoomOptions(defaultAudioPublishOptions:
    /// AudioPublishOptions(dtx: false, red: false), encryptionOptions:)`,
    /// the call's shared key in a shared-key provider (plans/private-voice.md §2, §4.1).
    @ObservationIgnored private let room = Room()
    @ObservationIgnored private var connecting: Task<Void, Never>?
    @ObservationIgnored private var changes: AnyCancellable?
    @ObservationIgnored private var failed = false
    @ObservationIgnored private var connectedOnce = false
    @ObservationIgnored private var agentSeen = false
    @ObservationIgnored private var leaving = false
    @ObservationIgnored private var switchingMic = false

    init(ticket: TalkTicket, home: TalkHome) {
        self.home = home
        identity = ticket.identity
        agent = ticket.agent
        #if os(iOS)
        IOSCallSession.activateAudioSession()
        #endif
        // The room changes many times a second while anyone speaks; the
        // phase is worked out from it at most ten times a second.
        changes = room.objectWillChange
            .throttle(for: .milliseconds(100), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        let url = ticket.url.absoluteString, token = ticket.token
        connecting = Task { [weak self] in await self?.connect(url: url, token: token) }
    }

    private func connect(url: String, token: String) async {
        // Before the room connects, so no line is missed.
        try? await room.registerTextStreamHandler(for: TalkTranscript.topic) { [weak self] reader, sender in
            let stream = reader.info.id, attributes = reader.info.attributes
            for try await chunk in reader {
                await self?.received(chunk, stream: stream, sender: sender.stringValue, attributes: attributes)
            }
        }
        do {
            try await room.connect(url: url, token: token)
        } catch {
            failed = true
            refresh()
            return
        }
        guard !Task.isCancelled else { return }
        await setMicrophone(true)
    }

    private func received(_ chunk: String, stream: String, sender: String, attributes: [String: String]) {
        guard !leaving else { return }
        let tracks = Set(room.localParticipant.trackPublications.keys.map(\.stringValue))
        transcript.receive(chunk, stream: stream, sender: sender, attributes: attributes, you: identity, yourTracks: tracks)
    }

    /// Hangs up: leaves once a join still in flight has finished, so it
    /// cannot outlive the call, then gives the phone's audio session back.
    func leave() async {
        guard !leaving else { return }
        leaving = true
        connecting?.cancel()
        await connecting?.value
        changes = nil
        await room.unregisterTextStreamHandler(for: TalkTranscript.topic)
        await room.disconnect()
        #if os(iOS)
        IOSCallSession.deactivateAudioSession()
        #endif
    }

    // MARK: The microphone

    func toggleMicrophone() {
        Task { await setMicrophone(!micOn) }
    }

    private func setMicrophone(_ on: Bool) async {
        guard !switchingMic, !leaving else { return }
        switchingMic = true
        defer { switchingMic = false }
        #if os(macOS)
        // The offscreen check (scripts/check-app.sh) asks for no device.
        if on, AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined, Offscreen.refuses("a device prompt") {
            micRefused = true
            return
        }
        #endif
        if on, !(await VoiceRecorder.permission()) {
            micRefused = true
            return
        }
        micRefused = false
        do {
            try await room.localParticipant.setMicrophone(enabled: on)
            notice = nil
        } catch {
            if on { notice = "Could not turn the microphone on" }
        }
        refresh()
    }

    // MARK: The room

    private func refresh() {
        let connection: TalkPhase.Connection = switch room.connectionState {
        case .connected: .connected
        case .reconnecting: .reconnecting
        case .connecting: .connecting
        case .disconnected, .disconnecting: .disconnected
        }
        if connection == .connected { connectedOnce = true }
        // Not connected yet and not failed: still on the way.
        let notYet = connection == .disconnected && !connectedOnce && !failed
        let participant = room.remoteParticipants.values.first { $0.identity?.stringValue == agent }
        if participant != nil { agentSeen = true }
        let next = TalkPhase(
            connection: notYet ? .connecting : connection, connectedOnce: connectedOnce,
            agentState: participant.map { $0.attributes[TalkAgentState.attribute] ?? "" }, agentSeen: agentSeen
        )
        if next != phase { phase = next }
        let mic = room.localParticipant.isMicrophoneEnabled()
        if mic != micOn { micOn = mic }
    }
}
