import AVFoundation
import CoreMedia
@preconcurrency import ScreenCaptureKit
import Synchronization

/// A display, its cursor and the microphone, written to an MP4 by
/// ScreenCaptureKit's own recording output (docs/recording.md). The display
/// comes from macOS's picker (`ScreenShare.pick`), so Peel holds no standing
/// Screen Recording permission. Peel's own windows are in it, as anything
/// else on the display is (a recording of Peel itself); only the recording's
/// bar never is.
///
/// The mic is the default input at Record, for the whole recording: any
/// change to the stream's configuration (another mic, or the same one
/// opened again) makes the recording output finish its file, ending the
/// recording there. A mic that drops mid-recording is only noticed
/// (`micSilence`).
@MainActor
final class ScreenRecorder {
    private let stream: SCStream
    private let output: SCRecordingOutput
    private let delegate: RecorderDelegate

    /// The longest side recorded: sharp text, a file that fits an attachment.
    private static let maxSide: CGFloat = 1920
    private static let fps: Int32 = 30

    private init(stream: SCStream, output: SCRecordingOutput, delegate: RecorderDelegate) {
        self.stream = stream
        self.output = output
        self.delegate = delegate
    }

    /// Starts recording `filter` into a temporary MP4. `ended` runs once,
    /// with the file and the failure if there was one, when the file is
    /// finished or the recording failed: after `stop()`, or when macOS ended
    /// the capture (the menu bar's Stop, the display going away). It can come
    /// before this returns.
    static func start(
        _ filter: SCContentFilter, ended: @escaping @MainActor (URL, (any Error)?) -> Void
    ) async throws -> ScreenRecorder {
        let configuration = SCStreamConfiguration.fitting(filter, maxSide: maxSide, fps: fps)
        configuration.captureMicrophone = true
        // The input itself, as dictation learned: one following the default
        // can be left deaf by a call's voice processing.
        configuration.microphoneCaptureDeviceID = AVCaptureDevice.default(for: .audio)?.uniqueID

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("peel-recording-\(UUID().uuidString).mp4")
        let recording = SCRecordingOutputConfiguration()
        recording.outputURL = url
        recording.outputFileType = .mp4
        recording.videoCodecType = .h264

        let delegate = RecorderDelegate { error in
            Task { @MainActor in ended(url, error) }
        }
        let output = SCRecordingOutput(configuration: recording, delegate: delegate)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: delegate)
        do {
            try stream.addRecordingOutput(output)
            // Frames are taken (and dropped) here as well, so the stream never
            // reports frames without an output for them.
            try stream.addStreamOutput(delegate, type: .screen, sampleHandlerQueue: delegate.queue)
            try stream.addStreamOutput(delegate, type: .microphone, sampleHandlerQueue: delegate.queue)
            try await stream.startCapture()
        } catch {
            // Nothing for `ended` to report: this throws instead.
            _ = delegate.claim()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return ScreenRecorder(stream: stream, output: output, delegate: delegate)
    }

    var duration: TimeInterval { output.recordedDuration.seconds.isFinite ? output.recordedDuration.seconds : 0 }

    /// How long the mic has sent nothing but zeros: a live mic always
    /// hears something, so this is a mic gone, not a quiet room.
    var micSilence: TimeInterval { delegate.micSilence }

    /// Ends the recording; `ended` follows once the file is finished, or,
    /// if the recording output never says so, after `finishing`.
    func stop() async {
        do {
            try await stream.stopCapture()
            delegate.finishLater(nil)
        } catch {
            // Already stopped (macOS's Stop came first): its file may still be closing.
            delegate.finishLater(error)
        }
    }
}

/// The stream's and the recording's delegate, on ScreenCaptureKit's queues.
private final class RecorderDelegate: NSObject, SCStreamDelegate, SCStreamOutput, SCRecordingOutputDelegate, Sendable {
    let queue = DispatchQueue(label: "peel.screen-recording")
    private let ended: @Sendable ((any Error)?) -> Void
    private let done = Mutex(false)
    /// When the mic last sent anything but zeros.
    private let lastSound = Mutex(ContinuousClock.now)

    /// How long the recording output has to finish its file after macOS
    /// ends the capture, before the stop's error stands: a long recording's
    /// file takes a while to close.
    private static let finishing: TimeInterval = 60

    init(ended: @escaping @Sendable ((any Error)?) -> Void) {
        self.ended = ended
    }

    /// True the first time only: whoever claims it reports the end.
    func claim() -> Bool {
        done.withLock { done in
            defer { done = true }
            return !done
        }
    }

    /// Once only: the recording finished, or the first failure.
    func finish(_ error: (any Error)?) {
        if claim() { ended(error) }
    }

    var micSilence: TimeInterval {
        let quiet = lastSound.withLock { $0 }.duration(to: .now).components
        return Double(quiet.seconds) + Double(quiet.attoseconds) / 1e18
    }

    /// Frames are dropped; the mic's sound is read for whether it is there at all.
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .microphone, let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var bytes: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &length, totalLengthOut: nil, dataPointerOut: &bytes) == noErr,
              let bytes else { return }
        // Zero is zero in every sample format.
        if UnsafeRawBufferPointer(start: bytes, count: length).contains(where: { $0 != 0 }) {
            lastSound.withLock { $0 = .now }
        }
    }

    /// The end, unless the recording output reports it first, within `finishing`.
    func finishLater(_ error: (any Error)?) {
        queue.asyncAfter(deadline: .now() + Self.finishing) { [self] in
            finish(error ?? CocoaError(.fileWriteUnknown))
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        // macOS ended the capture (the menu bar's Stop): the recording output
        // finishes its file and says so; if it never does, this error stands.
        finishLater(error)
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        finish(nil)
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        finish(error)
    }
}
