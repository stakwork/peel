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
    /// The microphone has been asked for once the room connected: until
    /// then it is neither on nor muted.
    private(set) var micReady = false
    /// The system refused the microphone: the agent cannot hear the member.
    private(set) var micRefused = false
    /// Something that went wrong with the microphone or the voice, said quietly.
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
    /// Jamie's voice the agent has been told (as the call began, the home's
    /// answer), the one the member wants, and whether it is being told now.
    @ObservationIgnored private var toldVoice: TalkVoice?
    @ObservationIgnored private var wantedVoice: TalkVoice?
    @ObservationIgnored private var tellingVoice = false
    #if os(iOS)
    @ObservationIgnored private var routeChanges: (any NSObjectProtocol)?
    #endif

    init(ticket: TalkTicket, home: TalkHome) {
        self.home = home
        identity = ticket.identity
        agent = ticket.agent
        toldVoice = ticket.voice
        #if os(iOS)
        IOSCallSession.activateAudioSession()
        routeChanges = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated { self?.routeChanged(raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))) }
        }
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
        // Not awaited by `leave`: a microphone prompt nobody answers must not
        // hold the call open.
        Task {
            await setMicrophone(true)
            micReady = true
        }
        // A voice switched while connecting.
        Task { await tellVoice() }
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
        routeChanges.map(NotificationCenter.default.removeObserver)
        IOSCallSession.deactivateAudioSession()
        #endif
    }

    #if os(iOS)
    /// Headphones in or out, a Bluetooth headset coming or going: the audio
    /// session set up again and the microphone reopened, as `IOSCallSession`
    /// does. Our own category change comes back as one too: only while the
    /// room is up, and not during a switch.
    private func routeChanged(_ reason: AVAudioSession.RouteChangeReason?) {
        guard let reason, [.newDeviceAvailable, .oldDeviceUnavailable, .categoryChange, .override].contains(reason),
              room.connectionState == .connected, !leaving, !switchingMic else { return }
        IOSCallSession.activateAudioSession()
        guard micOn else { return }
        Task {
            await setMicrophone(false)
            await setMicrophone(true)
        }
    }
    #endif

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

    // MARK: Jamie's voice

    func setVoice(_ voice: TalkVoice) {
        wantedVoice = voice
        Task { await tellVoice() }
    }

    private static let voiceNotice = "Could not switch Jamie's voice"

    /// Sets the member's participant attribute `voice` to the voice wanted,
    /// once the room is connected (until then `connect` does it); the agent
    /// switches from its next sentence. The member's token allows it
    /// (strut's plans/private-voice.md §4.1). A switch made while one is on
    /// its way is told after it.
    private func tellVoice() async {
        guard !tellingVoice, !leaving, room.connectionState == .connected else { return }
        tellingVoice = true
        defer { tellingVoice = false }
        while let wanted = wantedVoice, wanted != toldVoice, !leaving {
            var attributes = room.localParticipant.attributes
            attributes[TalkVoice.attribute] = wanted.rawValue
            do {
                try await room.localParticipant.set(attributes: attributes)
                toldVoice = wanted
                if notice == Self.voiceNotice { notice = nil }
            } catch {
                if !leaving { notice = Self.voiceNotice }
                return
            }
        }
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
