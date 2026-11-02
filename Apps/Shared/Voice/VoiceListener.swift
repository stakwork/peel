import AVFoundation
import Foundation
import Speech
#if os(macOS)
import CoreAudio
#endif

/// What the recogniser has heard.
struct VoiceTranscript: Sendable, Equatable {
    /// Everything heard since the last `resetTranscript()`.
    var text: String
}

/// Speech to text for voice mode, as a seam: `VoiceListener` is the
/// `SFSpeechRecognizer` one. TODO (docs/voice-mode.md, follow-up): a
/// `SpeechAnalyzer`/`SpeechTranscriber` conformance (iOS and macOS 26) has
/// no task limit and better accuracy; the deployment target allows it on
/// the phone, but it was not written without a compiler to check it.
@MainActor
protocol SpeechListening: AnyObject {
    /// Partial and final transcripts alike.
    var onTranscript: ((VoiceTranscript) -> Void)? { get set }
    /// The input could not be kept running; the text says why.
    var onProblem: ((String) -> Void)? { get set }
    /// 0…1, the input's loudness now, for a meter.
    var level: Float { get }
    func start() throws
    func stop()
    /// Forgets the text so far (after a send, or what was heard while speaking).
    func resetTranscript()
}

/// Why listening cannot start.
enum VoiceAuthorization: Equatable {
    case granted
    case microphoneDenied
    case speechDenied
    case unavailable

    /// What the chat's notice says; nil when granted.
    var notice: String? {
        switch self {
        case .granted: nil
        case .microphoneDenied: "Allow the microphone for Peel in Settings to use voice mode."
        case .speechDenied: "Allow speech recognition for Peel in Settings to use voice mode."
        case .unavailable: "Speech recognition is not available for your language on this device."
        }
    }

    /// Asks for what is not yet decided: the system's prompts show once.
    static func request() async -> VoiceAuthorization {
        guard await microphone() else { return .microphoneDenied }
        guard await speech() else { return .speechDenied }
        guard SFSpeechRecognizer(locale: .current)?.isAvailable == true else { return .unavailable }
        return .granted
    }

    private static func microphone() async -> Bool {
        #if os(iOS)
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default: return await AVAudioApplication.requestRecordPermission()
        }
        #else
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
        #endif
    }

    private static func speech() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined: return await requestSpeech()
        default: return false
        }
    }

    // Not isolated: the system answers on its own queue.
    private nonisolated static func requestSpeech() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
    }
}

/// Where the engine's tap puts audio. Not isolated, because the audio
/// thread calls it: the current request and the level are under `lock`.
final class VoiceAudioFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var current: Float = 0

    var level: Float {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// Audio goes to `request` from now on; the one before is told it ended.
    func swap(to request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        let old = self.request
        self.request = request
        lock.unlock()
        old?.endAudio()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        var sum: Float = 0
        if let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 {
            let count = Int(buffer.frameLength)
            for i in 0..<count { sum += samples[i] * samples[i] }
            sum = (sum / Float(count)).squareRoot()
        }
        lock.lock()
        current = min(1, sum * 6)
        let request = request
        lock.unlock()
        request?.append(buffer)
    }

    /// Taps `node` into this feed (made here, not in an actor's method,
    /// so the tap's closure is not tied to the main actor).
    func install(on node: AVAudioInputNode, format: AVAudioFormat) {
        node.installTap(onBus: 0, bufferSize: 2048, format: format) { [self] buffer, _ in append(buffer) }
    }
}

/// On-device streaming recognition from an `AVAudioEngine` tap. A
/// recognition task lasts about a minute, so a new one starts before and
/// after that, with the text of the earlier ones kept (`segments`).
@MainActor
final class VoiceListener: SpeechListening {
    var onTranscript: ((VoiceTranscript) -> Void)?
    var onProblem: ((String) -> Void)?
    var level: Float { feed.level }

    private let feed = VoiceAudioFeed()
    private var engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var task: SFSpeechRecognitionTask?
    private var running = false
    /// Each task's text, by the number it started with; the draft is
    /// their join in order.
    private var segments: [Int: String] = [:]
    private var generation = 0
    /// Results of tasks before this one are ignored (after a reset).
    private var floor = 0
    private var rotation: Task<Void, Never>?
    private var quickFailures = 0
    private var lastStart = Date.distantPast
    private let extraStrings: [String]
    private var configurationObserver: (any NSObjectProtocol)?
    private var rebuilding: Task<Void, Never>?
    #if os(macOS)
    private var inputListener: AudioObjectPropertyListenerBlock?
    #endif

    /// Tasks are ended and replaced this often, before the system's limit.
    private static let rotateAfter: TimeInterval = 50

    /// `contextualStrings`: what the recogniser should expect (Peel, the phrases).
    init(contextualStrings: [String]) { extraStrings = contextualStrings }

    func start() throws {
        guard !running else { return }
        guard let recognizer = SFSpeechRecognizer(locale: .current), recognizer.isAvailable else {
            throw VoiceListenerError.unavailable
        }
        self.recognizer = recognizer
        try buildEngine()
        running = true
        quickFailures = 0
        beginTask()
        #if os(macOS)
        watchDefaultInput()
        #endif
    }

    func stop() {
        running = false
        rotation?.cancel()
        rotation = nil
        task?.cancel()
        task = nil
        rebuilding?.cancel()
        rebuilding = nil
        feed.swap(to: nil)
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        configurationObserver.map(NotificationCenter.default.removeObserver)
        configurationObserver = nil
        #if os(macOS)
        unwatchDefaultInput()
        #endif
        segments = [:]
    }

    /// A new engine on the input as it is now: when a headset connects or
    /// leaves, the old one keeps the format it started with. Called on a
    /// route change (`VoiceModeController`), the engine's own word that its
    /// configuration changed, and on the Mac a new default input. A burst of
    /// them (a Bluetooth headset switching profile) makes one engine.
    func rebuildSoon() {
        guard running else { return }
        rebuilding?.cancel()
        rebuilding = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self, running else { return }
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            do { try buildEngine() } catch { fail("The microphone stopped working.") }
        }
    }

    #if os(macOS)
    private static var defaultInput: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func watchDefaultInput() {
        var address = Self.defaultInput
        let block = Self.inputListenerBlock { [weak self] in Task { @MainActor in self?.rebuildSoon() } }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
        inputListener = block
    }

    private func unwatchDefaultInput() {
        guard let block = inputListener else { return }
        var address = Self.defaultInput
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
        inputListener = nil
    }

    private nonisolated static func inputListenerBlock(_ fire: @escaping @Sendable () -> Void) -> AudioObjectPropertyListenerBlock {
        { _, _ in fire() }
    }
    #endif

    func resetTranscript() {
        segments = [:]
        floor = generation + 1
        guard running else { return }
        beginTask()
    }

    private func buildEngine() throws {
        engine = AVAudioEngine()
        let input = engine.inputNode
        // Echo cancellation, so what the speech plays is not heard as the
        // user (barge-in listens while it plays). Best effort: without it
        // the controller still ignores everything but whole-utterance controls.
        try? input.setVoiceProcessingEnabled(true)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw VoiceListenerError.noInput }
        feed.install(on: input, format: format)
        configurationObserver.map(NotificationCenter.default.removeObserver)
        configurationObserver = Self.observeConfiguration(of: engine) { [weak self] in
            Task { @MainActor in self?.rebuildSoon() }
        }
        engine.prepare()
        try engine.start()
    }

    /// Starts a recognition task on the feed, replacing the one running.
    private func beginTask() {
        guard running, let recognizer else { return }
        generation += 1
        let mine = generation
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = false
        request.contextualStrings = extraStrings
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        lastStart = Date()
        let old = task
        task = Self.recognize(recognizer, request) { [weak self] text, finished, failed in
            Task { @MainActor in self?.result(generation: mine, text: text, finished: finished, failed: failed) }
        }
        feed.swap(to: request)
        old?.finish()
        rotation?.cancel()
        rotation = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.rotateAfter))
            guard !Task.isCancelled else { return }
            self?.beginTask()
        }
    }

    private nonisolated static func observeConfiguration(
        of engine: AVAudioEngine, _ fire: @escaping @Sendable () -> Void
    ) -> any NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { _ in fire() }
    }

    /// Made outside the actor: the recogniser calls back on its own queue.
    private nonisolated static func recognize(
        _ recognizer: SFSpeechRecognizer, _ request: SFSpeechAudioBufferRecognitionRequest,
        deliver: @escaping @Sendable (String?, Bool, Bool) -> Void
    ) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            deliver(result?.bestTranscription.formattedString, result?.isFinal ?? false, error != nil)
        }
    }

    private func result(generation mine: Int, text: String?, finished: Bool, failed: Bool) {
        guard running, mine >= floor else { return }
        if let text {
            segments[mine] = text
            quickFailures = 0
            let joined = segments.keys.sorted().compactMap { segments[$0] }.filter { !$0.isEmpty }.joined(separator: " ")
            onTranscript?(VoiceTranscript(text: joined))
        }
        guard (finished || failed), mine == generation else { return }
        // The task ended by itself (its limit, or silence): start another.
        // Several that end at once, with no words, mean something is wrong.
        if failed, text == nil, Date().timeIntervalSince(lastStart) < 2 {
            quickFailures += 1
            if quickFailures >= 3 {
                fail("Speech recognition stopped working.")
                return
            }
        }
        beginTask()
    }

    private func fail(_ problem: String) {
        stop()
        onProblem?(problem)
    }
}

enum VoiceListenerError: Error {
    case unavailable, noInput
}
