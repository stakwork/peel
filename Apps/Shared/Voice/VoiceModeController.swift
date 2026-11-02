import AVFoundation
import Foundation
import Observation
import PeelCore
import PeelUI

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
    }

    var phase: VoicePhase { machine.phase }
    var draft: String { machine.draft }
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

    private static let confirmation = "Voice mode on. Say send it when you are done."
    private static let approval = "Peel is waiting for your approval. Approve it on your Mac."
    /// How long a sent message may take to show in the chat before voice mode stops waiting for it.
    private static let findTimeout: TimeInterval = 20

    /// The strings the recogniser should expect.
    private var contextualStrings: [String] {
        ["Peel", "Hey Peel"] + parser.table.all
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
        if settings.spokenReplies { say([Self.confirmation]) }
    }

    func stop() {
        perform(machine.apply(.stop))
    }

    /// The panel's Send: the draft goes now, without waiting for the pause.
    func sendNow() {
        silence?.cancel()
        perform(machine.apply(.command(.send)))
    }

    /// The panel's Stop speaking.
    func stopSpeaking() {
        perform(machine.apply(.command(.stopSpeaking)))
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
        level = 0
        deactivateSession()
        rearmIfWanted()
    }

    private func fail(_ problem: String) {
        if let chat = model?.agentChat { model?.conversationNotices[chat] = problem }
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
            case .clearDraft: listener?.resetTranscript()
            case .stopSpeech: speaker.stop()
            case .skipSpeech:
                speaker.stop()
                speechEnded()
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
    private func send(_ text: String) {
        guard let model, let chat = model.agentChat else {
            perform(machine.apply(.sendFinished(sent: false)))
            return
        }
        let before = Set(model.timeline.messages.compactMap(\.uuid))
        Task {
            let sent = await model.send(text, from: .chat(chat))
            perform(machine.apply(.sendFinished(sent: sent)))
            guard phase.isActive else { return }
            if sent {
                pendingTurn = PendingTurn(chat: chat, text: text, before: before)
                listener?.resetTranscript()
            } else {
                say(["I could not send that."])
            }
        }
    }

    // MARK: Speaking

    private func say(_ chunks: [String]) {
        guard phase.isActive, !chunks.isEmpty else { return }
        speaker.stop()
        perform(machine.apply(.speechStarted))
        speaker.speak(chunks, rate: settings.speechRate)
    }

    private func speechEnded() {
        guard phase == .speaking else { return }
        perform(machine.apply(.speechEnded))
        if pendingTurn != nil { perform(machine.apply(.awaitReply)) }
    }

    // MARK: Listening

    private func startListener() throws {
        let listener = VoiceListener(contextualStrings: contextualStrings)
        listener.onTranscript = { [weak self] transcript in self?.heard(transcript.text) }
        listener.onProblem = { [weak self] problem in self?.recognizerProblem(problem) }
        try listener.start()
        self.listener = listener
    }

    private func heard(_ text: String) {
        guard let context = phase.context else { return }
        switch parser.parse(text, accepting: context.accepts) {
        case .command(let command, let before):
            silence?.cancel()
            if command == .send {
                perform(machine.apply(.transcript(before)))
            }
            perform(machine.apply(.command(command)))
            // What was said is the command, not the next draft.
            if command != .send, command != .deactivate { listener?.resetTranscript() }
        case .none:
            // Only the user's message is taken as text; while the agent
            // answers or the speech plays, anything else is noise or echo.
            guard context == .dictating else { return }
            perform(machine.apply(.transcript(text)))
            scheduleSilence()
        }
    }

    private func scheduleSilence() {
        silence?.cancel()
        guard settings.autoSend, phase == .hearing else { return }
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
    }

    private func pollReply(_ model: AppModel, _ hooks: Hooks) {
        guard var turn = pendingTurn, phase == .waiting || phase == .listening else { return }
        let messages = model.timeline.messages.filter { $0.chat == turn.chat }
        defer { if pendingTurn != nil { pendingTurn = turn } }

        if turn.sentUUID == nil {
            turn.sentUUID = Self.sentMessage(turn, in: messages)?.uuid
            if turn.sentUUID == nil, Date().timeIntervalSince(turn.since) > Self.findTimeout {
                finishTurn(&turn, reply: nil)
            }
            return
        }
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
            finishTurn(&turn, reply: reply.shownText)
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
                let wake = VoiceListener(contextualStrings: contextualStrings)
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
        try session.setCategory(
            .playAndRecord, mode: .voiceChat,
            options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker, .interruptSpokenAudioAndMixWithOthers]
        )
        try session.setActive(true)
        #endif
    }

    private func activateWakeSession() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP, .defaultToSpeaker, .mixWithOthers])
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
