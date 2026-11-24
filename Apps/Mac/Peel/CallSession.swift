import AVFoundation
import Combine
import SwiftUI
import LiveKit
import os
import PeelCore
import PeelUI

/// The call this Mac is on: owns the LiveKit room for one call, its
/// microphone, camera and devices, and what the window and the sidebar show
/// of it. The ticket's token goes to LiveKit and is not kept.
///
/// A link with a key (a box's Jamie is in the call) is joined end-to-end
/// encrypted with it (`CallRoom.options`): media, the call's chat and
/// Jamie's replies. What will not encrypt or decrypt is said
/// (`encryptionNotice`), and nothing is ever sent in the clear.
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
        /// A screen whose sharer paused it: the share is still there, its
        /// picture is not coming.
        var paused = false
        /// Their camera while it is on and arriving, or the screen they share.
        var video: VideoTrack?
        /// Jamie, the call's voice agent (`CallChatWire.isJamie`), not its screen.
        var isJamie = false
        var id: ID { ID(identity: person.identity, isScreen: isScreen) }

        static func == (a: Tile, b: Tile) -> Bool {
            a.person == b.person && a.isYou == b.isYou && a.isScreen == b.isScreen && a.speaking == b.speaking
                && a.muted == b.muted && a.paused == b.paused && a.video === b.video && a.isJamie == b.isJamie
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
    /// Called when a newer device on this account joins the call.
    @ObservationIgnored var movedAway: (() -> Void)?
    @ObservationIgnored private let handoff: CallHandoff?
    /// Whether the person chose to stay on both devices: the announcement
    /// on connecting says so, and an earlier device does not leave.
    @ObservationIgnored private let stay: Bool
    private(set) var state = State.connecting
    /// When the room first connected: the running time counts from here.
    private(set) var connectedAt: Date?
    /// When the first participant joined the room, the earliest seen; the
    /// timer counts from it so everyone's agrees.
    private(set) var callStartedAt: Date?
    /// Everyone on the call, the others in the order they joined, you last.
    private(set) var tiles: [Tile] = []
    private(set) var micOn = false
    /// Whether the call is recorded: by the call server (the room says
    /// so), or on the canvas by a box's Jamie (its `recording` attribute,
    /// `CallChatWire.jamieRecords`). Everyone on it must be told.
    private(set) var isRecording = false
    /// What will not encrypt or decrypt on an encrypted call
    /// (`CallEncryption`), said before anything else; nil while nothing fails.
    private(set) var encryptionNotice: String?
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
    /// The built-in microphone to offer, one click away, when the speaker
    /// moved to the Mac but the microphone stayed on another device.
    private(set) var micSwitchOffer: (name: String, id: String)?
    /// What you share, while you share it (and while it is being published).
    var sharing: ScreenShare.Content? { share?.content }
    /// Whether your running share is paused: its track is muted, the
    /// publication stays, so viewers see "Sharing paused" and nothing is
    /// renegotiated. False whenever nothing is shared.
    private(set) var sharePaused = false
    /// Whether the next share includes Peel's own windows, which are left out
    /// by default. Applies when a share starts, not to one already running.
    var includePeelWindows = false
    /// Whether the running share includes Peel's own windows.
    var sharingIncludesPeel: Bool { share?.includesPeel ?? false }
    /// The tile shown large with the others in a strip beside it; nil for
    /// the grid. A screen someone starts sharing takes it.
    private(set) var focus: Tile.ID?
    /// Who the speaker layout shows large while nothing is focused: the
    /// last one else on the call to speak, or the first to join.
    private(set) var activeSpeaker: Tile.ID?
    /// When the speaker layout last moved, so a cough does not take the stage.
    @ObservationIgnored private var speakerSince = Date.distantPast
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
    /// Jamie says its replies aloud, as its `tts` attribute has it; false
    /// while Jamie is not in the call.
    private(set) var jamieSpeaks = false
    /// Jamie's identity on the call, the one participant the voice toggle
    /// goes to.
    @ObservationIgnored private var jamieIdentity: Participant.Identity?
    /// Jamie is still on the last request, so another may be skipped.
    var jamieBusy: Bool { jamieThinking }
    /// A short-lived hint above the composer.
    private(set) var chatNotice: String?
    private var log = CallChatLog()
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    /// One room per call, encrypted with the link's key when it has one.
    @ObservationIgnored private let room: Room
    @ObservationIgnored private var encryption = CallEncryption()
    /// Hears the room's encryption state; the room holds its delegates weakly.
    @ObservationIgnored private var encryptionWatch: CallEncryptionWatch?
    @ObservationIgnored private var connecting: Task<Void, Never>?
    @ObservationIgnored private var failed = false
    @ObservationIgnored private var leaving = false
    @ObservationIgnored private var switchingMic = false
    /// Whether the microphone is meant to be on, as last asked for; `micOn`
    /// is what the room reports, which drops when a device goes away.
    @ObservationIgnored private var wantsMic = false
    @ObservationIgnored private var switchingCamera = false
    @ObservationIgnored private var switchingShare = false
    private var share: ScreenShare?
    @ObservationIgnored private var sharePublication: LocalTrackPublication?
    /// Every screen track seen on this call, so one that comes back after
    /// a pause or a reconnect does not take the focus again.
    @ObservationIgnored private var seenScreenTracks: Set<String> = []
    @ObservationIgnored private var changes: AnyCancellable?
    @ObservationIgnored private var audioSettleTask: Task<Void, Never>?
    /// The microphone after voice processing, as sent; read by the watchdog.
    @ObservationIgnored private let micMeter = CallMicMeter()
    @ObservationIgnored private var micMeterAdded = false
    @ObservationIgnored private var micWatchdog: Task<Void, Never>?
    @ObservationIgnored private var micRetryTask: Task<Void, Never>?
    /// When the microphone was last restarted. A restart can make a
    /// Bluetooth headset change profile, which fires another device change.
    @ObservationIgnored private var lastMicRestart: ContinuousClock.Instant?
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
    private static let audioSettleDelay: Duration = .milliseconds(1500)
    /// How long the microphone may be silent before it is restarted, and
    /// the level (linear full scale) above which it is not silent.
    private static let micSilenceWindow: Duration = .seconds(3)
    private static let micSilenceLevel = 0.00001
    private static let micRetryLimit = 5
    private static let deviceLog = Logger(subsystem: "dev.peel.mac", category: "call-audio")

    init(ticket: CallTicket, link: CallLink, chat: String, title: String, camera: Bool, stay: Bool) {
        room = Room(roomOptions: CallRoom.options(for: link))
        self.link = link
        self.chat = chat
        self.title = title
        identity = ticket.identity
        participantName = ticket.participantName
        handoff = ticket.handoff
        self.stay = stay
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
        claimAudioDevices()
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
        room.add(delegate: self)
        // Before the room connects, so a key that doesn't match is heard.
        if link.encryptionKey != nil {
            let watch = CallEncryptionWatch { [weak self] change in self?.encryptionChanged(change) }
            room.add(delegate: watch)
            encryptionWatch = watch
        }
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
        case .connecting: return String(localized: "Connecting…")
        case .reconnecting: return String(localized: "Reconnecting…")
        case .lost: return String(localized: "Disconnected")
        case .connected:
            guard let start = callStartedAt ?? connectedAt else { return "" }
            let seconds = Int(max(0, now.timeIntervalSince(start)))
            return Duration.seconds(seconds)
                .formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond(padMinuteToLength: 2)))
        }
    }

    /// One handler for the app: a session left after the next one began
    /// (a switch, a rejoin) must not take it away from that one. Done at
    /// connect as well as at init, so a later session gets it too.
    private func claimAudioDevices() {
        Self.audioDevicesOwner = self
        AudioManager.shared.onDeviceUpdate = { _ in
            Task { @MainActor in CallSession.audioDevicesOwner?.scheduleAudioDevicesChanged() }
        }
    }

    /// Route changes arrive in bursts (AirPods back in), and each was answered
    /// by re-pointing the AudioManager, which rebuilt WebRTC's voice-processing
    /// AVAudioEngine while AVFAudio's AVAudioIOUnit format-change listener
    /// still fires on the old one: a use-after-free inside AVFAudio
    /// (EXC_BAD_ACCESS in IsFormatSampleRateAndChannelCountValid beside
    /// -[AVAudioEngine dealloc]). We cannot fix AVFAudio, so the burst is
    /// settled and handled once. Best-effort.
    private func scheduleAudioDevicesChanged() {
        audioSettleTask?.cancel()
        audioSettleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.audioSettleDelay)
            guard !Task.isCancelled else { return }
            self?.audioDevicesChanged()
        }
    }

    private func connect(url: String, token: String, camera: Bool) async {
        claimAudioDevices()
        if !micMeterAdded {
            micMeterAdded = true
            AudioManager.shared.add(localAudioRenderer: micMeter)
        }
        await listenForHandoff()
        do {
            try await room.connect(url: url, token: token)
        } catch {
            failed = true
            refresh()
            return
        }
        guard !Task.isCancelled else { return }
        // A call meant to be encrypted that the room would not encrypt is
        // left before anything is published.
        if link.encryptionKey != nil, room.e2eeManager == nil {
            encryptionNotice = CallEncryption.unavailable
            failed = true
            await room.disconnect()
            refresh()
            return
        }
        refresh()
        announce(stay: stay)
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
        audioSettleTask?.cancel()
        audioSettleTask = nil
        micWatchdog?.cancel()
        micWatchdog = nil
        micRetryTask?.cancel()
        micRetryTask = nil
        micSwitchOffer = nil
        if micMeterAdded {
            micMeterAdded = false
            AudioManager.shared.remove(localAudioRenderer: micMeter)
        }
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
        let ownsAudio = Self.audioDevicesOwner === self
        if ownsAudio {
            Self.audioDevicesOwner = nil
            AudioManager.shared.onDeviceUpdate = nil
        }
        await room.disconnect()
        // The next call starts on the system's devices, not on an engine
        // still bound to one that has gone since.
        if ownsAudio {
            let audio = AudioManager.shared
            audio.inputDevice = audio.defaultInputDevice
            audio.outputDevice = audio.defaultOutputDevice
            Self.pickedMicrophone = nil
            Self.pickedSpeaker = nil
            Self.deviceLog.info("left the call; audio devices reset to the system default")
        }
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
            wantsMic = on
        } catch {
            if on { deviceNotice = String(localized: "Could not turn the microphone on") }
        }
        refresh()
    }

    /// Opens the microphone track afresh, on whatever device the engine now
    /// uses; a track left from before a device change stays silent. The
    /// track is unpublished (which stops it) and a new one published, as
    /// muting and unmuting would keep the same capture running. Asked while
    /// another switch is running, it tries again shortly.
    private func reacquireMicrophone(attempt: Int = 0) async {
        guard wantsMic, !leaving else { return }
        guard !switchingMic else {
            guard attempt < Self.micRetryLimit else {
                Self.deviceLog.error("microphone restart skipped: still switching after \(attempt) retries")
                return
            }
            micRetryTask?.cancel()
            micRetryTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                await self?.reacquireMicrophone(attempt: attempt + 1)
            }
            return
        }
        switchingMic = true
        defer { switchingMic = false }
        let local = room.localParticipant
        do {
            if let publication = local.audioTracks.first(where: { $0.source == .microphone }) as? LocalTrackPublication {
                try await local.unpublish(publication: publication)
            }
            guard !leaving else { return }
            try await local.setMicrophone(enabled: true)
            Self.deviceLog.info("microphone re-acquired")
        } catch {
            Self.deviceLog.error("microphone restart failed: \(String(describing: error))")
            deviceNotice = String(localized: "Could not turn the microphone on")
        }
        lastMicRestart = .now
        refresh()
    }

    /// After a device change: if the microphone is on yet delivers nothing
    /// for a few seconds, it is restarted once; if it is still silent, the
    /// line under the bar says so. One watchdog at a time.
    private func startMicWatchdog() {
        micWatchdog?.cancel()
        micWatchdog = Task { @MainActor [weak self] in
            for restart in [true, false] {
                guard let self else { return }
                _ = micMeter.take()
                try? await Task.sleep(for: Self.micSilenceWindow)
                guard !Task.isCancelled, wantsMic, micOn, !leaving else { return }
                if micMeter.take() > Self.micSilenceLevel { return }
                if restart {
                    Self.deviceLog.info("microphone silent; restarting it")
                    await reacquireMicrophone()
                } else {
                    Self.deviceLog.info("microphone still silent after a restart")
                    deviceNotice = String(localized: "Your microphone isn't picking anything up. Choose another in the device menu.")
                }
            }
        }
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
            if on { deviceNotice = String(localized: "Could not turn the camera on") }
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

    /// Mutes the share's track, keeping it published. No-op unless sharing.
    func pauseScreenShare() {
        Task { await setSharePaused(true) }
    }

    func resumeScreenShare() {
        Task { await setSharePaused(false) }
    }

    func toggleScreenSharePause() {
        if sharePaused { resumeScreenShare() } else { pauseScreenShare() }
    }

    private func setSharePaused(_ paused: Bool) async {
        guard let started = share, let publication = sharePublication, !leaving, paused != sharePaused else { return }
        do {
            if paused { try await publication.mute() } else { try await publication.unmute() }
        } catch {
            deviceNotice = paused ? String(localized: "Could not pause sharing") : String(localized: "Could not resume sharing")
            return
        }
        // The share may have stopped or been replaced meanwhile.
        guard share === started, sharePublication === publication else { return }
        sharePaused = paused
        refresh()
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
            deviceNotice = String(localized: "Could not start sharing")
            return
        }
        // Stop shows at once: the screen is being captured from here.
        share = started
        sharePaused = false
        if leaving || started.ended { return await stopSharing() }
        do {
            let publication = try await room.localParticipant.publish(videoTrack: started.track, options: ScreenShare.publishOptions)
            // Stopped while it was being published.
            guard share === started else {
                try? await room.localParticipant.unpublish(publication: publication)
                return
            }
            sharePublication = publication
        } catch {
            await stopSharing()
            deviceNotice = String(localized: "Could not start sharing")
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
        sharePaused = false
        await share.stop()
        if let publication = sharePublication {
            sharePublication = nil
            try? await publication.unmute()
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
        micSwitchOffer = nil
        refreshAudioDevices()
    }

    /// The offer under the bar: the Mac's own microphone, picked, and the
    /// microphone track restarted on it.
    func switchToBuiltInMicrophone() {
        let audio = AudioManager.shared
        let device = Self.builtInMicrophone(in: audio.inputDevices) ?? audio.defaultInputDevice
        chooseMicrophone(device.deviceId)
        Task {
            await reacquireMicrophone()
            startMicWatchdog()
        }
    }

    /// The Mac's own microphone: listed by itself, not Bluetooth.
    private static func builtInMicrophone(in list: [AudioDevice]) -> AudioDevice? {
        list.first { device in
            let name = device.name.lowercased()
            return !device.isDefault
                && !name.contains("airpods") && !name.contains("bluetooth") && !name.contains("headset")
                && (name.contains("macbook") || name.contains("built-in") || name.contains("microphone"))
        }
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
        Device(id: device.deviceId, name: device.isDefault ? String(localized: "System default (\(device.name))") : device.name)
    }

    /// The one picked while it is listed, else the system's default.
    private static func inUse(_ picked: String?, in list: [AudioDevice]) -> String? {
        list.contains { $0.deviceId == picked } ? picked : list.first { $0.isDefault }?.deviceId
    }

    /// A microphone or speaker came or went: one picked that went is
    /// replaced by the system's default, and the line under the bar says so.
    /// One that came (AirPods back in) moves the call to the system's
    /// default, which macOS points at it, and the engine is pointed afresh
    /// so the microphone and the playout do not stay bound to a stale device.
    private func audioDevicesChanged() {
        audioSettleTask = nil
        guard !leaving else { return }
        micSwitchOffer = nil
        micWatchdog?.cancel()
        micWatchdog = nil
        let audio = AudioManager.shared
        let goneMic = audio.inputDevices.contains { $0.deviceId == microphone } ? nil : microphones.first { $0.id == microphone }
        let goneSpeaker = audio.outputDevices.contains { $0.deviceId == speaker } ? nil : speakers.first { $0.id == speaker }
        let knownMics = Set(microphones.map(\.id)), knownSpeakers = Set(speakers.map(\.id))
        let addedMics = audio.inputDevices.filter { !knownMics.contains($0.deviceId) }
        let addedSpeakers = audio.outputDevices.filter { !knownSpeakers.contains($0.deviceId) }
        // The default entry keeps its id and changes the name of what it
        // stands for.
        let oldMicDefault = microphones.first { $0.name.hasPrefix("System default") }?.name
        let oldSpeakerDefault = speakers.first { $0.name.hasPrefix("System default") }?.name
        let newMicDefault = audio.inputDevices.first { $0.isDefault }.map { Self.device($0).name }
        let newSpeakerDefault = audio.outputDevices.first { $0.isDefault }.map { Self.device($0).name }
        if goneMic != nil { Self.pickedMicrophone = nil }
        if goneSpeaker != nil { Self.pickedSpeaker = nil }
        let moveMic = goneMic != nil || !addedMics.isEmpty || (Self.pickedMicrophone == nil && oldMicDefault != newMicDefault)
        let moveSpeaker = goneSpeaker != nil || !addedSpeakers.isEmpty || (Self.pickedSpeaker == nil && oldSpeakerDefault != newSpeakerDefault)
        // Added devices take the call over the picked one: the system made
        // them its default.
        if !addedMics.isEmpty { Self.pickedMicrophone = nil }
        if !addedSpeakers.isEmpty { Self.pickedSpeaker = nil }
        if moveMic { audio.inputDevice = audio.defaultInputDevice }
        if moveSpeaker { audio.outputDevice = audio.defaultOutputDevice }
        if let gone = goneMic ?? goneSpeaker {
            deviceNotice = goneMic != nil
                ? String(localized: "\(gone.name) was disconnected; using the default microphone")
                : String(localized: "\(gone.name) was disconnected; using the default speaker")
        }
        refreshAudioDevices()
        let names = { (list: [AudioDevice]) in list.map(\.name).joined(separator: ", ") }
        Self.deviceLog.info("""
            audio devices changed: added [\(names(addedMics + addedSpeakers))], \
            removed [\([goneMic?.name, goneSpeaker?.name].compactMap { $0 }.joined(separator: ", "))], \
            microphone \(moveMic ? (audio.defaultInputDevice.name) : "kept"), \
            speaker \(moveSpeaker ? (audio.defaultOutputDevice.name) : "kept")
            """)
        // The speaker moved (to the Mac) but the microphone stayed on
        // another device, say AirPods taken out: offer the built-in one.
        if moveSpeaker, !moveMic, let builtIn = Self.builtInMicrophone(in: audio.inputDevices) {
            let inUse = audio.inputDevices.first { $0.deviceId == microphone }
            let inUseName = inUse.map { $0.isDefault ? audio.defaultInputDevice.name : $0.name }
            if let inUseName, inUseName != builtIn.name {
                micSwitchOffer = (name: builtIn.name, id: builtIn.deviceId)
                deviceNotice = String(localized: "Output moved to \(audio.defaultOutputDevice.name), but your microphone is still \(inUseName).")
            }
        }
        // The track bound to the old device is replaced when the devices it
        // may be bound to moved, or the mic is off. Not right after a restart:
        // that can itself flip a headset's profile and notify again.
        if wantsMic, moveMic || moveSpeaker || !micOn {
            if micOn, let last = lastMicRestart, last.duration(to: .now) < .seconds(5) {
                Self.deviceLog.info("microphone restart skipped: restarted less than 5 seconds ago")
                return
            }
            // The engine restart from the device changes should finish before
            // the track is reopened.
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                await reacquireMicrophone()
                startMicWatchdog()
            }
        }
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
            let cameraName = cameras.first { $0.id == id }?.name ?? String(localized: "The camera")
            deviceNotice = String(localized: "\(cameraName) was disconnected")
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
            let everyone = next.filter { !$0.isScreen && !$0.isJamie }.map(\.person)
            if everyone != people { people = everyone }
            refocus()
        }
        // On every refresh, not only when the tiles change: someone who
        // started speaking during the hold still takes the stage once it ends
        // although nothing about the tiles changed since.
        followSpeaker()
        let mic = local.isMicrophoneEnabled(), cam = local.isCameraEnabled()
        if mic != micOn { micOn = mic }
        if cam != cameraOn { cameraOn = cam }
        let jamie = others.first(where: Self.isJamie)
        let recording = room.isRecording || jamie.map { CallChatWire.jamieRecords($0.attributes) } == true
        if recording != isRecording { isRecording = recording }
        jamieIdentity = jamie?.identity
        if (jamie != nil) != jamieInCall {
            jamieInCall = jamie != nil
            // Jamie left: nothing is coming.
            if jamie == nil { log.stopThinking() }
        }
        let speaks = jamie.map { CallChatWire.jamieSpeaks($0.attributes) } ?? false
        if speaks != jamieSpeaks { jamieSpeaks = speaks }

        let now: State
        switch room.connectionState {
        case .connected:
            now = .connected
            if connectedAt == nil { connectedAt = .now }
            let started = CallStart.earliest(
                callStartedAt,
                [room.localParticipant.joinedAt] + room.remoteParticipants.values.map(\.joinedAt))
            if started != callStartedAt { callStartedAt = started }
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

    /// The speaker layout follows whoever else speaks: it stays on them
    /// while they speak and through a pause, moves to someone else only
    /// after `speakerHold`, and moves on at once when they leave.
    private func followSpeaker() {
        let other = { (tile: Tile) in !tile.isScreen && !tile.isYou }
        // Only someone else holds the stage: you are shown large only while
        // no one else is on the call.
        let current = tiles.first { $0.id == activeSpeaker && other($0) }
        if let current, current.speaking || Date.now.timeIntervalSince(speakerSince) < Self.speakerHold { return }
        let next = tiles.first { other($0) && $0.speaking }?.id ?? current?.id ?? tiles.first(where: other)?.id ?? tiles.first?.id
        if next != activeSpeaker {
            activeSpeaker = next
            speakerSince = .now
        }
    }

    /// The least time the speaker layout stays on one person.
    private static let speakerHold: TimeInterval = 2

    /// Their tile, or the tile of the screen they share (nil when they share none).
    private func tile(_ participant: Participant, isYou: Bool, screen: Bool) -> Tile? {
        let video = Self.video(of: participant, screen: screen)
        let paused = screen && video == nil && Self.screenPaused(participant)
        guard !screen || video != nil || paused, let id = isYou ? identity : participant.identity?.stringValue,
              let person = person(id, name: participant.name, metadata: participant.metadata)
        else { return nil }
        // Jamie keeps its track published with its voice off: muted is what it says.
        let jamie = !isYou && Self.isJamie(participant)
        let quiet = jamie
            ? !CallChatWire.jamieSpeaks(participant.attributes) : !participant.isMicrophoneEnabled()
        return Tile(
            person: person, isYou: isYou, isScreen: screen, speaking: !screen && participant.isSpeaking,
            muted: !screen && quiet, paused: paused, video: video, isJamie: !screen && jamie
        )
    }

    /// The screen they share, or their camera: the first video that is not
    /// a screen share, since some clients publish it with no source.
    private static func video(of participant: Participant, screen: Bool) -> VideoTrack? {
        participant.videoTracks
            .first { ($0.source == .screenShareVideo) == screen && !$0.isMuted && $0.isSubscribed }
            .flatMap { $0.track as? VideoTrack }
    }

    /// Whether they publish a screen share whose track is muted (paused).
    private static func screenPaused(_ participant: Participant) -> Bool {
        participant.videoTracks.contains { $0.source == .screenShareVideo && $0.isMuted }
    }

    private func person(_ id: String, name: String?, metadata: String?) -> CallParticipant? {
        if let read = readPeople[id], read.name == name, read.metadata == metadata { return read.person }
        let person = CallParticipant(identity: id, name: name, metadata: metadata)
        readPeople[id] = (name, metadata, person)
        return person
    }
}

// MARK: - Encryption

extension CallSession {
    fileprivate func encryptionChanged(_ change: CallEncryptionWatch.Change) {
        guard !leaving else { return }
        switch change {
        case let .track(id, local, failed):
            encryption.track(id, whose: local ? .yours : .theirs(room.publisherName(ofTrack: id)), failed: failed)
        case .data:
            encryption.dataFailedToDecrypt()
        }
        if encryption.notice != encryptionNotice { encryptionNotice = encryption.notice }
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
            showChatNotice(String(localized: "Jamie is still working on your last request; this one may be skipped."))
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

    /// Jamie, the call's voice agent (`CallChatWire.isJamie`).
    nonisolated static func isJamie(_ participant: Participant) -> Bool {
        CallChatWire.isJamie(name: participant.name, attributes: participant.attributes)
    }

    /// Asks Jamie to say its replies aloud, or to stop, for everyone on the
    /// call. `jamieSpeaks` changes when Jamie answers, not here.
    func setJamieSpeaks(_ on: Bool) {
        guard let jamie = jamieIdentity, !leaving else { return }
        Task {
            do {
                try await room.localParticipant.publish(
                    data: CallChatWire.voice(on: on),
                    options: DataPublishOptions(destinationIdentities: [jamie], topic: CallChatWire.topic, reliable: true)
                )
            } catch {
                deviceNotice = String(localized: "Could not reach Jamie")
            }
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

// MARK: - Handoff

extension CallSession {
    /// Tells this account's other devices on the call that this one has
    /// joined, so they leave it (`CallHandoff`).
    fileprivate func announce(stay: Bool = false) {
        guard let handoff else { return }
        Task { await handoff.announce(on: room, roomName: link.room, identity: identity, stay: stay) { [weak self] in self?.leaving ?? true } }
    }

    /// Leaves when a newer device on this account joins: set up before the
    /// room connects, so no announcement is missed.
    fileprivate func listenForHandoff() async {
        await handoff?.listen(on: room, roomName: link.room, me: identity) { [weak self] in
            guard let self, !self.leaving else { return }
            self.movedAway?()
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
        guard topic == CallChatWire.topic,
              let incoming = CallChatWire.decode(data, fromJamie: participant.map(Self.isJamie) ?? false) else { return }
        Task { @MainActor [weak self] in self?.receiveChat(incoming) }
    }
}

/// The loudest level of the microphone since the last read: written by the
/// audio engine (an `AudioRenderer`, about every 10 ms), read by the
/// call's silence watchdog.
final class CallMicMeter: NSObject, AudioRenderer, Sendable {
    private let loudest = OSAllocatedUnfairLock<Double>(initialState: 0)

    func render(pcmBuffer: AVAudioPCMBuffer) {
        let level = Self.peak(pcmBuffer)
        loudest.withLock { $0 = max($0, level) }
    }

    /// The loudest since the last read, and it starts again.
    func take() -> Double {
        loudest.withLock { value in
            defer { value = 0 }
            return value
        }
    }

    /// The first channel's peak, in linear full scale.
    private static func peak(_ buffer: AVAudioPCMBuffer) -> Double {
        let frames = Int(buffer.frameLength), stride = buffer.stride
        guard frames > 0 else { return 0 }
        var peak: Float = 0
        if let data = buffer.floatChannelData {
            for frame in 0 ..< frames { peak = max(peak, abs(data[0][frame * stride])) }
            return Double(peak)
        }
        if let data = buffer.int16ChannelData {
            for frame in 0 ..< frames { peak = max(peak, abs(Float(data[0][frame * stride]) / 32768)) }
            return Double(peak)
        }
        return 0
    }
}
