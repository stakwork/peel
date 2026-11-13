import Accelerate
import AudioToolbox
import AVFoundation
import Combine
import LiveKit
import PeelCore
import PeelUI
import Synchronization

/// A Talk call's room (docs/talk.md), on the phone and the Mac: the LiveKit
/// room an org's home named for a call with its agent, the microphone, and
/// what the call screen shows of it, the agent's state and the live text
/// (`TalkPhase`, `TalkTranscript`). The ticket's token and key go to LiveKit
/// and are not kept.
///
/// The room is end-to-end encrypted with the call's key (docs/talk.md), the
/// audio both ways and the live text: the LiveKit server forwards what it
/// cannot read.
///
/// Apple's voice processing stays on, as for every call (LiveKit's default;
/// on the phone LiveKit also sets the audio session up, as for calls), so
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
    /// The call's encryption failing (`TalkEncryption`): said before anything else.
    private(set) var encryptionNotice: String?

    /// The cards Jamie sent (`TalkArtifacts`), in the order they came, each
    /// with where it goes in the transcript (`TalkCardAnchor`).
    private(set) var cards: [TalkCard] = []
    /// The newest cards kept.
    static let maxCards = 30

    /// True once the transcript cap warning sound has been played this call.
    @ObservationIgnored private var capSoundPlayed = false
    @ObservationIgnored private var seenArtifacts = Set<String>()
    @ObservationIgnored private let identity: String
    @ObservationIgnored private let agent: String
    /// One room per call: its encryption is set as it connects (`options(key:)`).
    @ObservationIgnored private let room = Room()
    @ObservationIgnored private var encryption = TalkEncryption()
    /// Hears the room's encryption state; the room holds its delegates weakly.
    @ObservationIgnored private var encryptionWatch: TalkEncryptionWatch?
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
    /// How loud Jamie and the member are, for the call screen's waveform:
    /// fed by the agent's audio track and the microphone, read by `level(of:)`.
    @ObservationIgnored private let agentMeter = TalkLevelMeter()
    @ObservationIgnored private let micMeter = TalkLevelMeter()
    /// The agent's track `agentMeter` listens to.
    @ObservationIgnored private var heardTrack: RemoteAudioTrack?
    #if os(iOS)
    @ObservationIgnored private var routeChanges: (any NSObjectProtocol)?
    #endif

    init(ticket: TalkTicket, home: TalkHome) {
        self.home = home
        identity = ticket.identity
        agent = ticket.agent
        toldVoice = ticket.voice
        #if os(iOS)
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
        // The microphone after voice processing, as the agent hears it.
        AudioManager.shared.add(localAudioRenderer: micMeter)
        // Before the room connects, so a key that doesn't match is heard.
        let watch = TalkEncryptionWatch { [weak self] change in self?.encryptionChanged(change) }
        room.add(delegate: watch)
        encryptionWatch = watch
        let url = ticket.url.absoluteString, token = ticket.token, options = Self.options(key: ticket.key)
        connecting = Task { [weak self] in await self?.connect(url: url, token: token, options: options) }
    }

    /// The room's options for a call's key:
    /// - `encryptionOptions`, never the deprecated `e2eeOptions`, so the
    ///   agent's live text on the data channel is encrypted as well as the
    ///   audio. The shared key is the key string as the home has it (the SDK
    ///   keys with its UTF-8 bytes, and so does the agent).
    /// - The microphone without Opus RED, which the server can't repackage
    ///   for an encrypted track and this SDK leaves on under encryption, and
    ///   without DTX, so packets keep a steady rate through silence.
    static func options(key: String) -> RoomOptions {
        RoomOptions(
            defaultAudioPublishOptions: AudioPublishOptions(dtx: false, red: false),
            encryptionOptions: EncryptionOptions(keyProvider: BaseKeyProvider(isSharedKey: true, sharedKey: key))
        )
    }

    private func connect(url: String, token: String, options: RoomOptions) async {
        // Before the room connects, so no line is missed.
        try? await room.registerTextStreamHandler(for: TalkTranscript.topic) { [weak self] reader, sender in
            let stream = reader.info.id, attributes = reader.info.attributes
            for try await chunk in reader {
                await self?.received(chunk, stream: stream, sender: sender.stringValue, attributes: attributes)
            }
        }
        try? await room.registerTextStreamHandler(for: TalkArtifacts.topic) { [weak self] reader, _ in
            let text = try await reader.readAll()
            await self?.receivedArtifacts(text)
        }
        do {
            try await room.connect(url: url, token: token, roomOptions: options)
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
        let wasUnderCap = transcript.lines.count < TalkTranscript.maxLines
        transcript.receive(chunk, stream: stream, sender: sender, attributes: attributes, you: identity, yourTracks: tracks)
        // Warn once when the transcript first hits its cap and lines start being dropped.
        if wasUnderCap, transcript.lines.count >= TalkTranscript.maxLines, !capSoundPlayed {
            capSoundPlayed = true
            AudioServicesPlaySystemSound(1057)
        }
    }

    /// One turn's artifacts, each a card anchored in the transcript so far.
    /// A payload seen before (by its id) adds nothing.
    private func receivedArtifacts(_ text: String) {
        guard !leaving, text.utf8.count <= 256 * 1024, let batch = TalkArtifacts.batch(text, workspace: home.id),
              seenArtifacts.insert(batch.id).inserted else { return }
        let anchor = TalkCardAnchor(transcript)
        for (index, artifact) in batch.artifacts.enumerated() {
            cards.append(TalkCard(id: "\(batch.id)/\(index)", artifact: artifact, anchor: anchor))
        }
        if cards.count > Self.maxCards { cards.removeFirst(cards.count - Self.maxCards) }
    }

    /// Hangs up: leaves once a join still in flight has finished, so it
    /// cannot outlive the call, then gives the phone's audio session back.
    func leave() async {
        guard !leaving else { return }
        leaving = true
        connecting?.cancel()
        await connecting?.value
        changes = nil
        AudioManager.shared.remove(localAudioRenderer: micMeter)
        heardTrack?.remove(audioRenderer: agentMeter)
        heardTrack = nil
        await room.unregisterTextStreamHandler(for: TalkTranscript.topic)
        await room.unregisterTextStreamHandler(for: TalkArtifacts.topic)
        await room.disconnect()
        #if os(iOS)
        routeChanges.map(NotificationCenter.default.removeObserver)
        IOSCallSession.deactivateAudioSession()
        #endif
    }

    #if os(iOS)
    /// Headphones in or out, a Bluetooth headset coming or going: the session
    /// is kept active, and LiveKit's audio engine follows the new route itself.
    /// The microphone is no longer turned off and on here: a category change
    /// (LiveKit setting the session up, often as the microphone starts) came
    /// back as a route change and restarted it, in a loop, as on calls.
    private func routeChanged(_ reason: AVAudioSession.RouteChangeReason?) {
        guard let reason, [.newDeviceAvailable, .oldDeviceUnavailable, .override].contains(reason),
              room.connectionState == .connected, !leaving else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
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

    // MARK: Encryption

    private func encryptionChanged(_ change: TalkEncryptionWatch.Change) {
        guard !leaving else { return }
        switch change {
        case let .track(id, local, failed): encryption.track(id, local: local, failed: failed)
        case .text: encryption.textFailedToDecrypt()
        }
        if encryption.notice != encryptionNotice { encryptionNotice = encryption.notice }
    }

    // MARK: The waveform

    /// How loud `speaker` has been since the last read, 0…1 (`TalkWave.loudness`):
    /// what the call screen's waveform samples on its own clock, so nothing
    /// here is observed. The member's is zero while muted.
    func level(of speaker: TalkLine.Speaker) -> Double {
        switch speaker {
        case .agent: agentMeter.take()
        case .you: micOn ? micMeter.take() : 0
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
        // The agent's voice to the waveform; a track republished is followed.
        let track = participant?.firstAudioTrack as? RemoteAudioTrack
        if track !== heardTrack, !leaving {
            heardTrack?.remove(audioRenderer: agentMeter)
            track?.add(audioRenderer: agentMeter)
            heardTrack = track
        }
        let next = TalkPhase(
            connection: notYet ? .connecting : connection, connectedOnce: connectedOnce,
            agentState: participant.map { $0.attributes[TalkAgentState.attribute] ?? "" }, agentSeen: agentSeen
        )
        if next != phase { phase = next }
        let mic = room.localParticipant.isMicrophoneEnabled()
        if mic != micOn { micOn = mic }
    }
}

/// One artifact Jamie sent on the call, shown where its anchor puts it in
/// the transcript.
struct TalkCard: Identifiable, Equatable {
    let id: String
    let artifact: AgentArtifact
    let anchor: TalkCardAnchor
}

/// Hears a Talk room's encryption (a `RoomDelegate`, which LiveKit calls on
/// its own queues) and hands each change to the session on the main queue,
/// in order.
private final class TalkEncryptionWatch: NSObject, RoomDelegate, Sendable {
    enum Change: Sendable {
        /// A track's state: `failed` for a missing key or frames that will
        /// not encrypt or decrypt; `local` for the member's own track.
        case track(String, local: Bool, failed: Bool)
        /// A packet of the agent's text would not decrypt.
        case text
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
        send(.text)
    }

    private func send(_ change: Change) {
        let onChange = onChange
        DispatchQueue.main.async { MainActor.assumeIsolated { onChange(change) } }
    }
}

/// The loudness of one side of a Talk call, fed from LiveKit's audio thread
/// (an `AudioRenderer`, about every 10 ms) and read by the call screen about
/// 30 times a second: the loudest buffer since the last read, so no syllable
/// falls between two frames.
final class TalkLevelMeter: NSObject, AudioRenderer, Sendable {
    private let loudest = Mutex<Double>(0)

    func render(pcmBuffer: AVAudioPCMBuffer) {
        let level = TalkWave.loudness(rms: Self.rms(pcmBuffer))
        loudest.withLock { $0 = max($0, level) }
    }

    /// The loudest since the last read, and it starts again.
    func take() -> Double {
        loudest.withLock { value in
            defer { value = 0 }
            return value
        }
    }

    /// The first channel's RMS, in linear full scale.
    private static func rms(_ buffer: AVAudioPCMBuffer) -> Double {
        let frames = Int(buffer.frameLength), stride = buffer.stride
        guard frames > 0 else { return 0 }
        if let data = buffer.floatChannelData {
            var rms: Float = 0
            vDSP_rmsqv(data[0], stride, &rms, vDSP_Length(frames))
            return Double(rms)
        }
        if let data = buffer.int16ChannelData {
            var sum: Float = 0
            for frame in 0 ..< frames {
                let sample = Float(data[0][frame * stride]) / 32768
                sum += sample * sample
            }
            return Double((sum / Float(frames)).squareRoot())
        }
        return 0
    }
}
