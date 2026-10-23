import AppKit
import AVFoundation
import Observation
import os
import PeelAgent
import PeelCore
import PeelUI

/// System-wide dictation, milestone 0: the hotkey, the microphone and the
/// HUD, with a stub in place of transcription. Owns the glue between them;
/// the state machine decides, this performs.
@MainActor @Observable
final class DictationController {
    static let shared = DictationController()

    let permissions = DictationPermissions()
    private(set) var settings: DictationSettings

    /// What the user chose; before they do, on once permissions are granted.
    var isEnabled: Bool {
        DictationSettings.isEnabled(stored: stored, permissionsGranted: permissions.requiredGranted)
    }
    /// Right Option for now; choosing another key comes back once its recorder works.
    let hotkey = DictationDefaults.hotkey
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
    /// Speech-to-text on Peel's own strut, and its model.
    let speech = DictationSpeech()
    /// The user's vocabulary: rewrites what dictation mishears, learns from edits.
    let lingo = DictationLingo()
    /// The speech model and the fixer the user picked, on Peel's strut.
    let models = DictationModels()
    /// The field Peel last typed into, watched for the user's corrections.
    @ObservationIgnored private var watch: Task<Void, Never>?
    /// Dictation History keeps each dictation in the open account's database.
    private(set) var historyOn: Bool
    /// The open account's database; nil while it is locked or closed, when
    /// nothing is kept (`AppDelegate` gates it on `AppModel.phase`).
    @ObservationIgnored var history: () -> Storage? = { nil }
    @ObservationIgnored private var tap: DictationHotkeyTap?
    /// What had the keyboard when the key went down: where the text goes.
    @ObservationIgnored private var target: FocusFacts?
    /// The insertion under way: one at a time, so a second one never saves
    /// the first's text as the clipboard to put back.
    @ObservationIgnored private var insertion: Task<Void, Never>?
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var poll: Timer?
    @ObservationIgnored private let log = Logger(subsystem: "dev.peel.mac", category: "dictation")

    private init() {
        // @Observable makes `settings` computed, so read a local copy before init completes.
        let settings = DictationSettings()
        self.settings = settings
        stored = settings.storedEnabled
        offerDismissed = settings.offerDismissed
        historyOn = settings.historyOn
    }

    // MARK: - Lifecycle

    func start() {
        hud.model.accept = { [weak self] in self?.send(.accept) }
        hud.model.cancel = { [weak self] in self?.send(.cancel) }
        speech.onDownloadWait = { [weak self] in
            self?.hud.show(.message("Downloading the speech model (\(StrutSpeech.modelSize)), once"))
        }
        capture.onLevel = { [weak self] level in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.hud.model.push(level) } }
        }
        capture.onProblem = { [weak self] text in
            MainActor.assumeIsolated { self?.abandon(text) }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        refresh()
    }

    /// Re-reads the permissions and starts or stops what depends on them.
    func refresh() {
        permissions.refresh()
        checkSecureInput()
        // A tap made before Accessibility was granted cannot swallow; make it again.
        if isListening && !canSwallow && permissions.accessibility == .granted { stopListening() }
        if isEnabled && permissions.requiredGranted { startListening() } else { stopListening() }
        // The model is fetched while dictation is on, before the first recording needs it.
        if isEnabled { speech.prepare() }
    }

    /// Peel's strut started, stopped or changed (`AppModel.strutChanged`).
    func strutChanged(_ server: MemoryServer?) {
        speech.use(server)
        lingo.use(server)
        models.use(server)
        if isEnabled { speech.prepare() }
    }

    func setEnabled(_ on: Bool) {
        stored = on
        settings.storedEnabled = on
        refresh()
    }

    func setHistoryOn(_ on: Bool) {
        historyOn = on
        settings.historyOn = on
    }

    func dismissOffer() {
        offerDismissed = true
        settings.offerDismissed = true
    }

    private func checkSecureInput() {
        let on = SecureInput.isEnabled
        guard on != secureInput else { return }
        secureInput = on
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
        poll = repeating(every: 2) { $0.checkSecureInput() }
        if DictationDefaults.keepMicWarm {
            do { try capture.start() } catch { log.error("microphone not started: \(String(describing: error))") }
        }
    }

    private func stopListening() {
        guard isListening else { return }
        tap?.stop()
        tap = nil
        isListening = false
        poll?.invalidate()
        poll = nil
        stopTicking()
        machine.reset()
        capture.discardRecording()
        capture.stop()
        hud.hide()
    }

    /// A main-thread timer that also runs while a menu is open or a window is resized.
    private func repeating(every interval: TimeInterval, _ body: @escaping @MainActor (DictationController) -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if let self { body(self) } }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
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
            case .showHUD, .enterLocked:
                // Not after a start that failed: the machine was reset.
                guard !machine.isIdle else { break }
                if let target, target.isSecure {
                    abandon(Self.secureMessage(entry: target.secureInput))
                } else {
                    hud.show(effect == .enterLocked ? .locked : .recording)
                }
            case .submit(let mode):
                stopTicking()
                submit(mode)
            case .discard:
                stopTicking()
                target = nil
                capture.discardRecording()
                hud.hide()
            }
        }
    }

    private func beginCapture() {
        // Delivered after the key went down: dictation may have been turned
        // off, or the press already ended, in between.
        guard isListening, !machine.isIdle else { return }
        // A new dictation: what the user did to the last one is as it is now.
        watch?.cancel()
        let focus = DictationFocus.current(full: false).facts
        target = focus
        // The machine needs the time to know a hold from a tap, and a recording's end.
        ticker?.invalidate()
        ticker = repeating(every: DictationDefaults.tickInterval) { $0.send(.tick) }
        // A password field: not a word is recorded. Said once the hold is
        // past the threshold, so typing an Option character there stays quiet.
        guard !focus.isSecure else { return }
        do {
            try capture.start()
            try capture.beginRecording()
        } catch DictationAudioCapture.Failure.permissionDenied {
            permissions.refresh()
            abandon("Allow the microphone in System Settings")
            return
        } catch {
            abandon("The microphone is not available")
            return
        }
    }

    private static func secureMessage(entry: Bool) -> String {
        entry ? "Another app has secure typing on, so dictation is off" : "Dictation is off in password fields"
    }

    /// Where the text went, when the HUD has something to say about it.
    private static func message(for outcome: DictationTextInserter.Outcome) -> String? {
        switch outcome {
        case .inserted: nil
        case .blocked(let entry): secureMessage(entry: entry)
        case .copied(.focusMoved): "The focus moved, so it's on the clipboard: press ⌘V"
        case .copied(.noAccessibility): "Copied: press ⌘V. Allow Accessibility for Peel to type it."
        case .copied(.noField), .copied(.notPosted): "Copied: press ⌘V"
        }
    }

    /// The microphone failed: whatever was under way ends, and the user is told.
    private func abandon(_ text: String) {
        machine.reset()
        stopTicking()
        target = nil
        capture.discardRecording()
        hud.show(.message(text))
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
    }

    private func submit(_ mode: DictationMode) {
        hud.hide()
        guard let start = target, !start.isSecure else {
            capture.discardRecording()
            return
        }
        target = nil
        guard let recorded = capture.finishRecording() else {
            hud.show(.message("The recording could not be saved"))
            return
        }
        if !DictationDefaults.keepMicWarm { capture.stop() }
        let session = DictationSession(audioURL: recorded.url, duration: recorded.duration, mode: mode)
        // Where and when, as of now: the account and the clock may move on
        // while the strut transcribes.
        let storage = historyOn ? history() : nil
        let entry = HistoryEntry(
            id: session.id, storage: storage, startedAt: Date().addingTimeInterval(-recorded.duration),
            duration: recorded.duration, appID: start.bundleID,
            appName: storage == nil ? nil : NSRunningApplication(processIdentifier: start.pid)?.localizedName
        )
        log.info("dictation \(session.id.uuidString) \(session.mode.rawValue) \(session.duration)s")
        let transcriber = StrutTranscriber(speech: speech)
        let previous = insertion
        insertion = Task {
            defer { try? FileManager.default.removeItem(at: session.audioURL) }
            let transcript: DictationTranscript
            do {
                // Strut has already put the user's vocabulary right ("stack work" → "Stakwork").
                transcript = try await transcriber.transcribe(audioFileURL: session.audioURL)
            } catch {
                let why = (error as? StrutSpeech.Failure).map(String.init(describing:)) ?? "Couldn't transcribe"
                await entry.keep(nil, .failed, note: why)
                hud.show(.message(why))
                return
            }
            let text = transcript.text, rewritten = transcript.heard
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                await entry.keep(nil, .failed, note: "Nothing was heard")
                hud.show(.message("Nothing was heard"))
                return
            }
            await previous?.value
            let outcome = await DictationTextInserter.insert(text, startedIn: start)
            let note = Self.message(for: outcome)
            var copied = false
            let kept: Bool
            switch outcome {
            case .inserted:
                kept = await entry.keep(text, .typed, heard: rewritten)
                // Not Peel's own fields: asking Accessibility would wait on this very thread.
                if start.pid != getpid(), history() != nil { watchForCorrections(of: text) }
            case .copied(let why):
                copied = true
                kept = await entry.keep(text, .copied, note: Self.historyNote(why), heard: rewritten)
            case .blocked(let secureEntry): kept = await entry.keep(nil, .blocked, note: Self.secureMessage(entry: secureEntry))
            }
            // Only a message: by now another dictation may be under way.
            if let note { hud.show(.message(kept && copied ? note + " (also in History)" : note)) }
        }
    }
}

extension DictationController {
    /// Watches the field for what the user does to `typed`, then, once the
    /// edit has settled, has strut learn what it can from it (one call: it
    /// runs a model), with Undo in the HUD.
    fileprivate func watchForCorrections(of typed: String) {
        watch?.cancel()
        watch = DictationEditWatch.watch(typed: typed) { [weak self] edited in
            // Only while unlocked (`history` is the unlocked account's database).
            guard let self, let edited, edited != typed, history() != nil else { return }
            Task { await self.learn(typed: typed, edited: edited) }
        }
    }

    private func learn(typed: String, edited: String) async {
        let learned: [LingoLearned]
        do { learned = try await lingo.correct(typed: typed, edited: edited) } catch {
            log.error("lingo not learned: \(String(describing: error))")
            return
        }
        // Only what strut wrote now: a pair it already had needs no Undo.
        let new = learned.filter { !$0.undo.isEmpty }
        let undo = new.flatMap(\.undo), words = new.map(\.written)
        guard !words.isEmpty else { return }
        // Not over a dictation under way: once it is done (the usual case,
        // as the next dictation is what ends the watch).
        let clock = ContinuousClock()
        let until = clock.now + .seconds(60)
        while !machine.isIdle {
            guard clock.now < until else { return }
            try? await Task.sleep(for: .milliseconds(300))
        }
        await insertion?.value
        hud.model.undo = { [weak self] in
            self?.hud.hide()
            Task { await self?.lingo.undo(undo) }
        }
        hud.show(.learned("Learned " + ListFormatter.localizedString(byJoining: words)))
    }

    /// Why a dictation was copied rather than typed, for its History row.
    fileprivate static func historyNote(_ why: DictationTextInserter.Outcome.Why) -> String {
        switch why {
        case .noField, .notPosted: "no field had focus"
        case .focusMoved: "the focus moved"
        case .noAccessibility: "Accessibility is off"
        }
    }
}

/// One dictation on its way into History: the account's database and the
/// moment the key was let go, taken when the recording ended; nothing kept
/// with History off or the account locked (`storage` nil).
private struct HistoryEntry {
    let id: UUID
    let storage: Storage?
    let startedAt: Date
    let duration: TimeInterval
    let appID: String?
    let appName: String?

    /// Keeps it, never anything from a password field; whether it was kept.
    @discardableResult
    /// `heard`: what dictation heard, when the vocabulary rewrote it into `text`.
    func keep(_ text: String?, _ outcome: DictationRecord.Outcome, note: String? = nil, heard: String? = nil) async -> Bool {
        guard let storage else { return false }
        let record = DictationRecord(
            id: id, startedAt: startedAt, duration: duration, text: text, appID: appID, appName: appName,
            outcome: outcome, note: note, heard: text == nil ? nil : heard
        )
        do {
            try await storage.addDictation(record, keep: DictationDefaults.historyKeep)
            return true
        } catch {
            Logger(subsystem: "dev.peel.mac", category: "dictation").error("dictation history not kept: \(String(describing: error))")
            return false
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

    func reset() {
        lock.withLock { machine = DictationStateMachine() }
    }
}
