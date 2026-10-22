import AVFoundation
import Foundation
import PeelUI

/// The microphone, as 16 kHz mono PCM16. The engine's input tap runs the
/// whole time the engine does, filling a short pre-roll ring; a recording
/// starts with that ring and goes on into a temporary WAV file. Used from
/// the main thread; the audio thread only touches `lock`ed state.
final class DictationAudioCapture: @unchecked Sendable {
    enum Failure: Error { case permissionDenied, noInput, formatUnavailable }

    /// 0…1 for each buffer, on the audio thread.
    var onLevel: (@Sendable (Float) -> Void)?
    /// Something the user should know ("The microphone changed").
    var onProblem: (@Sendable (String) -> Void)?

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var preRoll = PreRollBuffer(seconds: DictationDefaults.preRoll, sampleRate: DictationDefaults.sampleRate)
    private var writer: WAVFileWriter?
    private var observer: (any NSObjectProtocol)?
    private(set) var isRunning = false

    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: DictationDefaults.sampleRate, channels: 1, interleaved: true
    )

    var isRecording: Bool { lock.withLock { writer != nil } }

    /// Starts the engine and fills the pre-roll. Throws without permission.
    func start() throws {
        guard !isRunning else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw Failure.permissionDenied }
        try install()
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in self?.configurationChanged() }
        isRunning = true
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        lock.withLock {
            preRoll.removeAll()
            writer?.discard()
            writer = nil
        }
    }

    /// Starts a file with the pre-roll in it; what comes next follows it.
    func beginRecording() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("peel-dictation-\(UUID().uuidString).wav")
        let new = try WAVFileWriter(url: url)
        try lock.withLock {
            guard writer == nil else { new.discard(); return }
            try new.append(preRoll.snapshot())
            writer = new
        }
    }

    /// The finished file and its length; nil if nothing was being recorded.
    func finishRecording() -> (url: URL, duration: TimeInterval)? {
        let finished = lock.withLock { () -> WAVFileWriter? in
            defer { writer = nil }
            return writer
        }
        guard let finished else { return nil }
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
        let old = lock.withLock { () -> WAVFileWriter? in
            defer { writer = nil }
            return writer
        }
        old?.discard()
    }

    // MARK: - Engine

    private func install() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Failure.noInput }
        guard let outputFormat, let converter = AVAudioConverter(from: format, to: outputFormat) else {
            throw Failure.formatUnavailable
        }
        lock.withLock { self.converter = converter }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    /// The device or its format changed (headphones, another input): the
    /// engine has stopped. Build the tap again; a recording goes on.
    private func configurationChanged() {
        do {
            try install()
        } catch {
            isRunning = false
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
        onLevel?(PCM16.level(of: samples))
        lock.withLock {
            if let writer {
                do { try writer.append(samples) } catch { self.writer = nil; writer.discard() }
            } else {
                preRoll.append(samples)
            }
        }
    }
}
