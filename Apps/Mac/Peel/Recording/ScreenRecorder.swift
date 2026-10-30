import AVFoundation
import CoreMedia
import os
@preconcurrency import ScreenCaptureKit
import Synchronization
import PeelUI

/// A display, its cursor and the microphone, written to an MP4 by Peel's
/// own writer (`RecordingMedia.recordingWriter`, docs/recording.md). The
/// display comes from macOS's picker (`ScreenShare.pick`), so Peel holds no
/// standing Screen Recording permission. Peel's own windows are in it, as
/// anything else on the display is (a recording of Peel itself); only the
/// recording's bar never is.
///
/// The mic is the default input at Record, for the whole recording. A mic
/// that drops mid-recording is only noticed (`micSilence`).
@MainActor
final class ScreenRecorder {
    private let stream: SCStream
    private let delegate: RecorderDelegate

    /// The longest side recorded: sharp text, a file that fits an attachment.
    private static let maxSide: CGFloat = 1920
    private static let fps: Int32 = 30

    private init(stream: SCStream, delegate: RecorderDelegate) {
        self.stream = stream
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
        // The input itself, as dictation learned: one following the default
        // can be left deaf by a call's voice processing.
        let mic = AVCaptureDevice.default(for: .audio)?.uniqueID
        configuration.captureMicrophone = mic != nil
        configuration.microphoneCaptureDeviceID = mic

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("peel-recording-\(UUID().uuidString).mp4")
        let file = try RecordingMedia.recordingWriter(at: url, width: configuration.width, height: configuration.height)
        let delegate = RecorderDelegate(writer: file.writer, video: file.video, audio: file.audio) { error in
            Task { @MainActor in ended(url, error) }
        }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: delegate)
        do {
            guard file.writer.startWriting() else { throw file.writer.error ?? RecordingMedia.Failure.unwritable }
            // No mic on this Mac: the writer would otherwise hold the
            // picture back waiting for sound.
            if mic == nil { file.audio.markAsFinished() }
            try stream.addStreamOutput(delegate, type: .screen, sampleHandlerQueue: delegate.queue)
            try stream.addStreamOutput(delegate, type: .microphone, sampleHandlerQueue: delegate.queue)
            try await stream.startCapture()
        } catch {
            // Nothing for `ended` to report: this throws instead.
            delegate.abandon()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return ScreenRecorder(stream: stream, delegate: delegate)
    }

    var duration: TimeInterval { delegate.duration }

    /// How long the mic has sent nothing but zeros: a live mic always
    /// hears something, so this is a mic gone, not a quiet room.
    var micSilence: TimeInterval { delegate.micSilence }

    /// Ends the recording; `ended` follows once the file is finished.
    func stop() async {
        // Already stopped (macOS's Stop came first) is no failure: what was
        // written is finished either way.
        try? await stream.stopCapture()
        delegate.finish(nil)
    }
}

/// The stream's delegate, writing its frames and sound, on its queue.
private final class RecorderDelegate: NSObject, SCStreamDelegate, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "peel.screen-recording")
    // The writer and its inputs are only touched on `queue`.
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput
    private let ended: @Sendable ((any Error)?) -> Void
    private let log = Logger(subsystem: "dev.peel.mac", category: "recording")

    private struct State {
        var done = false
        /// The first frame's time, where the file starts, and the latest
        /// time heard from the stream, frame or sound.
        var start: CMTime?
        var latest: CMTime?
        var micSeen = false
    }
    private let state = Mutex(State())
    /// When the mic last sent anything but zeros.
    private let lastSound = Mutex(ContinuousClock.now)

    init(writer: AVAssetWriter, video: AVAssetWriterInput, audio: AVAssetWriterInput, ended: @escaping @Sendable ((any Error)?) -> Void) {
        self.writer = writer
        self.video = video
        self.audio = audio
        self.ended = ended
    }

    var duration: TimeInterval {
        state.withLock { state in
            guard let start = state.start, let latest = state.latest else { return 0 }
            return max(0, (latest - start).seconds)
        }
    }

    var micSilence: TimeInterval {
        let quiet = lastSound.withLock { $0 }.duration(to: .now).components
        return Double(quiet.seconds) + Double(quiet.attoseconds) / 1e18
    }

    /// True the first time only: whoever claims it ends the file.
    private func claim() -> Bool {
        state.withLock { state in
            defer { state.done = true }
            return !state.done
        }
    }

    /// The capture failed to start: the writer let go, nothing reported.
    func abandon() {
        queue.async { [self] in
            if claim() { writer.cancelWriting() }
        }
    }

    /// Once only: the file finished with what was written, then `ended`,
    /// with `error` if the capture failed but the file is whole.
    func finish(_ error: (any Error)?) {
        queue.async { [self] in
            guard claim() else { return }
            let (start, latest) = state.withLock { ($0.start, $0.latest) }
            guard let start else {
                // Not one frame: no file.
                writer.cancelWriting()
                return ended(error ?? RecordingMedia.Failure.unwritable)
            }
            video.markAsFinished()
            audio.markAsFinished()
            writer.endSession(atSourceTime: max(start, latest ?? start))
            writer.finishWriting { [self] in
                ended(writer.status == .completed ? nil : writer.error ?? error ?? RecordingMedia.Failure.unwritable)
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        let time = sampleBuffer.presentationTimeStamp
        guard time.isValid else { return }
        switch type {
        case .screen:
            // A frame unchanged since the last (`idle`) has no picture, but
            // its time still counts.
            let complete = Self.status(of: sampleBuffer) == .complete
            let started = state.withLock { state -> Bool in
                guard !state.done else { return false }
                if state.start == nil, complete {
                    state.start = time
                    writer.startSession(atSourceTime: time)
                }
                if state.start != nil { state.latest = max(state.latest ?? time, time) }
                return state.start != nil
            }
            if started, complete, video.isReadyForMoreMediaData { video.append(sampleBuffer) }
        case .microphone:
            hear(sampleBuffer)
            let started = state.withLock { state -> Bool in
                guard !state.done, let start = state.start else { return false }
                state.latest = max(state.latest ?? time, time)
                // The mic and the frames on one clock, or the voice drifts
                // off the picture: the first of each, for checking.
                if !state.micSeen {
                    state.micSeen = true
                    log.info("recording clocks: first frame \(start.seconds, privacy: .public) s, first mic \(time.seconds, privacy: .public) s")
                }
                return true
            }
            // Sound from before the first frame is dropped by the writer.
            if started, audio.isReadyForMoreMediaData { audio.append(sampleBuffer) }
        default:
            return
        }
        if writer.status == .failed {
            // The disk filled, or the encoder gave up: the capture ended,
            // keeping what the fragments hold.
            log.error("recording writer failed: \(String(describing: self.writer.error), privacy: .public)")
            stream.stopCapture { _ in }
            finish(writer.error)
        }
    }

    private static func status(of sample: CMSampleBuffer) -> SCFrameStatus? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int else { return nil }
        return SCFrameStatus(rawValue: raw)
    }

    /// The mic's sound read for whether it is there at all.
    private func hear(_ sampleBuffer: CMSampleBuffer) {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var bytes: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &length, totalLengthOut: nil, dataPointerOut: &bytes) == noErr,
              let bytes else { return }
        // Zero is zero in every sample format.
        if UnsafeRawBufferPointer(start: bytes, count: length).contains(where: { $0 != 0 }) {
            lastSound.withLock { $0 = .now }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        // macOS ended the capture (the menu bar's Stop, the display gone):
        // what was written is kept.
        finish(error)
    }
}
