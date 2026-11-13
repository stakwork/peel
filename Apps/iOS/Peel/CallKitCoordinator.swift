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
/// LiveKit keeps configuring the audio session itself; CallKit's activation
/// only tells this class's owner (`onAudioActivated`) so it can make sure the
/// session is really active.
@MainActor
final class CallKitCoordinator: NSObject, CXProviderDelegate {
    private let log = Logger(subsystem: "dev.peel.ios", category: "callkit")
    private let provider: CXProvider
    private let controller = CXCallController()
    private let uuid = UUID()
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

    override init() {
        let configuration = CXProviderConfiguration()
        configuration.localizedName = "Peel"
        configuration.supportsVideo = true
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.generic]
        configuration.includesCallsInRecents = false
        provider = CXProvider(configuration: configuration)
        super.init()
        provider.setDelegate(self, queue: .main)
    }

    /// Asks the system to start the call.
    func start(title: String, video: Bool) {
        let action = CXStartCallAction(call: uuid, handle: CXHandle(type: .generic, value: title))
        action.isVideo = video
        action.contactIdentifier = title
        live = true
        controller.request(CXTransaction(action: action)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                guard let self else { return }
                self.log.error("CallKit could not start the call: \(String(describing: error))")
                self.live = false
                Diagnostics.recordCallAudio(.callKitFailed, ok: false)
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

    /// The call is over (left, or the room is lost): the system forgets it.
    func end(failed: Bool = false) {
        guard !ended else { return }
        ended = true
        if live { provider.reportCall(with: uuid, endedAt: nil, reason: failed ? .failed : .remoteEnded) }
        live = false
        provider.invalidate()
        Diagnostics.recordCallAudio(.callKitEnded, ok: !failed)
    }

    // MARK: CXProviderDelegate

    nonisolated func providerDidReset(_ provider: CXProvider) {
        MainActor.assumeIsolated {
            live = false
            onSystemEnd?()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        MainActor.assumeIsolated {
            let update = CXCallUpdate()
            update.remoteHandle = action.handle
            update.localizedCallerName = action.handle.value
            update.hasVideo = action.isVideo
            update.supportsHolding = false
            update.supportsGrouping = false
            update.supportsUngrouping = false
            update.supportsDTMF = false
            provider.reportOutgoingCall(with: uuid, startedConnectingAt: nil)
            provider.reportCall(with: uuid, updated: update)
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        MainActor.assumeIsolated {
            action.fulfill()
            guard !ended else { return }
            ended = true
            live = false
            Diagnostics.recordCallAudio(.callKitEnded, ok: true)
            onSystemEnd?()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        MainActor.assumeIsolated {
            action.fulfill()
            guard action.isMuted != muted else { return }
            muted = action.isMuted
            onMuteRequest?(action.isMuted)
        }
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated { onAudioActivated?() }
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated { log.info("CallKit gave the audio session back") }
    }
}
