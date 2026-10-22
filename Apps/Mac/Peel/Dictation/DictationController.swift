import AppKit
import AVFoundation
import Observation
import os
import PeelUI

/// System-wide dictation, milestone 0: the hotkey, the microphone and the
/// HUD, with a stub in place of transcription. Owns the glue between them;
/// the state machine decides, this performs.
@MainActor @Observable
final class DictationController {
    static let shared = DictationController()

    let permissions = DictationPermissions()
    private(set) var settings = DictationSettings()

    /// What the user chose; before they do, on once permissions are granted.
    var isEnabled: Bool {
        DictationSettings.isEnabled(stored: stored, permissionsGranted: permissions.requiredGranted)
    }
    /// The hotkey, kept in step with the settings.
    private(set) var hotkey: HotkeyConfig
    /// The last thing worth showing in the menu and Settings.
    private(set) var lastResult: String?
    private(set) var secureInput = false
    /// The tap is running.
    private(set) var isListening = false
    /// The tap cannot swallow keys (Accessibility is off): the locking Space types a space.
    private(set) var canSwallow = true
    private var stored: Bool?
    private var offerDismissed: Bool

    /// The first-use offer: until permissions are in or it is turned down.
    var showsOffer: Bool { !offerDismissed && !permissions.requiredGranted }

    @ObservationIgnored private let machine = MachineBox()
    @ObservationIgnored private let capture = DictationAudioCapture()
    @ObservationIgnored private let hud = DictationHUDPanel()
    @ObservationIgnored private let transcriber: any Transcriber = StubTranscriber()
    @ObservationIgnored private var tap: DictationHotkeyTap?
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var poll: Timer?
    @ObservationIgnored private let log = Logger(subsystem: "chat.sphinx.peel", category: "dictation")

    private init() {
        hotkey = settings.hotkey
        stored = settings.storedEnabled
        offerDismissed = settings.offerDismissed
    }

    // MARK: - Lifecycle

    func start() {
        hud.model.accept = { [weak self] in self?.send(.accept) }
        hud.model.cancel = { [weak self] in self?.send(.cancel) }
        capture.onLevel = { [weak self] level in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.hud.model.level = level } }
        }
        capture.onProblem = { [weak self] text in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.hud.show(.message(text)) } }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        poll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSecureInput() }
        }
        refresh()
    }

    /// Re-reads the permissions and starts or stops what depends on them.
    func refresh() {
        permissions.refresh()
        checkSecureInput()
        if isEnabled && permissions.requiredGranted { startListening() } else { stopListening() }
    }

    func setEnabled(_ on: Bool) {
        stored = on
        settings.storedEnabled = on
        refresh()
    }

    func dismissOffer() {
        offerDismissed = true
        settings.offerDismissed = true
    }

    func setHotkey(_ new: HotkeyConfig) {
        guard !new.isReserved else { return }
        hotkey = new
        settings.hotkey = new
        tap?.setHotkey(new)
    }

    private func checkSecureInput() {
        let on = SecureInput.isEnabled
        if on != secureInput { secureInput = on }
        hud.model.note = on ? "Another app is blocking keyboard shortcuts" : nil
    }

    private func startListening() {
        guard !isListening else { return }
        // Not before Input Monitoring is granted: the tap would be refused.
        guard CGPreflightListenEventAccess() else { return }
        let machine = self.machine
        let tap = DictationHotkeyTap(
            hotkey: hotkey,
            isActive: { !machine.isIdle },
            handler: { [weak self] input in
                let output = machine.handle(input)
                if !output.effects.isEmpty {
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.perform(output.effects) } }
                }
                return output.swallow
            }
        )
        tap.start()
        guard tap.isRunning else { return }
        self.tap = tap
        canSwallow = tap.swallows
        isListening = true
        if DictationDefaults.keepMicWarm { warmUp() }
    }

    private func stopListening() {
        guard isListening else { return }
        tap?.stop()
        tap = nil
        isListening = false
        ticker?.invalidate()
        ticker = nil
        machine.reset()
        capture.discardRecording()
        capture.stop()
        hud.hide()
    }

    private func warmUp() {
        do { try capture.start() } catch { log.error("microphone not started: \(String(describing: error))") }
    }

    // MARK: - Effects

    private func send(_ input: DictationStateMachine.Input) {
        let output = machine.handle(input)
        perform(output.effects)
    }

    private func perform(_ effects: [DictationStateMachine.Effect]) {
        for effect in effects {
            switch effect {
            case .beginCapture:
                beginCapture()
            case .showHUD:
                // Not after a start that failed: the machine was reset.
                if !machine.isIdle { hud.show(.recording) }
            case .enterLocked:
                if !machine.isIdle { hud.show(.locked) }
            case .submit(let mode):
                stopTicking()
                submit(mode)
            case .discard:
                stopTicking()
                capture.discardRecording()
                hud.hide()
            }
        }
    }

    private func beginCapture() {
        do {
            try capture.start()
            try capture.beginRecording()
        } catch DictationAudioCapture.Failure.permissionDenied {
            _ = machine.reset()
            permissions.refresh()
            hud.show(.message("Allow the microphone in System Settings"))
            return
        } catch {
            _ = machine.reset()
            hud.show(.message("The microphone is not available"))
            return
        }
        // The machine needs the time to know a hold from a tap, and a recording's end.
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: DictationDefaults.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.send(.tick) }
        }
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
    }

    private func submit(_ mode: DictationMode) {
        hud.hide()
        let warm = DictationDefaults.keepMicWarm
        guard let recorded = capture.finishRecording() else { return }
        if !warm { capture.stop() }
        let session = DictationSession(audioURL: recorded.url, duration: recorded.duration, mode: mode)
        log.info("dictation \(session.id.uuidString) \(session.mode.rawValue) \(session.duration)s")
        let transcriber = self.transcriber
        Task {
            defer { try? FileManager.default.removeItem(at: session.audioURL) }
            do {
                let text = try await transcriber.transcribe(audioFileURL: session.audioURL)
                log.info("dictation result: \(text)")
                lastResult = text
                hud.show(.message(text))
            } catch {
                hud.show(.message("Could not transcribe"))
            }
        }
    }
}

/// The state machine behind a lock: the tap's thread decides on it, the
/// main thread ticks it and the HUD's buttons feed it.
final class MachineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var machine = DictationStateMachine()

    var isIdle: Bool { lock.withLock { machine.isIdle } }

    func handle(_ input: DictationStateMachine.Input) -> DictationStateMachine.Output {
        lock.withLock { machine.handle(input, at: ProcessInfo.processInfo.systemUptime) }
    }

    @discardableResult
    func reset() -> Bool {
        lock.withLock { machine = DictationStateMachine() }
        return true
    }
}
