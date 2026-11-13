import AVFoundation
import CallKit
import os
import PeelDiagnostics

/// Shows the call to the system as a CallKit call (the green banner, the
/// lock-screen call UI, the system mute and hang-up) and keeps the app alive
/// in the background with it. No PushKit: only outgoing-style calls, started
/// by the person here. CallKit is an addition: if it fails the call goes on
/// without it, and nothing here ever throws into the call.
///
/// One per call; the provider they report through is the app's one
/// (`CallKitProvider`), as Apple asks.
///
/// LiveKit keeps configuring the audio session itself; CallKit's activation
/// only tells this class's owner (`onAudioActivated`) so it can make sure the
/// session is really active.
@MainActor
final class CallKitCoordinator {
    private let log = Logger(subsystem: "dev.peel.ios", category: "callkit")
    private let controller = CXCallController()
    let uuid = UUID()
    /// The call is known to the system (requested and not yet ended).
    private var live = false
    private var ended = false
    /// The mute state as the system last has it, so a change does not echo.
    private var muted = false
    /// The system's call screen ended the call (hang-up there).
    var onSystemEnd: (() -> Void)?
    /// The system's mute button asked for the microphone to be muted or not.
    var onMuteRequest: ((Bool) -> Void)?
    /// CallKit gave the audio session to the call, or took it back.
    var onAudioActivated: (() -> Void)?

    private var provider: CXProvider { CallKitProvider.shared.provider }

    /// Asks the system to start the call.
    func start(title: String, video: Bool) {
        CallKitProvider.shared.call = self
        let action = CXStartCallAction(call: uuid, handle: CXHandle(type: .generic, value: title))
        action.isVideo = video
        live = true
        controller.request(CXTransaction(action: action)) { [weak self] error in
            guard let error else { return }
            let code = (error as NSError).code
            Task { @MainActor in
                guard let self else { return }
                self.log.error("CallKit could not start the call: \(String(describing: error))")
                self.live = false
                Diagnostics.recordCallAudio(.callKitFailed, ok: false, callKitError: code)
            }
        }
    }

    /// The room connected.
    func connected() {
        guard live, !ended else { return }
        provider.reportOutgoingCall(with: uuid, connectedAt: nil)
        Diagnostics.recordCallAudio(.callKitStarted, ok: true)
    }

    /// The microphone changed: tells the system's call screen, once.
    func reportMuted(_ value: Bool) {
        guard live, !ended, value != muted else { return }
        muted = value
        controller.request(CXTransaction(action: CXSetMutedCallAction(call: uuid, muted: value))) { [weak self] error in
            if let error { self?.log.error("CallKit mute report failed: \(String(describing: error))") }
        }
    }

    /// The call is over: hung up here (asked of the system as an end action,
    /// as a hang-up on its screen would be), or the room lost (reported as
    /// failed). The system forgets it either way.
    func end(failed: Bool = false) {
        guard !ended else { return }
        ended = true
        let wasLive = live
        live = false
        if CallKitProvider.shared.call === self { CallKitProvider.shared.call = nil }
        Diagnostics.recordCallAudio(.callKitEnded, ok: !failed)
        guard wasLive else { return }
        let uuid = uuid
        if failed {
            provider.reportCall(with: uuid, endedAt: nil, reason: .failed)
            return
        }
        controller.request(CXTransaction(action: CXEndCallAction(call: uuid))) { [log] error in
            guard let error else { return }
            log.error("CallKit end request failed: \(String(describing: error))")
            // Refused (the system may already have dropped it): still forgotten.
            Task { @MainActor in CallKitProvider.shared.provider.reportCall(with: uuid, endedAt: nil, reason: .remoteEnded) }
        }
    }

    // MARK: From the provider

    /// The system took the start request: the call is connecting.
    func started(title: String, video: Bool) {
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: title)
        update.localizedCallerName = title
        update.hasVideo = video
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false
        provider.reportOutgoingCall(with: uuid, startedConnectingAt: nil)
        provider.reportCall(with: uuid, updated: update)
    }

    /// Hung up on the system's screen.
    func systemEnded() {
        guard !ended else { return }
        ended = true
        live = false
        Diagnostics.recordCallAudio(.callKitEnded, ok: true)
        onSystemEnd?()
    }

    func systemMuted(_ isMuted: Bool) {
        guard isMuted != muted else { return }
        muted = isMuted
        onMuteRequest?(isMuted)
    }

    func audioActivated() {
        onAudioActivated?()
    }

    /// The system dropped every call (`providerDidReset`).
    func reset() {
        live = false
        onSystemEnd?()
    }
}

/// The app's one `CXProvider`, made on first use and kept, handing what the
/// system asks to the call it is about (`call`, matched by its UUID). Our own
/// end request comes back as an end action after `end` let go of the call,
/// so it reaches nobody.
@MainActor
final class CallKitProvider: NSObject, CXProviderDelegate {
    static let shared = CallKitProvider()

    let provider: CXProvider
    /// The call on now; one at a time (`maximumCallsPerCallGroup`).
    weak var call: CallKitCoordinator?
    private let log = Logger(subsystem: "dev.peel.ios", category: "callkit")

    private override init() {
        // The system names the call by the app's display name.
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = true
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.generic]
        configuration.includesCallsInRecents = false
        provider = CXProvider(configuration: configuration)
        super.init()
        provider.setDelegate(self, queue: .main)
    }

    private func call(_ uuid: UUID) -> CallKitCoordinator? {
        call.flatMap { $0.uuid == uuid ? $0 : nil }
    }

    // The delegate queue is main, so these run on the main actor; CallKit's
    // actions are not Sendable, so only plain values cross into it, and each
    // action is fulfilled where it arrived.

    nonisolated func providerDidReset(_ provider: CXProvider) {
        MainActor.assumeIsolated { call?.reset() }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        let uuid = action.callUUID, title = action.handle.value, video = action.isVideo
        MainActor.assumeIsolated { call(uuid)?.started(title: title, video: video) }
        action.fulfill()
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        let uuid = action.callUUID
        action.fulfill()
        MainActor.assumeIsolated { call(uuid)?.systemEnded() }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        let uuid = action.callUUID, isMuted = action.isMuted
        action.fulfill()
        MainActor.assumeIsolated { call(uuid)?.systemMuted(isMuted) }
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated { call?.audioActivated() }
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated { log.info("CallKit gave the audio session back") }
    }
}
