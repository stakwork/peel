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
    /// The key held to dictate, kept in step with the settings.
    private(set) var hotkey: HotkeyConfig
    /// Settings is waiting for a key press to make the key (`chooseKey`).
    private(set) var choosingKey = false
    /// The key last pressed while choosing could not be the key, and why.
    private(set) var keyProblem: String?
    /// System Settings › Keyboard › Press 🌐 key, read on each `refresh`.
    private var fnKeyUsage: Int?
    private(set) var secureInput = false
    /// The tap is running.
    private(set) var isListening = false
    /// The tap cannot swallow keys (Accessibility is off): the locking Space types a space.
    private(set) var canSwallow = true
    /// The tap was refused although Input Monitoring reads as granted: only a relaunch fixes it.
    private(set) var needsRestart = false
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
    /// What strut learned from the last edit, for the HUD once no dictation
    /// is under way (`showLearned`).
    @ObservationIgnored private var learned: Learned?
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
    /// Insertions started and not yet done.
    @ObservationIgnored private var inserting = 0
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var poll: Timer?
    /// Re-reads the permissions while dictation waits on them, so granting needs no relaunch.
    @ObservationIgnored private var permissionWatch: Timer?
    @ObservationIgnored private var requesting: Task<Void, Never>?
    @ObservationIgnored private var askedRestart = false
    @ObservationIgnored private var choosingTimeout: Timer?
    /// Which choosing an outcome belongs to: one from an earlier round is dropped.
    @ObservationIgnored private var choosingRound = 0
    @ObservationIgnored private let log = Logger(subsystem: "dev.peel.mac", category: "dictation")

    private init() {
        // @Observable makes `settings` computed, so read a local copy before init completes.
        let settings = DictationSettings()
        self.settings = settings
        hotkey = settings.hotkey
        stored = settings.storedEnabled
        offerDismissed = settings.offerDismissed
        historyOn = settings.historyOn
    }

    // MARK: - Lifecycle

    func start() {
        lingo.isUnlocked = { [weak self] in self?.history() != nil }
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
        fnKeyUsage = UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int
        checkSecureInput()
        // A tap made before Accessibility was granted cannot swallow; make it again.
        if isListening && !canSwallow && permissions.accessibility == .granted { stopListening() }
        if isEnabled && permissions.requiredGranted { startListening() } else { stopListening() }
        // The model is fetched while dictation is on, before the first recording needs it.
        if isEnabled { speech.prepare() }
        updatePermissionWatch()
    }

    /// Polls while dictation is on and waiting for permissions; stops once they are in or it is off.
    private func updatePermissionWatch() {
        guard isEnabled && !(permissions.requiredGranted && permissions.accessibility == .granted) else {
            permissionWatch?.invalidate()
            permissionWatch = nil
            return
        }
        guard permissionWatch == nil else { return }
        permissionWatch = repeating(every: 1.5) { me in
            me.permissions.refresh()
            // Granted: the full refresh starts the tap, fresh (or remakes one that
            // cannot swallow once Accessibility is in). Not yet: keep waiting.
            let tapNeeded = me.permissions.requiredGranted && !me.isListening
            if tapNeeded || me.permissions.accessibility == .granted || !me.isEnabled { me.refresh() }
        }
    }

    /// Asks for the microphone; the other permissions have their own Allow buttons.
    private func requestPermissions() {
        guard requesting == nil else { return }
        requesting = Task {
            await permissions.requestAll()
            requesting = nil
            refresh()
        }
    }

    /// Only a relaunch lets the tap in: said once, with Restart.
    private func offerRestart() {
        guard !askedRestart else { return }
        askedRestart = true
        Task {
            let alert = NSAlert()
            alert.messageText = "Restart Peel to enable Dictation"
            alert.informativeText = "macOS only lets Peel see the dictation key after it restarts."
            alert.addButton(withTitle: "Restart")
            alert.addButton(withTitle: "Later")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let relaunch = Process()
            relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
            // After Peel has quit, so `-n` opens a new instance rather than none.
            relaunch.arguments = ["-c", "sleep 1; /usr/bin/open -n \"$0\"", Bundle.main.bundlePath]
            try? relaunch.run()
            NSApp.terminate(nil)
        }
    }

    /// Peel's strut started, stopped or changed (`AppModel.strutChanged`).
    func strutChanged(_ server: MemoryServer?) {
        // An edit of text typed with the last strut is not this one's to learn.
        watch?.cancel()
        watch = nil
        learned = nil
        speech.use(server)
        lingo.use(server)
        models.use(server)
        if isEnabled { speech.prepare() }
    }

    /// The account unlocked, or locked or closed (`AppModel.phase`): nothing
    /// of its vocabulary is watched, learned or kept in memory while locked.
    func accountChanged(unlocked: Bool) {
        if unlocked {
            Task { await lingo.refresh() }
        } else {
            watch?.cancel()
            watch = nil
            learned = nil
            lingo.lock()
        }
    }

    func setEnabled(_ on: Bool) {
        stored = on
        settings.storedEnabled = on
        refresh()
        if on && !permissions.requiredGranted { requestPermissions() }
    }

    func setHistoryOn(_ on: Bool) {
        historyOn = on
        settings.historyOn = on
    }

    func dismissOffer() {
        offerDismissed = true
        settings.offerDismissed = true
    }

    /// What else on the Mac the key does, when that is known.
    var keyConflict: String? { hotkey.conflict(fnKeyUsage: fnKeyUsage) }

    /// The next key pressed anywhere becomes the key, through the tap, which
    /// sees modifiers on their own and every app's keys; Escape, or a timeout, stops.
    /// Not while a dictation is under way: its key's release would go to the
    /// recorder and never end it.
    func chooseKey() {
        guard let tap, !choosingKey, machine.isIdle else { return }
        choosingKey = true
        keyProblem = nil
        choosingRound += 1
        let round = choosingRound
        log.info("choosing a key (tap swallows: \(tap.swallows))")
        tap.record { [weak self] outcome in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.recorded(outcome, round: round) } }
        }
        // In the common modes, so an open menu doesn't keep every key swallowed.
        let timeout = Timer(timeInterval: DictationDefaults.choosingKeyTimeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopChoosingKey() }
        }
        RunLoop.main.add(timeout, forMode: .common)
        choosingTimeout = timeout
    }

    func stopChoosingKey() {
        guard choosingKey else { return }
        tap?.record(nil)
        choosingKey = false
        choosingTimeout?.invalidate()
        choosingTimeout = nil
    }

    /// A choice stands even if the round was stopped meanwhile (the timeout,
    /// leaving Settings): the tap had already swallowed the key.
    private func recorded(_ outcome: HotkeyRecording.Outcome, round: Int) {
        guard round == choosingRound else { return }
        switch outcome {
        case .pass, .swallow: break
        case .cancel:
            log.info("choosing a key: cancelled")
            stopChoosingKey()
        case .refused(let reason):
            guard choosingKey else { return }
            // Not which key: someone typing elsewhere meanwhile would be logged.
            log.info("choosing a key: refused one")
            keyProblem = reason
        case .chosen(let key):
            log.info("choosing a key: \(key.label, privacy: .public)")
            stopChoosingKey()
            setHotkey(key)
        }
    }

    func setHotkey(_ new: HotkeyConfig) {
        guard new.canBeHotkey else { return }
        keyProblem = nil
        hotkey = new
        settings.hotkey = new
        tap?.setHotkey(new)
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
        guard tap.isRunning else {
            // Granted, yet refused: tried again on each refresh, and a relaunch is the way out.
            needsRestart = true
            offerRestart()
            return
        }
        needsRestart = false
        self.tap = tap
        canSwallow = tap.swallows
        isListening = true
        poll = repeating(every: 2) { $0.checkSecureInput() }
    }

    private func stopListening() {
        guard isListening else { return }
        stopChoosingKey()
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

    // MARK: - Teaching hands-free

    /// When the HUD came up for this hold; nil once hands-free needs no tip.
    @ObservationIgnored private var tipClock: Date?

    /// The HUD came up: Space's tip, after a while, until hands-free has
    /// been used or the tip has shown its fill (its X and tick say how to end it).
    private func teachHandsFree(locked: Bool) {
        hud.model.tip = nil
        tipClock = nil
        if locked { settings.usedHandsFree = true } else if settings.wantsHandsFreeTip { tipClock = Date() }
    }

    /// Each tick of a hold: the Space tip once it has gone on long enough.
    private func offerHandsFree() {
        guard let since = tipClock, hud.model.mode == .recording,
              Date().timeIntervalSince(since) >= DictationDefaults.handsFreeTipAfter else { return }
        tipClock = nil
        settings.handsFreeTipsShown += 1
        hud.model.tip = "Press Space to keep going hands-free"
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
                    teachHandsFree(locked: effect == .enterLocked)
                    hud.show(effect == .enterLocked ? .locked : .recording)
                }
            case .submit(let mode):
                stopTicking()
                submit(mode)
            case .discard:
                stopTicking()
                target = nil
                capture.discardRecording()
                capture.stop()
                hud.hide()
            }
        }
        showLearned()
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
        ticker = repeating(every: DictationDefaults.tickInterval) {
            $0.send(.tick)
            $0.offerHandsFree()
        }
        // A password field: not a word is recorded. Said once the hold is
        // past the threshold, so typing an Option character there stays quiet.
        guard !focus.isSecure else { return }
        // Only when an edit could be learned from: the watch reads the field.
        if canLearn { DictationEditWatch.exposeText(pid: focus.pid) }
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
        capture.stop()
        hud.show(.message(text))
        showLearned()
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
    }

    private func submit(_ mode: DictationMode) {
        // The mic is off once the key is up, whatever became of the recording.
        defer { capture.stop() }
        guard let start = target, !start.isSecure else {
            hud.hide()
            capture.discardRecording()
            return
        }
        // Transcribing: the pill stays, working, until the text is typed.
        hud.show(.working)
        target = nil
        guard let recorded = capture.finishRecording() else {
            hud.show(.message("The recording could not be saved"))
            return
        }
        // Too short to hold a word, or no audio at all: strut is not asked
        // (an empty file once crashed its decoder), and it ends as silence does.
        guard recorded.duration >= DictationDefaults.minRecording else {
            try? FileManager.default.removeItem(at: recorded.url)
            // Another dictation still transcribing keeps the working pill.
            if inserting == 0 { hud.show(.message("Nothing was heard")) }
            return
        }
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
        inserting += 1
        insertion = Task {
            defer {
                try? FileManager.default.removeItem(at: session.audioURL)
                inserting -= 1
                // Typed with nothing to say, and nothing else being transcribed: the working pill goes.
                if inserting == 0, hud.model.mode == .working { hud.hide() }
                showLearned()
            }
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
            // The last field's watch ends before Peel types again, so it never reads this text as an edit.
            watch?.cancel()
            let outcome = await DictationTextInserter.insert(text, startedIn: start)
            let note = Self.message(for: outcome)
            var copied = false
            let kept: Bool
            switch outcome {
            case .inserted:
                kept = await entry.keep(text, .typed, heard: rewritten)
                watchForCorrections(of: text)
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
    /// A learn waiting for the HUD, with the strut and account it was made on.
    fileprivate struct Learned {
        let words: [String]
        let undo: [String]
        let server: MemoryServer
        let account: ObjectIdentifier
    }

    /// Watches the field for what the user does to `typed`, then, once the
    /// edit has settled, has strut learn what it can from it (one call: it
    /// runs a model), with Undo in the HUD. Only with a fixer running (without
    /// one strut learns nothing), while unlocked, and only for the strut and
    /// account there when the text went in.
    fileprivate func watchForCorrections(of typed: String) {
        watch?.cancel()
        watch = nil
        // A pick that was downloading when last read may be in use by now: read again for next time.
        if models.downloading { Task { await models.load() } }
        guard let (server, account) = learnTarget else {
            log.notice("edit watch not started: \(self.models.hasActiveFixer ? "Peel is locked or its strut is not running" : "no clean-up model in use", privacy: .public)")
            return
        }
        watch = DictationEditWatch.watch(typed: typed) { [weak self] edited in
            guard let self, let edited, edited != typed, isCurrent(server, account) else { return }
            Task { await self.learn(typed: typed, edited: edited, on: server, account: account) }
        }
    }

    /// Still the strut and the unlocked account a learn began with.
    private func isCurrent(_ server: MemoryServer, _ account: ObjectIdentifier) -> Bool {
        lingo.server == server && history().map(ObjectIdentifier.init) == account
    }

    /// Where an edit would be learned now: Peel's strut and the unlocked
    /// account, with a fixer in use (without one strut learns nothing).
    private var learnTarget: (server: MemoryServer, account: ObjectIdentifier)? {
        guard models.hasActiveFixer, let server = lingo.server, let storage = history() else { return nil }
        return (server, ObjectIdentifier(storage))
    }

    private var canLearn: Bool { learnTarget != nil }

    private func learn(typed: String, edited: String, on server: MemoryServer, account: ObjectIdentifier) async {
        let learned: [LingoLearned]
        do { learned = try await lingo.correct(typed: typed, edited: edited, on: server) } catch {
            log.error("lingo not learned: \(String(describing: error))")
            return
        }
        // Only what strut wrote now: a pair it already had needs no Undo.
        let new = learned.filter { !$0.undo.isEmpty }
        // Counts and lengths only, never the words.
        log.notice("edit sent to strut (typed \((typed as NSString).length, privacy: .public), edited \((edited as NSString).length, privacy: .public)): \(learned.count, privacy: .public) learned, \(new.count, privacy: .public) new")
        guard !new.isEmpty, isCurrent(server, account) else { return }
        self.learned = Learned(words: new.map(\.written), undo: new.flatMap(\.undo), server: server, account: account)
        showLearned()
    }

    /// Says what was learned, with Undo, once no dictation is under way and
    /// no insertion (the usual case: the next dictation is what ends the
    /// watch); called again whenever either finishes.
    private func showLearned() {
        guard let learned, machine.isIdle, inserting == 0 else { return }
        self.learned = nil
        // Not if the account locked or the strut changed since.
        guard isCurrent(learned.server, learned.account) else { return }
        hud.model.undo = { [weak self] in
            self?.hud.hide()
            Task { await self?.lingo.undo(learned.undo, on: learned.server) }
        }
        hud.show(.learned("Learned " + ListFormatter.localizedString(byJoining: learned.words)))
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
            outcome: outcome, note: note, heard: heard
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
