import AVFoundation
import CoreAudio
import Foundation
import PeelUI

/// The microphone, as 16 kHz mono PCM16 into a temporary WAV file. It runs
/// only while the hotkey is down or a recording goes on, so the mic
/// indicator (and a Bluetooth headset's call mode) is on only then. Used
/// from the main thread; the audio thread only touches `lock`ed state.
///
/// An engine stays on the input it started with, so when the input changes
/// (AirPods connect, another mic is chosen) a new one is made: on macOS's
/// word that the default input changed and on the engine's that its
/// configuration did. Each press starts a new engine, so none is left deaf
/// on an input that went away while dictation was idle.
final class DictationAudioCapture: @unchecked Sendable {
    enum Failure: Error { case permissionDenied, noInput, formatUnavailable }

    /// 0…1 for each buffer while recording, on the audio thread.
    var onLevel: (@Sendable (Float) -> Void)?
    /// The microphone stopped working, on the main thread.
    var onProblem: (@Sendable (String) -> Void)?

    private var engine = AVAudioEngine()
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var writer: WAVFileWriter?
    private var observer: (any NSObjectProtocol)?
    private var inputListener: AudioObjectPropertyListenerBlock?
    private var pendingRebuild: DispatchWorkItem?
    /// The input the engine was made on.
    private var device: AudioDeviceID?
    /// When the input last delivered audio (`systemUptime`), under `lock`.
    private var lastAudio: TimeInterval = 0
    private(set) var isRunning = false

    /// Buffers come every 100–250 ms; this long without one, the engine is deaf.
    private static let quietAfter: TimeInterval = 1
    /// Device changes come in bursts (a Bluetooth headset switches profile as
    /// its mic opens): one new engine for the burst.
    private static let settle: TimeInterval = 0.25

    private static var defaultInput: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: DictationDefaults.sampleRate, channels: 1, interleaved: true
    )

    /// Starts the engine. Throws without permission.
    func start() throws {
        guard !isRunning else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw Failure.permissionDenied }
        try install()
        var address = Self.defaultInput
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.rebuildSoon() }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        inputListener = listener
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        if let inputListener {
            var address = Self.defaultInput
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, inputListener)
        }
        inputListener = nil
        tearDown()
        isRunning = false
        lock.withLock {
            writer?.discard()
            writer = nil
        }
    }

    /// Starts a file; what the engine hears next goes into it.
    func beginRecording() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("peel-dictation-\(UUID().uuidString).wav")
        let new = try WAVFileWriter(url: url)
        lock.withLock {
            guard writer == nil else { new.discard(); return }
            writer = new
        }
    }

    /// The finished file and its length; nil if nothing was being recorded.
    func finishRecording() -> (url: URL, duration: TimeInterval)? {
        guard let finished = takeWriter() else { return nil }
        do {
            try finished.finish()
            return (finished.url, finished.duration)
        } catch {
            finished.discard()
            return nil
        }
    }

    /// Throws the recording away, file and all.
    func discardRecording() {
        takeWriter()?.discard()
    }

    private func takeWriter() -> WAVFileWriter? {
        lock.withLock {
            defer { writer = nil }
            return writer
        }
    }

    // MARK: - Engine

    /// A new engine on the current default input, its tap filling the
    /// recording under way.
    ///
    /// Set to the device itself: an engine that follows the default opens the
    /// app's default-device aggregate, which a call's voice processing can
    /// leave deaf until Peel is relaunched (docs/dictation.md, 2026-10-28).
    private func install() throws {
        guard var id = Self.currentInput() else { throw Failure.noInput }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        guard let unit = input.audioUnit, AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &id, UInt32(MemoryLayout<AudioDeviceID>.size)
        ) == noErr else { throw Failure.noInput }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Failure.noInput }
        guard let outputFormat, let converter = AVAudioConverter(from: format, to: outputFormat) else {
            throw Failure.formatUnavailable
        }
        lock.withLock {
            self.converter = converter
            // A new engine has a moment before its first buffer.
            lastAudio = ProcessInfo.processInfo.systemUptime
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        try engine.start()
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.rebuildSoon() }
        self.engine = engine
        device = id
    }

    private func tearDown() {
        pendingRebuild?.cancel()
        pendingRebuild = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private var isQuiet: Bool {
        lock.withLock { ProcessInfo.processInfo.systemUptime - lastAudio } > Self.quietAfter
    }

    /// macOS's default input now.
    private static func currentInput() -> AudioDeviceID? {
        var address = defaultInput
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    /// The input or its format changed: a new engine once the burst settles.
    private func rebuildSoon() {
        guard isRunning else { return }
        pendingRebuild?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rebuild() }
        pendingRebuild = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settle, execute: work)
    }

    /// The old engine out, a new one on today's input; a recording goes on.
    private func rebuild() {
        guard isRunning else { return }
        // Still running on the same input (an output changed, or the notice
        // named the device it already has): nothing to do.
        if engine.isRunning, device == Self.currentInput(), !isQuiet { return }
        tearDown()
        do {
            try install()
        } catch {
            stop()
            onProblem?("The microphone is not available")
        }
    }

    /// On the audio thread.
    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let outputFormat else { return }
        let converter = lock.withLock { self.converter }
        guard let converter else { return }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
        nonisolated(unsafe) var consumed = false
        nonisolated(unsafe) let input = buffer
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, error == nil, out.frameLength > 0, let channel = out.int16ChannelData else { return }
        let samples = Array(UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength)))
        let recording = lock.withLock {
            lastAudio = ProcessInfo.processInfo.systemUptime
            guard let writer else { return false }
            do { try writer.append(samples) } catch { self.writer = nil; writer.discard() }
            return true
        }
        // Only a recording shows a meter.
        if recording { onLevel?(PCM16.level(of: samples)) }
    }
}
