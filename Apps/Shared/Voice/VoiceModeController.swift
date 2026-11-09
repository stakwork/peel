import AVFoundation
import Foundation
import Observation
import PeelCore
import PeelUI
#if os(macOS)
import CoreAudio
#endif

/// Voice mode for the DM with the Peel agent (docs/voice-mode.md): listens,
/// sends what was said through the composer's own send path
/// (`AppModel.send(_:from:)`), waits for the agent's reply to it, reads it
/// aloud and listens again. The transitions are `VoiceMachine`'s (pure,
/// tested); this is what runs them: the audio session, the listener, the
/// speaker, the clock and the model. One per agent chat view.
@MainActor @Observable
final class VoiceModeController {
    /// What differs between the phone and the Mac, given by the view.
    struct Hooks {
        /// Whether the agent is still answering the message just sent.
        var isAnswering: @MainActor () -> Bool
        /// A card of the agent's waits for an approval.
        var isWaitingApproval: @MainActor () -> Bool
        /// Stops the agent's running turn; nil where the phone cannot.
        var stopAgentTurn: (@MainActor () -> Void)?
        /// Why voice mode cannot run now (a dictation is recording), if so.
        var blocked: @MainActor () -> String?
        /// The user's vocabulary, read-only: the Mac gives dictation's live
        /// lexicon. TODO (docs/voice-mode.md): the phone has no source yet
        /// (the vocabulary lives in the memory graph on the Mac's strut and
        /// must be synced to it), so it gives nil and voice mode there is
        /// generic-vocabulary.
        var lexicon: @MainActor () -> LingoLexicon? = { nil }
        /// Asks the source to read the vocabulary again; called when a
        /// listener starts (the next recognition task picks up the result).
        var refreshLexicon: (@MainActor () -> Void)?
    }

    var phase: VoicePhase { machine.phase }
    /// What the user said, with their vocabulary applied for display; the
    /// machine keeps the raw words.
    var draft: String { LexiconRewriter.apply(machine.draft, lexicon: hooks?.lexicon()) }
    /// Muted: the input is ignored but for "Peel unmute" (docs/voice-mode.md).
    var isMuted: Bool { machine.isMuted }
    /// 0…1 for the meter.
    private(set) var level: Float = 0
    /// The "Hey Peel" listener is on.
    private(set) var isArmed = false

    private var machine = VoiceMachine()
    @ObservationIgnored private var model: AppModel?
    @ObservationIgnored private var hooks: Hooks?
    @ObservationIgnored private var settings = VoiceSettings()
    private let parser = VoiceCommandParser()
    private let speaker: any SpeechSynthesizing = VoiceSpeaker()
    @ObservationIgnored private var listener: (any SpeechListening)?
    @ObservationIgnored private var wake: (any SpeechListening)?
    @ObservationIgnored private var wantsWake = false
    @ObservationIgnored private var starting = false
    @ObservationIgnored private var pendingTurn: PendingTurn?
    @ObservationIgnored private var lastReply: SpokenText?
    @ObservationIgnored private var silence: Task<Void, Never>?
    @ObservationIgnored private var supervisor: Task<Void, Never>?
    @ObservationIgnored private var retry: Task<Void, Never>?
    @ObservationIgnored private var retries = 0
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    /// What the speech says now and just said, to tell it from the user.
    @ObservationIgnored private var echo = EchoFilter()
    /// The output is headphones, Bluetooth, a car or USB: the speech does not
    /// come back into the microphone, so barge-in may use any control.
    @ObservationIgnored private var routeEchoSafe = false
    /// The draft held while muted; what is heard after unmuting is added to it
    /// (the listener's own text starts again at each mute and unmute).
    @ObservationIgnored private var draftBase = ""
    /// The draft held while something is read over it (a failed send's
    /// "say Peel send to try again", a reply that came while you paused):
    /// it comes back when the speech ends or is stopped.
    @ObservationIgnored private var heldDraft: String?
    /// When the draft last changed, so a reply waits while you are talking.
    @ObservationIgnored private var lastDictation = Date.distantPast
    /// The agent's messages already read or there before voice mode, by uuid.
    @ObservationIgnored private var seen: Set<String> = []
    @ObservationIgnored private var lastThinkingCue = Date.distantPast
    /// Voice mode is ending on a problem: the problem tone, not the off one.
    @ObservationIgnored private var problemEnding = false
    private let cues = VoiceCues()

    /// A message sent and not yet answered.
    private struct PendingTurn {
        var chat: String
        var text: String
        var before: Set<String>
        var sentUUID: String?
        var since = Date()
        var idleSince: Date?
        var announcedApproval = false
    }

    private static let sendFailed = "I could not send that. Say Peel send to try again."
    /// How long the draft must be still before a reply is read over it.
    private static let quietBeforeSpeaking: TimeInterval = 3
    /// How often the thinking tone sounds while the agent works.
    private static let thinkingEvery: TimeInterval = 10
    private static let approval = "Peel is waiting for your approval. Approve it on your Mac."
    /// How long a sent message may take to show in the chat before voice mode stops waiting for it.
    private static let findTimeout: TimeInterval = 20

    /// The strings the recogniser should expect.
    private var contextualStrings: [String] {
        VoiceVocabulary.contextualStrings(from: hooks?.lexicon(), base: ["Peel", "Hey Peel"] + parser.table.all)
    }

    init() {
        speaker.onFinished = { [weak self] in self?.speechEnded() }
    }

    func attach(_ model: AppModel, hooks: Hooks) {
        self.model = model
        self.hooks = hooks
    }

    // MARK: Entering and leaving

    func toggle() {
        if phase.isActive { stop() } else { Task { await start() } }
    }

    func start() async {
        guard let model, let hooks, let chat = model.agentChat, !phase.isActive, !starting else { return }
        starting = true
        defer { starting = false }
        if let reason = blockedReason(model, hooks) {
            model.conversationNotices[chat] = reason
            return
        }
        stopWake()
        let authorization = await VoiceAuthorization.request()
        if let notice = authorization.notice {
            model.conversationNotices[chat] = notice
            rearmIfWanted()
            return
        }
        // The answer may have taken a while (the prompt): re-check.
        if let reason = blockedReason(model, hooks) {
            model.conversationNotices[chat] = reason
            return
        }
        settings = VoiceSettings(defaults: .standard)
        retries = 0
        draftBase = ""
        heldDraft = nil
        echo.reset()
        seen = Set(model.timeline.messages.filter { $0.chat == chat }.compactMap(\.uuid))
        perform(machine.apply(.start))
        do {
            try activateSession()
            try startListener()
        } catch {
            fail("Voice mode could not start the microphone.")
            return
        }
        observe()
        supervise()
        // A tone, not a sentence: words said over a spoken greeting were lost.
        cues.play(.start)
    }

    func stop() {
        perform(machine.apply(.stop))
    }

    /// The panel's Send: the draft goes now, without waiting for the pause.
    func sendNow() {
        silence?.cancel()
        perform(machine.apply(.command(.send)))
    }

    /// The panel's Mute and Unmute, the same as saying "Peel mute".
    func toggleMute() {
        perform(machine.apply(.command(machine.isMuted ? .unmute : .mute)))
    }

    /// The panel's Stop speaking.
    func stopSpeaking() {
        perform(machine.apply(.command(.stopSpeaking)))
        restoreHeldDraft()
    }

    /// Voice mode, any way it ends: everything it holds is given back.
    private func teardown() {
        silence?.cancel()
        supervisor?.cancel()
        retry?.cancel()
        silence = nil
        supervisor = nil
        retry = nil
        speaker.stop()
        listener?.stop()
        listener = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        pendingTurn = nil
        draftBase = ""
        heldDraft = nil
        seen = []
        echo.reset()
        level = 0
        let ending: VoiceCues.Cue = problemEnding ? .problem : .end
        problemEnding = false
        if wantsWake {
            // `arm` sets the session up for itself.
            rearmIfWanted()
        } else {
            cues.play(ending)
            // Long enough for the tone; not if voice mode came back meanwhile.
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard let self, !phase.isActive, !isArmed, !starting else { return }
                cues.stop()
                deactivateSession()
            }
        }
    }

    private func fail(_ problem: String) {
        if let chat = model?.agentChat { model?.conversationNotices[chat] = problem }
        problemEnding = true
        perform(machine.apply(.failure(problem)))
    }

    private func blockedReason(_ model: AppModel, _ hooks: Hooks) -> String? {
        if model.calls.call != nil { return "Voice mode is off during a call." }
        return hooks.blocked()
    }

    // MARK: Effects

    private func perform(_ effects: [VoiceEffect]) {
        for effect in effects {
            switch effect {
            case .begin: break
            case .end: teardown()
            case .send(let text): send(text)
            case .clearDraft:
                draftBase = ""
                listener?.resetTranscript()
            case .stopSpeech:
                speaker.stop()
                echo.speechEnded(now: Date())
            case .skipSpeech:
                speaker.stop()
                speechEnded()
            case .mute:
                // Frozen: the draft stays as it is; what is heard from now
                // on is only matched for "unmute".
                silence?.cancel()
                draftBase = machine.draft
                listener?.resetTranscript()
            case .unmute:
                // What was heard while muted is forgotten.
                listener?.resetTranscript()
            case .speakLastReply:
                if let lastReply, !lastReply.chunks.isEmpty { say(lastReply.chunks) } else { say(["There is nothing to repeat."]) }
            case .speakFullReply:
                if let lastReply, !lastReply.full.isEmpty { say(lastReply.full) } else { say(["There is nothing more to read."]) }
            case .stopAgent:
                if let stop = hooks?.stopAgentTurn { stop() } else { say(["I can't stop the agent from here. Use your Mac."]) }
            }
        }
    }

    /// The composer's own send of a text message to the agent's DM.
    private func send(_ raw: String) {
        // The vocabulary is applied to the dictation only now: the commands
        // were parsed from the raw transcript.
        let text = LexiconRewriter.apply(raw, lexicon: hooks?.lexicon())
        guard let model, let chat = model.agentChat else {
            perform(machine.apply(.sendFinished(sent: false)))
            return
        }
        let before = Set(model.timeline.messages.compactMap(\.uuid))
        Task {
            // The text alone: not the composer's files or reply target.
            let sent = await model.sendDictated(text, to: chat)
            perform(machine.apply(.sendFinished(sent: sent)))
            guard phase.isActive else { return }
            if sent {
                // A turn still unanswered is replaced: its reply is read
                // when it comes, as a new message (`announceNew`).
                pendingTurn = PendingTurn(chat: chat, text: text, before: before)
                draftBase = ""
                listener?.resetTranscript()
                cues.play(.sent)
                lastThinkingCue = Date()
            } else {
                // The draft is kept (`say` holds it): a tunnel must not cost
                // what was said.
                cues.play(.problem)
                say([Self.sendFailed])
            }
        }
    }

    // MARK: Speaking

    private func say(_ chunks: [String]) {
        guard phase.isActive, !chunks.isEmpty else { return }
        // Read over a draft: it is kept and comes back after.
        if phase == .hearing, heldDraft == nil { heldDraft = machine.draft }
        speaker.stop()
        silence?.cancel()
        routeEchoSafe = Self.isEchoSafeRoute()
        echo.speechStarted(chunks: chunks, now: Date())
        perform(machine.apply(.speechStarted))
        speaker.speak(chunks, rate: settings.speechRate)
    }

    private func speechEnded() {
        guard phase == .speaking else { return }
        echo.speechEnded(now: Date())
        // `.speechEnded` clears the draft and the listener's text: a fresh
        // recognition task, so what the room heard is never dictation.
        perform(machine.apply(.speechEnded))
        restoreHeldDraft()
        if pendingTurn != nil { perform(machine.apply(.awaitReply)) }
        if phase == .listening || phase == .hearing { cues.play(.ready) }
    }

    /// The draft held over a speech is the draft again, and what is said
    /// next is added to it.
    private func restoreHeldDraft() {
        guard let held = heldDraft else { return }
        heldDraft = nil
        guard phase == .listening || phase == .waiting else { return }
        draftBase = held
        perform(machine.apply(.transcript(held)))
        lastDictation = Date()
    }

    // MARK: Listening

    private func startListener() throws {
        hooks?.refreshLexicon?()
        let listener = VoiceListener(contextualStrings: { [weak self] in self?.contextualStrings ?? [] })
        listener.onTranscript = { [weak self] transcript in self?.heard(transcript.text) }
        listener.onProblem = { [weak self] problem in self?.recognizerProblem(problem) }
        try listener.start()
        self.listener = listener
    }

    private func heard(_ text: String) {
        guard let context = machine.context else { return }
        let now = Date()
        let speaking = phase == .speaking
        // The speech itself, heard back: dropped, and in the tail after it
        // the listener starts over, so leftovers never join the dictation.
        if echo.isGuarding(now: now), echo.isEcho(text, now: now) {
            if !speaking { listener?.resetTranscript() }
            return
        }
        var accepted = context.accepts
        if speaking, !routeEchoSafe {
            // On the speaker the microphone may still hear the speech: only
            // the whole, exact control counts (and not if it is in the text).
            if context != .muted { accepted = [.stopSpeaking] }
            guard case .command(_, let before) = parser.parse(text, accepting: accepted), before.isEmpty,
                  !echo.currentlyContains(text)
            else {
                if VoiceCommandParser.normalize(text).split(separator: " ").count > 6 { listener?.resetTranscript() }
                return
            }
        }
        switch parser.parse(text, accepting: accepted) {
        case .command(let command, let before):
            silence?.cancel()
            // The words before "Peel send" or "Peel mute" are dictation.
            if command == .send || command == .mute {
                perform(machine.apply(.transcript(compose(before))))
            }
            perform(machine.apply(.command(command)))
            // What was said is the command, not the next draft.
            if command != .send, command != .deactivate { listener?.resetTranscript() }
            if command == .stopSpeaking { restoreHeldDraft() }
        case .none:
            // Only the user's message is taken as text; while muted, while the
            // agent answers or the speech plays, anything else is discarded
            // (muted: never stored or sent).
            guard context == .dictating else {
                if context == .muted, text.count > 120 { listener?.resetTranscript() }
                return
            }
            perform(machine.apply(.transcript(compose(text))))
            lastDictation = now
            scheduleSilence()
        }
    }

    /// The listener's text after what was held while muted.
    private func compose(_ text: String) -> String {
        guard !draftBase.isEmpty else { return text }
        let added = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return added.isEmpty ? draftBase : draftBase + " " + added
    }

    /// Headphones, Bluetooth, a car or USB audio out. Unsure counts as the speaker.
    private static func isEchoSafeRoute() -> Bool {
        #if os(iOS)
        let safe: [AVAudioSession.Port] = [.headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .carAudio, .usbAudio]
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains { safe.contains($0.portType) }
        #else
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != AudioObjectID(kAudioObjectUnknown)
        else { return false }
        var transportAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &transportAddress, 0, nil, &size, &transport) == noErr else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
            || transport == kAudioDeviceTransportTypeUSB
        #endif
    }

    private func scheduleSilence() {
        silence?.cancel()
        guard settings.autoSend, phase == .hearing, !machine.isMuted else { return }
        let seconds = settings.autoSendSeconds
        silence = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            perform(machine.apply(.silence))
        }
    }

    /// The recogniser gave up: one spoken word about it, then a new start
    /// after a growing wait; the third failure in a row leaves voice mode.
    private func recognizerProblem(_ problem: String) {
        guard phase.isActive else { return }
        retries += 1
        guard retries <= VoiceDefaults.retryLimit else {
            fail("Voice mode stopped: \(problem)")
            return
        }
        if retries == 1 { say(["I lost the microphone. Trying again."]) }
        let wait = VoiceDefaults.backoff(attempt: retries)
        retry?.cancel()
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self, phase.isActive else { return }
            listener?.stop()
            listener = nil
            do {
                try activateSession()
                try startListener()
            } catch {
                recognizerProblem("The microphone is not available.")
            }
        }
    }

    // MARK: Waiting for the agent

    /// Every quarter second while voice mode is on: the meter, a call or a
    /// dictation that started, and the reply to what was sent.
    private func supervise() {
        supervisor?.cancel()
        supervisor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self else { return }
                tick()
            }
        }
    }

    private func tick() {
        guard let model, let hooks, phase.isActive else { return }
        level = listener?.level ?? 0
        if let reason = blockedReason(model, hooks) {
            if let chat = model.agentChat { model.conversationNotices[chat] = reason }
            stop()
            return
        }
        pollReply(model, hooks)
        announceNew(model)
        if phase == .waiting, !machine.isMuted, Date().timeIntervalSince(lastThinkingCue) >= Self.thinkingEvery {
            lastThinkingCue = Date()
            cues.play(.thinking)
        }
    }

    /// Whether something may be read now: not over your words while you are
    /// still saying them, nor over another speech.
    private var canSpeakNow: Bool {
        switch phase {
        case .listening, .waiting: true
        case .hearing: Date().timeIntervalSince(lastDictation) > Self.quietBeforeSpeaking
        default: false
        }
    }

    /// The agent's messages that are not the reply being waited for (a job
    /// that finished, the answer to a message sent before the last one) are
    /// read too when they come, so nothing it says is missed while driving.
    private func announceNew(_ model: AppModel) {
        guard canSpeakNow, let chat = model.agentChat else { return }
        // Until the message just sent is found its reply cannot be told apart.
        if let turn = pendingTurn, turn.sentUUID == nil { return }
        let new = model.timeline.messages.filter { message in
            guard message.chat == chat, !message.fromMe, message.type == MessageType.text, !message.deleted,
                  message.control == nil, let uuid = message.uuid, !seen.contains(uuid) else { return false }
            return pendingTurn == nil || message.replyUUID != pendingTurn?.sentUUID
        }
        guard !new.isEmpty else { return }
        new.compactMap(\.uuid).forEach { seen.insert($0) }
        guard settings.spokenReplies else { return }
        let spoken = new.map { SpokenText(markdown: $0.shownText) }.filter { !$0.chunks.isEmpty }
        guard !spoken.isEmpty else { return }
        let intro = new.contains { $0.replyUUID != nil } ? "Peel answered an earlier message." : "A new message from Peel."
        lastReply = spoken.last
        say([intro] + spoken.flatMap(\.chunks))
    }

    private func pollReply(_ model: AppModel, _ hooks: Hooks) {
        guard var turn = pendingTurn, phase != .sending, phase != .speaking else { return }
        let messages = model.timeline.messages.filter { $0.chat == turn.chat }
        defer { if pendingTurn != nil { pendingTurn = turn } }

        if turn.sentUUID == nil {
            turn.sentUUID = Self.sentMessage(turn, in: messages)?.uuid
            if turn.sentUUID == nil, Date().timeIntervalSince(turn.since) > Self.findTimeout {
                finishTurn(&turn, reply: nil)
            }
            return
        }
        // Read nothing over your words while you are still saying them.
        guard canSpeakNow else { return }
        if hooks.isWaitingApproval(), !turn.announcedApproval {
            turn.announcedApproval = true
            pendingTurn = turn
            say([Self.approval])
            return
        }
        let reply = messages.last { message in
            !message.fromMe && message.type == MessageType.text && !message.deleted && message.replyUUID == turn.sentUUID
        }
        if let reply {
            let already = reply.uuid.map { seen.contains($0) } ?? false
            reply.uuid.map { _ = seen.insert($0) }
            finishTurn(&turn, reply: already ? nil : reply.shownText)
        } else if !hooks.isAnswering() {
            // Not answering and nothing came (the turn was stopped here): stop waiting.
            let since = turn.idleSince ?? Date()
            turn.idleSince = since
            if Date().timeIntervalSince(since) > 3 { finishTurn(&turn, reply: nil) }
        } else {
            turn.idleSince = nil
        }
    }

    /// The message just sent: yours, a text, new since the send, with its words.
    private static func sentMessage(_ turn: PendingTurn, in messages: [Message]) -> Message? {
        messages.last { message in
            guard message.fromMe, message.type == MessageType.text, let uuid = message.uuid else { return false }
            let words = (message.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return !turn.before.contains(uuid) && words == turn.text
        }
    }

    /// The turn is over: its reply is read, or listening resumes.
    private func finishTurn(_ turn: inout PendingTurn, reply: String?) {
        pendingTurn = nil
        let spoken = reply.map { SpokenText(markdown: $0) }
        if let spoken, !spoken.chunks.isEmpty { lastReply = spoken }
        guard let spoken, settings.spokenReplies, !spoken.chunks.isEmpty else {
            perform(machine.apply(.replyReady(hasReply: false)))
            if reply != nil, phase == .listening { cues.play(.ready) }
            return
        }
        perform(machine.apply(.replyReady(hasReply: true)))
        say(spoken.chunks)
    }

    // MARK: Wake phrase

    /// Starts listening for "Hey Peel" (only while the agent chat is on
    /// screen and in front; the view calls `disarm` otherwise).
    func arm() {
        wantsWake = true
        guard !isArmed, !phase.isActive, !starting, let model, let hooks, blockedReason(model, hooks) == nil else { return }
        Task {
            guard await VoiceAuthorization.request() == .granted, wantsWake, !isArmed, !phase.isActive else { return }
            do {
                try activateWakeSession()
                hooks.refreshLexicon?()
                let wake = VoiceListener(contextualStrings: { [weak self] in self?.contextualStrings ?? [] })
                wake.onTranscript = { [weak self] transcript in self?.heardWake(transcript.text) }
                wake.onProblem = { [weak self] _ in self?.stopWake() }
                try wake.start()
                self.wake = wake
                isArmed = true
            } catch {
                stopWake()
            }
        }
    }

    func disarm() {
        wantsWake = false
        stopWake()
    }

    private func stopWake() {
        guard isArmed || wake != nil else { return }
        wake?.stop()
        wake = nil
        isArmed = false
        if !phase.isActive { deactivateSession() }
    }

    private func rearmIfWanted() {
        if wantsWake { arm() }
    }

    private func heardWake(_ text: String) {
        // The wake listener hears a running transcript, so the phrase is the
        // end of it, not the whole.
        var table = parser.table
        table.trailing.insert(.activate)
        if case .command(.activate, _) = VoiceCommandParser(table: table).parse(text, accepting: VoiceContext.armed.accepts) {
            wake?.resetTranscript()
            Task {
                stopWake()
                await start()
            }
        } else if text.count > 120 {
            wake?.resetTranscript()
        }
    }

    // MARK: Audio session

    private func activateSession() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        // .voiceChat gives echo cancellation, so barge-in and speech coexist,
        // at the cost of a little speech volume and quality.
        // Music and podcasts pause unless the user asked to keep them
        // (`pauseOtherAudio`): mixed in, the microphone writes their words
        // into the draft. They resume when voice mode ends
        // (`.notifyOthersOnDeactivation`).
        var options: AVAudioSession.CategoryOptions = [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]
        if !settings.pauseOtherAudio { options.insert(.interruptSpokenAudioAndMixWithOthers) }
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: options)
        try session.setActive(true)
        #endif
    }

    private func activateWakeSession() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        // Not `.allowBluetoothHFP`: it would put AirPods in call quality, and
        // the music with them, for as long as the chat is open. The phone's
        // own microphone hears "Hey Peel"; voice mode takes the headset's.
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothA2DP, .defaultToSpeaker, .mixWithOthers])
        try session.setActive(true)
        #endif
    }

    private func deactivateSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    /// Interruptions, route changes and a reset media server (iOS).
    private func observe() {
        #if os(iOS)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            MainActor.assumeIsolated { self?.interruption(type: type, options: options) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated { self?.routeChanged(reason: reason) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // Everything audio was rebuilt by the system: start over is the safe way.
                self?.fail("Voice mode ended: audio was reset by the system.")
            }
        })
        #endif
    }

    #if os(iOS)
    private func interruption(type: UInt?, options: UInt?) {
        guard phase.isActive else { return }
        switch type.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) {
        case .began:
            speaker.pause()
            listener?.stop()
            listener = nil
        case .ended:
            let resume = options.map { AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume) } ?? false
            guard resume else {
                fail("Voice mode ended: another app took the audio.")
                return
            }
            do {
                try activateSession()
                try startListener()
                speaker.resume()
            } catch {
                fail("Voice mode ended: the microphone is not available.")
            }
        default: break
        }
    }

    private func routeChanged(reason: UInt?) {
        guard phase.isActive else { return }
        switch reason.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:)) {
        case .oldDeviceUnavailable:
            // The headset or car went away: do not carry on out loud on the
            // speaker. Paused; "repeat that" or Stop picks it up.
            speaker.pause()
            (listener as? VoiceListener)?.rebuildSoon()
        case .newDeviceAvailable, .routeConfigurationChange:
            (listener as? VoiceListener)?.rebuildSoon()
        default: break
        }
    }
    #endif
}
