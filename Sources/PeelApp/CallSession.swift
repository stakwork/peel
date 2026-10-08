import AVFoundation
import Combine
import SwiftUI
import LiveKit
import PeelCore

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
    private(set) var state = State.connecting
    /// When the room first connected: the running time counts from here.
    private(set) var connectedAt: Date?
    /// Everyone on the call, the others in the order they joined, you last.
    private(set) var tiles: [Tile] = []
    private(set) var micOn = false
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
    /// The tile shown large with the others in a strip beside it; nil for
    /// the grid. A screen someone starts sharing takes it.
    private(set) var focus: Tile.ID?
    /// The call window floats above other apps' windows, for this call.
    var keepOnTop = false

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
    /// The session audio device changes go to: the newest.
    private static weak var audioDevicesOwner: CallSession?

    init(ticket: CallTicket, link: CallLink, chat: String, title: String, camera: Bool) {
        self.link = link
        self.chat = chat
        self.title = title
        identity = ticket.identity
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
        if AVCaptureDevice.authorizationStatus(for: media) == .notDetermined {
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

    /// Opens macOS's picker.
    func startScreenShare() {
        Task { await startSharing() }
    }

    func stopScreenShare() {
        Task { await stopSharing() }
    }

    private func startSharing() async {
        guard !switchingShare, !leaving, share == nil, state == .connected else { return }
        switchingShare = true
        defer { switchingShare = false }
        // Nothing is shared unless the picker returned something and the
        // call is still on when it did.
        guard let filter = await ScreenShare.pick(), !leaving, state == .connected else { return }
        let started: ScreenShare
        do {
            started = try await ScreenShare.start(filter) { [weak self] in self?.shareEnded() }
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
        deviceNotice = nil
        refreshAudioDevices()
    }

    func chooseSpeaker(_ id: String) {
        guard let device = AudioManager.shared.outputDevices.first(where: { $0.deviceId == id }) else { return }
        AudioManager.shared.outputDevice = device
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
        microphones = audio.inputDevices.map { Device(id: $0.deviceId, name: $0.name) }
        speakers = audio.outputDevices.map { Device(id: $0.deviceId, name: $0.name) }
        microphone = audio.inputDevice.deviceId
        speaker = audio.outputDevice.deviceId
    }

    /// A microphone or speaker came or went: one in use that went is
    /// replaced by the system's default, and the line under the bar says so.
    private func audioDevicesChanged() {
        guard !leaving else { return }
        let audio = AudioManager.shared
        let goneMic = audio.inputDevices.contains { $0.deviceId == microphone } ? nil : microphones.first { $0.id == microphone }
        let goneSpeaker = audio.outputDevices.contains { $0.deviceId == speaker } ? nil : speakers.first { $0.id == speaker }
        if goneMic != nil { audio.inputDevice = audio.defaultInputDevice }
        if goneSpeaker != nil { audio.outputDevice = audio.defaultOutputDevice }
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
