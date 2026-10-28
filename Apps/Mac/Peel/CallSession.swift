import AVFoundation
import Combine
import SwiftUI
import LiveKit
import PeelCore
import PeelUI

/// The call this Mac is on: owns the LiveKit room for one call, its
/// microphone, camera and devices, and what the window and the sidebar show
/// of it. The ticket's token goes to LiveKit and is not kept.
///
/// The microphone starts on and the camera off; only the person who started
/// a video call starts with the camera on.
@MainActor @Observable
final class CallSession {
    enum State: Equatable {
        case connecting, connected, reconnecting
        /// The connection is gone (or never came) and LiveKit gave up.
        case lost
    }

    /// One person in the grid, or a screen they share. Names and photos
    /// are what each joiner sent.
    struct Tile: Identifiable, Equatable {
        struct ID: Hashable {
            let identity: String
            let isScreen: Bool
        }

        let person: CallParticipant
        let isYou: Bool
        /// Their shared screen rather than them.
        let isScreen: Bool
        var speaking: Bool
        var muted: Bool
        /// Their camera while it is on and arriving, or the screen they share.
        var video: VideoTrack?
        var id: ID { ID(identity: person.identity, isScreen: isScreen) }

        static func == (a: Tile, b: Tile) -> Bool {
            a.person == b.person && a.isYou == b.isYou && a.isScreen == b.isScreen && a.speaking == b.speaking
                && a.muted == b.muted && a.video === b.video
        }
    }

    /// macOS's answer for the microphone or the camera.
    enum Access { case allowed, undecided, refused }

    struct Device: Identifiable, Equatable {
        let id: String
        let name: String
    }

    let link: CallLink
    let chat: String
    /// "#tribe" or the contact, as the call began.
    let title: String
    /// This side's identity on the call (the token's), to tell you apart
    /// in the presence feed.
    let identity: String
    /// The name this side joined with, sent as the sender of its chat messages.
    let participantName: String
    private(set) var state = State.connecting
    /// When the room first connected: the running time counts from here.
    private(set) var connectedAt: Date?
    /// Everyone on the call, the others in the order they joined, you last.
    private(set) var tiles: [Tile] = []
    private(set) var micOn = false
    /// Whether the call server is recording the call (the room says so);
    /// everyone on it must be told.
    private(set) var isRecording = false
    private(set) var cameraOn = false
    /// Whether you last chose the camera on (or started a video call):
    /// what a rejoin brings back.
    @ObservationIgnored private(set) var wantsCamera: Bool
    private(set) var micAccess = Access.undecided
    private(set) var cameraAccess = Access.undecided
    private(set) var microphones: [Device] = []
    private(set) var speakers: [Device] = []
    private(set) var cameras: [Device] = []
    private(set) var microphone: String?
    private(set) var speaker: String?
    private(set) var camera: String?
    /// A device that went away mid-call, said quietly under the bar.
    private(set) var deviceNotice: String?
    /// What you share, while you share it (and while it is being published).
    var sharing: ScreenShare.Content? { share?.content }
    /// Whether the next share includes Peel's own windows, which are left out
    /// by default. Applies when a share starts, not to one already running.
    var includePeelWindows = false
    /// Whether the running share includes Peel's own windows.
    var sharingIncludesPeel: Bool { share?.includesPeel ?? false }
    /// The tile shown large with the others in a strip beside it; nil for
    /// the grid. A screen someone starts sharing takes it.
    private(set) var focus: Tile.ID?
    /// The call window floats above other apps' windows, for this call.
    var keepOnTop = false

    // MARK: Chat state

    /// The call's chat, oldest first; in memory for this call only.
    var chatRows: [CallChatLog.Row] { log.rows }
    /// Messages from others that came while the panel was closed.
    private(set) var chatUnread = 0
    /// Whether the chat panel is open beside the call.
    private(set) var chatOpen = false
    /// Jamie is working on a request (it sent a status row, no answer yet);
    /// only ever set while Jamie is in the call.
    var jamieThinking: Bool { jamieInCall && log.jamieThinking }
    /// Jamie is in the call: a remote participant named "Jamie" with the
    /// `tts` attribute a sphinx-voice agent sets. Nil attribute: a person who
    /// happens to be called Jamie.
    private(set) var jamieInCall = false
    /// Jamie is still on the last request, so another may be skipped.
    var jamieBusy: Bool { jamieThinking }
    /// A short-lived hint above the composer.
    private(set) var chatNotice: String?
    private var log = CallChatLog()
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    @ObservationIgnored private let room = Room(roomOptions: RoomOptions(adaptiveStream: true, dynacast: true))
    @ObservationIgnored private var connecting: Task<Void, Never>?
    @ObservationIgnored private var failed = false
    @ObservationIgnored private var leaving = false
    @ObservationIgnored private var switchingMic = false
    @ObservationIgnored private var switchingCamera = false
    @ObservationIgnored private var switchingShare = false
    private var share: ScreenShare?
    @ObservationIgnored private var sharePublication: LocalTrackPublication?
    /// Every screen track seen on this call, so one that comes back after
    /// a pause or a reconnect does not take the focus again.
    @ObservationIgnored private var seenScreenTracks: Set<String> = []
    @ObservationIgnored private var changes: AnyCancellable?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    /// Each person as last read, by identity, with the name and metadata
    /// it was read from: the room changes many times a second while people
    /// speak, their metadata almost never.
    @ObservationIgnored private var readPeople: [String: (name: String?, metadata: String?, person: CallParticipant?)] = [:]
    /// The microphone and speaker picked, kept here since LiveKit reads
    /// back no device once one is set; for the app, as LiveKit's are. Nil
    /// follows the system's default.
    private static var pickedMicrophone: String?
    private static var pickedSpeaker: String?
    /// The session audio device changes go to: the newest.
    private static weak var audioDevicesOwner: CallSession?

    init(ticket: CallTicket, link: CallLink, chat: String, title: String, camera: Bool) {
        self.link = link
        self.chat = chat
        self.title = title
        identity = ticket.identity
        participantName = ticket.participantName
        wantsCamera = camera
        refreshAccess()
        refreshAudioDevices()
        // LiveKit tells SwiftUI on the main queue after each change to the
        // room, a participant or a track (audio levels included, several
        // times a second per speaker); the tiles are worked out from it at
        // most ten times a second.
        changes = room.objectWillChange
            .throttle(for: .milliseconds(100), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        // One handler for the app: a session left after the next one began
        // (a switch, a rejoin) must not take it away from that one.
        Self.audioDevicesOwner = self
        AudioManager.shared.onDeviceUpdate = { _ in
            Task { @MainActor in CallSession.audioDevicesOwner?.audioDevicesChanged() }
        }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main) { [weak self] note in
                guard let device = note.object as? AVCaptureDevice, device.hasMediaType(.video) else { return }
                let id = device.uniqueID
                MainActor.assumeIsolated { self?.cameraUnplugged(id) }
            },
            center.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: .main) { [weak self] note in
                guard (note.object as? AVCaptureDevice)?.hasMediaType(.video) == true else { return }
                MainActor.assumeIsolated { _ = Task { await self?.refreshCameras() } }
            },
            // Back from System Settings with access granted, or taken away.
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshAccess() }
            },
        ]
        let url = ticket.serverURL.absoluteString, token = ticket.token
        connecting = Task { [weak self] in await self?.connect(url: url, token: token, camera: camera) }
        Task { await refreshCameras() }
        room.add(delegate: self)
        // Your own tile from the start, while the room connects.
        refresh()
    }

    /// Whether you are on the call, or on your way.
    var isOn: Bool { state != .lost }

    /// Everyone on the call, for the sidebar's avatars; apart from the
    /// tiles so speaking and muting do not redraw the sidebar.
    private(set) var people: [CallParticipant] = []

    /// The running time while connected ("03:18", "1:02:07" past the hour),
    /// or what the connection is doing.
    func status(at now: Date) -> String {
        switch state {
        case .connecting: return "Connecting…"
        case .reconnecting: return "Reconnecting…"
        case .lost: return "Disconnected"
        case .connected:
            guard let connectedAt else { return "" }
            let seconds = Int(max(0, now.timeIntervalSince(connectedAt)))
            return Duration.seconds(seconds)
                .formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond(padMinuteToLength: 2)))
        }
    }

    private func connect(url: String, token: String, camera: Bool) async {
        do {
            try await room.connect(url: url, token: token)
        } catch {
            failed = true
            refresh()
            return
        }
        guard !Task.isCancelled else { return }
        refresh()
        // Not awaited by `leave`: a microphone prompt nobody answers must not
        // hold the call open.
        Task {
            await setMicrophone(true)
            if camera { await setCamera(true) }
        }
    }

    /// Leaves once a join still in flight has finished, so it cannot outlive
    /// the call.
    func leave() async {
        guard !leaving else { return }
        leaving = true
        connecting?.cancel()
        await connecting?.value
        await stopSharing()
        // Chat is for this call only.
        noticeTask?.cancel()
        log = CallChatLog()
        chatNotice = nil
        chatUnread = 0
        chatOpen = false
        changes = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if Self.audioDevicesOwner === self {
            Self.audioDevicesOwner = nil
            AudioManager.shared.onDeviceUpdate = nil
        }
        await room.disconnect()
    }

    // MARK: Microphone and camera

    func toggleMicrophone() {
        Task { await setMicrophone(!micOn) }
    }

    func toggleCamera() {
        Task { await setCamera(!cameraOn) }
    }

    private func setMicrophone(_ on: Bool) async {
        guard !switchingMic, !leaving else { return }
        switchingMic = true
        defer { switchingMic = false }
        // Leaving may have happened while macOS asked.
        if on, await !mayUse(.audio) || leaving { return }
        do {
            try await room.localParticipant.setMicrophone(enabled: on)
        } catch {
            if on { deviceNotice = "Could not turn the microphone on" }
        }
        refresh()
    }

    /// Off unpublishes the camera rather than muting it, so turning it on
    /// again opens the camera chosen in the meantime.
    private func setCamera(_ on: Bool) async {
        guard !switchingCamera, !leaving else { return }
        switchingCamera = true
        defer { switchingCamera = false }
        if on, await !mayUse(.video) || leaving { return }
        let local = room.localParticipant
        do {
            if on {
                let device = camera.flatMap { AVCaptureDevice(uniqueID: $0) }
                try await local.setCamera(enabled: true, captureOptions: CameraCaptureOptions(device: device))
                wantsCamera = true
            } else if let publication = local.firstCameraPublication as? LocalTrackPublication {
                try await local.unpublish(publication: publication)
                wantsCamera = false
            }
        } catch {
            if on { deviceNotice = "Could not turn the camera on" }
        }
        refresh()
    }

    /// Asks macOS the first time; true when access is allowed.
    private func mayUse(_ media: AVMediaType) async -> Bool {
        if AVCaptureDevice.authorizationStatus(for: media) == .notDetermined, !Offscreen.refuses("a device prompt") {
            _ = await AVCaptureDevice.requestAccess(for: media)
        }
        refreshAccess()
        return (media == .audio ? micAccess : cameraAccess) == .allowed
    }

    private func refreshAccess() {
        func access(_ media: AVMediaType) -> Access {
            switch AVCaptureDevice.authorizationStatus(for: media) {
            case .authorized: .allowed
            case .notDetermined: .undecided
            default: .refused
            }
        }
        micAccess = access(.audio)
        cameraAccess = access(.video)
    }

    // MARK: Screen share

    /// Opens macOS's picker on `kind`.
    func startScreenShare(_ kind: ScreenShare.Content) {
        Task { await startSharing(kind) }
    }

    func stopScreenShare() {
        Task { await stopSharing() }
    }

    private func startSharing(_ kind: ScreenShare.Content) async {
        guard !switchingShare, !leaving, share == nil, state == .connected else { return }
        switchingShare = true
        defer { switchingShare = false }
        // Nothing is shared unless the picker returned something and the
        // call is still on when it did.
        guard let filter = await ScreenShare.pick(kind, includePeel: includePeelWindows), !leaving, state == .connected else { return }
        let started: ScreenShare
        do {
            started = try await ScreenShare.start(filter, includePeel: includePeelWindows) { [weak self] in self?.shareEnded() }
        } catch {
            deviceNotice = "Could not start sharing"
            return
        }
        // Stop shows at once: the screen is being captured from here.
        share = started
        if leaving || started.ended { return await stopSharing() }
        do {
            let publication = try await room.localParticipant.publish(videoTrack: started.track)
            // Stopped while it was being published.
            guard share === started else {
                try? await room.localParticipant.unpublish(publication: publication)
                return
            }
            sharePublication = publication
        } catch {
            await stopSharing()
            deviceNotice = "Could not start sharing"
        }
        refresh()
    }

    /// macOS ended a capture (Stop in the menu bar, a closed window): the
    /// share stops if it is the one still running.
    private func shareEnded() {
        guard share?.ended == true else { return }
        stopScreenShare()
    }

    private func stopSharing() async {
        guard let share else { return }
        self.share = nil
        await share.stop()
        if let publication = sharePublication {
            sharePublication = nil
            try? await room.localParticipant.unpublish(publication: publication)
        }
        refresh()
    }

    // MARK: Focus

    /// Click a tile to focus it; click the focused one for the grid again.
    func toggleFocus(_ id: Tile.ID) {
        focus = focus == id ? nil : id
    }

    func showGrid() {
        focus = nil
    }

    // MARK: Devices

    func chooseMicrophone(_ id: String) {
        guard let device = AudioManager.shared.inputDevices.first(where: { $0.deviceId == id }) else { return }
        AudioManager.shared.inputDevice = device
        Self.pickedMicrophone = id
        deviceNotice = nil
        refreshAudioDevices()
    }

    func chooseSpeaker(_ id: String) {
        guard let device = AudioManager.shared.outputDevices.first(where: { $0.deviceId == id }) else { return }
        AudioManager.shared.outputDevice = device
        Self.pickedSpeaker = id
        deviceNotice = nil
        refreshAudioDevices()
    }

    func chooseCamera(_ id: String) {
        camera = id
        deviceNotice = nil
        guard cameraOn, let device = AVCaptureDevice(uniqueID: id), let capturer = cameraCapturer else { return }
        Task { _ = try? await capturer.set(options: CameraCaptureOptions(device: device)) }
    }

    private func refreshAudioDevices() {
        let audio = AudioManager.shared
        let inputs = audio.inputDevices, outputs = audio.outputDevices
        microphones = inputs.map(Self.device)
        speakers = outputs.map(Self.device)
        microphone = Self.inUse(Self.pickedMicrophone, in: inputs)
        speaker = Self.inUse(Self.pickedSpeaker, in: outputs)
    }

    /// WebRTC lists the system's default as an entry of its own, named
    /// after the device it stands for, which is also listed by itself.
    private static func device(_ device: AudioDevice) -> Device {
        Device(id: device.deviceId, name: device.isDefault ? "System default (\(device.name))" : device.name)
    }

    /// The one picked while it is listed, else the system's default.
    private static func inUse(_ picked: String?, in list: [AudioDevice]) -> String? {
        list.contains { $0.deviceId == picked } ? picked : list.first { $0.isDefault }?.deviceId
    }

    /// A microphone or speaker came or went: one picked that went is
    /// replaced by the system's default, and the line under the bar says so.
    private func audioDevicesChanged() {
        guard !leaving else { return }
        let audio = AudioManager.shared
        let goneMic = audio.inputDevices.contains { $0.deviceId == microphone } ? nil : microphones.first { $0.id == microphone }
        let goneSpeaker = audio.outputDevices.contains { $0.deviceId == speaker } ? nil : speakers.first { $0.id == speaker }
        if goneMic != nil {
            audio.inputDevice = audio.defaultInputDevice
            Self.pickedMicrophone = nil
        }
        if goneSpeaker != nil {
            audio.outputDevice = audio.defaultOutputDevice
            Self.pickedSpeaker = nil
        }
        if let gone = goneMic ?? goneSpeaker {
            deviceNotice = "\(gone.name) was disconnected; using the default \(goneMic != nil ? "microphone" : "speaker")"
        }
        refreshAudioDevices()
    }

    private func refreshCameras() async {
        let devices = (try? await CameraCapturer.captureDevices()) ?? []
        cameras = devices.map { Device(id: $0.uniqueID, name: $0.localizedName) }
        if camera == nil || !cameras.contains(where: { $0.id == camera }) {
            camera = cameraCapturer?.device?.uniqueID ?? cameras.first?.id
        }
    }

    private var cameraCapturer: CameraCapturer? {
        (room.localParticipant.firstCameraVideoTrack as? LocalVideoTrack)?.capturer as? CameraCapturer
    }

    /// The camera in use went away: it turns off rather than jumping to
    /// another camera unasked.
    private func cameraUnplugged(_ id: String?) {
        guard !leaving else { return }
        if cameraOn, let id, id == camera {
            deviceNotice = "\(cameras.first { $0.id == id }?.name ?? "The camera") was disconnected"
            Task { await setCamera(false) }
        }
        Task { await refreshCameras() }
    }

    // MARK: The room

    /// Works the tiles and the state out from the room, after any change.
    private func refresh() {
        let local = room.localParticipant
        let others = room.remoteParticipants.values.sorted {
            ($0.joinedAt ?? .distantPast, $0.identity?.stringValue ?? "") < ($1.joinedAt ?? .distantPast, $1.identity?.stringValue ?? "")
        }
        // Shared screens first, then people; you last in each.
        let everyone: [(Participant, Bool)] = others.map { ($0, false) } + [(local, true)]
        let next = [true, false].flatMap { screen in everyone.compactMap { tile($0.0, isYou: $0.1, screen: screen) } }
        if next != tiles {
            tiles = next
            let everyone = next.filter { !$0.isScreen }.map(\.person)
            if everyone != people { people = everyone }
            refocus()
        }
        let mic = local.isMicrophoneEnabled(), cam = local.isCameraEnabled()
        if mic != micOn { micOn = mic }
        if cam != cameraOn { cameraOn = cam }
        if room.isRecording != isRecording { isRecording = room.isRecording }
        let jamie = others.contains {
            $0.name?.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("Jamie") == .orderedSame
                && $0.attributes["tts"] != nil
        }
        if jamie != jamieInCall {
            jamieInCall = jamie
            // Jamie left: nothing is coming.
            if !jamie { log.stopThinking() }
        }

        let now: State
        switch room.connectionState {
        case .connected:
            now = .connected
            if connectedAt == nil { connectedAt = .now }
        case .reconnecting:
            now = .reconnecting
        case .connecting:
            now = connectedAt == nil ? .connecting : .reconnecting
        case .disconnected, .disconnecting:
            now = connectedAt == nil && !failed ? .connecting : .lost
        }
        if now != state {
            state = now
            // No one sees it any more; stop capturing.
            if now == .lost, share != nil { stopScreenShare() }
        }
    }

    /// A screen someone shares that was not there before takes the focus
    /// (the newest, when several start); your own never does. When the
    /// focused tile goes, the newest screen still shared takes it after a
    /// screen, and the grid comes back after a person.
    private func refocus() {
        let shared = tiles.filter { $0.isScreen && !$0.isYou }
        let started = shared.filter { tile in
            tile.video?.sid.map { seenScreenTracks.insert($0.stringValue).inserted } ?? false
        }
        if let newest = started.last?.id {
            focus = newest
        } else if let focus, !tiles.contains(where: { $0.id == focus }) {
            self.focus = focus.isScreen ? shared.last?.id : nil
        }
    }

    /// Their tile, or the tile of the screen they share (nil when they share none).
    private func tile(_ participant: Participant, isYou: Bool, screen: Bool) -> Tile? {
        let video = Self.video(of: participant, screen: screen)
        guard !screen || video != nil, let id = isYou ? identity : participant.identity?.stringValue,
              let person = person(id, name: participant.name, metadata: participant.metadata)
        else { return nil }
        return Tile(
            person: person, isYou: isYou, isScreen: screen, speaking: !screen && participant.isSpeaking,
            muted: !screen && !participant.isMicrophoneEnabled(), video: video
        )
    }

    /// The screen they share, or their camera: the first video that is not
    /// a screen share, since some clients publish it with no source.
    private static func video(of participant: Participant, screen: Bool) -> VideoTrack? {
        participant.videoTracks
            .first { ($0.source == .screenShareVideo) == screen && !$0.isMuted && $0.isSubscribed }
            .flatMap { $0.track as? VideoTrack }
    }

    private func person(_ id: String, name: String?, metadata: String?) -> CallParticipant? {
        if let read = readPeople[id], read.name == name, read.metadata == metadata { return read.person }
        let person = CallParticipant(identity: id, name: name, metadata: metadata)
        readPeople[id] = (name, metadata, person)
        return person
    }
}

// MARK: - Chat

/// Longest a "Jamie is thinking…" line stays when no answer comes.
private let thinkingLimit = Duration.seconds(120)
/// How long the busy hint stays.
private let noticeLimit = Duration.seconds(6)

extension CallSession {
    /// Opens or closes the chat panel; opening reads what came meanwhile.
    func setChatOpen(_ open: Bool) {
        chatOpen = open
        if open { chatUnread = 0 }
    }

    /// Sends `text` to everyone on the call as the name you joined with:
    /// shown at once, then published on the chat topic. A publish that fails
    /// leaves the row marked "Not sent" for `retryChat`. Asking Jamie while
    /// it is still on the last request is allowed, with a hint.
    func sendChat(_ text: String) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !leaving else { return }
        let message = CallChatMessage(
            id: UUID().uuidString, timestamp: .now, text: text, sender: participantName
        )
        log.appendLocal(message)
        if CallChatWire.mentionsJamie(text), jamieBusy {
            showChatNotice("Jamie is still working on your last request; this one may be skipped.")
        }
        await publish(message)
    }

    /// Sends a row that failed again.
    func retryChat(_ id: String) async {
        guard let row = log.rows.first(where: { $0.id == id && $0.failed }) else { return }
        log.mark(id: id, failed: false)
        await publish(row.message)
    }

    private func publish(_ message: CallChatMessage) async {
        let data = CallChatWire.encode(
            id: message.id, timestamp: message.timestamp, text: message.text, sender: participantName
        )
        do {
            try await room.localParticipant.publish(
                data: data, options: DataPublishOptions(topic: CallChatWire.topic, reliable: true)
            )
        } catch {
            log.mark(id: message.id, failed: true)
        }
    }

    private func showChatNotice(_ text: String) {
        chatNotice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: noticeLimit)
            guard !Task.isCancelled else { return }
            self?.chatNotice = nil
        }
    }

    fileprivate func receiveChat(_ incoming: CallChatWire.Incoming) {
        guard !leaving else { return }
        let added = log.receive(incoming)
        if added != nil, !chatOpen { chatUnread += 1 }
        if case .status = incoming {
            let serial = log.thinkingSerial
            Task { [weak self] in
                try? await Task.sleep(for: thinkingLimit)
                self?.log.stopThinking(ifSerial: serial)
            }
        }
    }
}

extension CallSession: RoomDelegate {
    /// Chat and Jamie's status rows arrive here, on LiveKit's queue: only
    /// the chat topic is read, and the result is applied on the main actor.
    nonisolated func room(
        _ room: Room, participant: RemoteParticipant?, didReceiveData data: Data, forTopic topic: String,
        encryptionType: EncryptionType
    ) {
        guard topic == CallChatWire.topic, let incoming = CallChatWire.decode(data) else { return }
        Task { @MainActor [weak self] in self?.receiveChat(incoming) }
    }
}
