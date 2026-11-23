import Foundation

/// Why a video could not be made small enough to send.
public enum CompressionError: Error, Equatable, CustomStringConvertible, Sendable {
    /// Even at the lowest worthwhile bitrate (`Engine.compressionFloorBitrate`)
    /// its length would not fit `Engine.compressionTarget`.
    case tooLong(minutes: Int)
    /// The file has no video track, or none that can be read.
    case unreadable
    /// The encoder failed, in its own words.
    case failed(String)

    public var description: String {
        switch self {
        case .tooLong(let minutes):
            String(localized: "this video is too long to compress for sending (\(minutes) min); trim it or send a shorter one", table: "Shared")
        case .unreadable:
            String(localized: "this video could not be read to compress it", table: "Shared")
        case .failed(let reason):
            String(localized: "the video could not be compressed: \(reason)", table: "Shared")
        }
    }
}

/// The arithmetic of compressing a video to fit: what bitrate the length
/// allows, which resolution that bitrate can carry, and the output's even
/// dimensions. Pure, so tested without a video.
public enum VideoCompression {
    /// The audio's rate, AAC mono.
    public static let audioBitrate = 128_000

    /// What the encoder is asked for.
    public struct Plan: Equatable, Sendable {
        /// Bits per second for the video track.
        public var videoBitrate: Int
        /// The output's dimensions, as displayed (the transform applied), both even.
        public var width: Int
        public var height: Int
    }

    /// The video bitrate that makes `duration` seconds fit `target` bytes
    /// beside the audio: `target * 8 / duration - audioBitrate`. Zero or
    /// negative for a very long video. An unknown duration (zero or less)
    /// gives a huge one, so only the tier's cap limits it.
    public static func videoBitrate(duration: Double, target: Int = Engine.compressionTarget) -> Int {
        guard duration > 0 else { return Int.max / 2 }
        return Int(Double(target) * 8 / duration) - audioBitrate
    }

    /// The largest box (long side, short side) a bitrate carries: at least
    /// 6.5 Mbps 1920×1080, 2.5 Mbps 1280×720, 750 kbps 854×480, else 640×360.
    public static func tier(forBitrate bitrate: Int) -> (long: Int, short: Int) {
        switch bitrate {
        case 6_500_000...: (1920, 1080)
        case 2_500_000...: (1280, 720)
        case 750_000...: (854, 480)
        default: (640, 360)
        }
    }

    /// `width`×`height` (as displayed, so a portrait video is taller than
    /// wide) fitted into the tier's box either way round, never enlarged,
    /// the aspect kept, each side even (H.264 needs it) and at least 2.
    public static func dimensions(width: Int, height: Int, bitrate: Int) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (2, 2) }
        let box = tier(forBitrate: bitrate)
        let (long, short) = (max(width, height), min(width, height))
        let scale = min(1, Double(box.long) / Double(long), Double(box.short) / Double(short))
        func even(_ value: Double) -> Int { max(2, Int((value / 2).rounded()) * 2) }
        return (even(Double(width) * scale), even(Double(height) * scale))
    }

    /// The plan for a video of `duration` seconds displayed `width`×`height`,
    /// or `tooLong` when the bitrate falls under `floor`.
    public static func plan(
        duration: Double, width: Int, height: Int,
        target: Int = Engine.compressionTarget, floor: Int = Engine.compressionFloorBitrate
    ) throws -> Plan {
        let bitrate = videoBitrate(duration: duration, target: target)
        guard bitrate >= floor else { throw CompressionError.tooLong(minutes: Int((duration / 60).rounded(.up))) }
        let size = dimensions(width: width, height: height, bitrate: bitrate)
        return Plan(videoBitrate: bitrate, width: size.width, height: size.height)
    }
}

#if canImport(AVFoundation)
import AVFoundation
import UniformTypeIdentifiers

/// Compresses a video to H.264 and mono AAC in an .mp4 that fits
/// `Engine.sendLimit`, with `AVAssetReader` and `AVAssetWriter`. The source
/// is only read; the copy goes where it is told, and a failure or a
/// cancel removes it.
public enum VideoCompressor {
    /// Whether `file` is a video over `Engine.sendLimit`: the only kind
    /// compressed (a larger file of any other kind is refused as before).
    public static func needsCompression(_ file: URL) -> Bool {
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size > Engine.sendLimit else { return false }
        return UTType(filenameExtension: file.pathExtension)?.conforms(to: .movie) == true
    }

    /// A new .mp4 path in a folder of Peel's (`IncomingFiles`), so it is
    /// deleted by the same rules as any file of ours, named after the source.
    public static func outputURL(for source: URL) throws -> URL {
        let name = (source.lastPathComponent as NSString).deletingPathExtension
        return try IncomingFiles.newFolder().appendingPathComponent("\(name.isEmpty ? "Video" : name).mp4")
    }

    /// Writes the compressed copy of `source` to `destination` and reports
    /// progress in 0...1 (from a background queue). Cancelling the task
    /// stops it. Throws `CompressionError` or `CancellationError`;
    /// `destination` does not exist after either.
    public static func compress(
        _ source: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try? FileManager.default.removeItem(at: destination)
        let job = Job()
        do {
            try await withTaskCancellationHandler {
                try await job.run(source: source, destination: destination, progress: progress)
            } onCancel: {
                job.cancel()
            }
            try Task.checkCancellation()
            // Whatever the rate control overshot is still refused here.
            try Engine.checkSendable(destination)
            progress(1)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    /// Wraps a non-Sendable AVFoundation object used on its own queue.
    private struct Unsafe<T>: @unchecked Sendable { let value: T }

    /// One run's reader and writer. `cancel` may come from any thread:
    /// AVFoundation allows `cancelReading` and `cancelWriting` from any.
    private final class Job: @unchecked Sendable {
        private let lock = NSLock()
        private var reader: AVAssetReader?
        private var writer: AVAssetWriter?
        private var cancelled = false

        func cancel() {
            lock.lock()
            cancelled = true
            let (reader, writer) = (reader, writer)
            lock.unlock()
            reader?.cancelReading()
            writer?.cancelWriting()
        }

        private func hold(_ reader: AVAssetReader, _ writer: AVAssetWriter) throws {
            lock.lock()
            defer { lock.unlock() }
            if cancelled { throw CancellationError() }
            self.reader = reader
            self.writer = writer
        }

        func run(source: URL, destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
            let asset = AVURLAsset(url: source)
            let duration: CMTime
            let tracks: [AVAssetTrack]
            let audioTracks: [AVAssetTrack]
            do {
                duration = try await asset.load(.duration)
                tracks = try await asset.loadTracks(withMediaType: .video)
                audioTracks = try await asset.loadTracks(withMediaType: .audio)
            } catch {
                throw CompressionError.unreadable
            }
            guard let video = tracks.first, duration.seconds.isFinite, duration.seconds > 0 else {
                throw CompressionError.unreadable
            }
            let (natural, transform, frameRate) = try await video.load(.naturalSize, .preferredTransform, .nominalFrameRate)
            let shown = natural.applying(transform)
            let (shownWidth, shownHeight) = (abs(shown.width), abs(shown.height))
            let plan = try VideoCompression.plan(
                duration: duration.seconds, width: Int(shownWidth.rounded()), height: Int(shownHeight.rounded())
            )

            let reader = try AVAssetReader(asset: asset)
            let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
            writer.shouldOptimizeForNetworkUse = true
            try hold(reader, writer)

            // The video: decoded through a composition that applies the
            // orientation and the scale in one step.
            let composition = AVMutableVideoComposition()
            composition.renderSize = CGSize(width: plan.width, height: plan.height)
            let rate = frameRate > 0 ? min(frameRate, 30) : 30
            composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(rate.rounded()))
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: video)
            layer.setTransform(
                transform.concatenating(CGAffineTransform(
                    scaleX: CGFloat(plan.width) / max(shownWidth, 1), y: CGFloat(plan.height) / max(shownHeight, 1)
                )),
                at: .zero
            )
            instruction.layerInstructions = [layer]
            composition.instructions = [instruction]
            let videoOut = AVAssetReaderVideoCompositionOutput(videoTracks: [video], videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            ])
            videoOut.videoComposition = composition
            guard reader.canAdd(videoOut) else { throw CompressionError.unreadable }
            reader.add(videoOut)
            let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: plan.width,
                AVVideoHeightKey: plan.height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: plan.videoBitrate,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoMaxKeyFrameIntervalDurationKey: 2,
                ] as [String: Any],
            ])
            videoIn.expectsMediaDataInRealTime = false
            guard writer.canAdd(videoIn) else { throw CompressionError.failed("the encoder refused the video settings") }
            writer.add(videoIn)

            // The audio, if any: down to mono and 44.1 kHz, then AAC at 128 kbps.
            var audio: (output: AVAssetReaderTrackOutput, input: AVAssetWriterInput)?
            if let track = audioTracks.first {
                let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                    AVNumberOfChannelsKey: 1,
                    AVSampleRateKey: 44_100,
                ])
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVNumberOfChannelsKey: 1,
                    AVSampleRateKey: 44_100,
                    AVEncoderBitRateKey: VideoCompression.audioBitrate,
                ])
                input.expectsMediaDataInRealTime = false
                if reader.canAdd(out), writer.canAdd(input) {
                    reader.add(out)
                    writer.add(input)
                    audio = (out, input)
                }
            }

            guard reader.startReading() else { throw failure(reader.error, "could not start reading") }
            guard writer.startWriting() else { throw failure(writer.error, "could not start writing") }
            writer.startSession(atSourceTime: .zero)

            let total = duration.seconds
            let videoPair = (Unsafe(value: videoOut as AVAssetReaderOutput), Unsafe(value: videoIn))
            let audioPair = audio.map { (Unsafe(value: $0.output as AVAssetReaderOutput), Unsafe(value: $0.input)) }
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await Self.pump(videoPair.0, videoPair.1, queue: DispatchQueue(label: "peel.compress.video")) { time in
                        // The video is nearly all the work; the last step is the file's close.
                        progress(min(max(time.seconds / total, 0), 1) * 0.99)
                    }
                }
                if let audioPair {
                    group.addTask {
                        await Self.pump(audioPair.0, audioPair.1, queue: DispatchQueue(label: "peel.compress.audio"), onSample: nil)
                    }
                }
            }

            if Task.isCancelled { cancel(); throw CancellationError() }
            guard reader.status != .failed else { throw failure(reader.error, "reading failed") }
            await writer.finishWriting()
            guard writer.status == .completed else {
                if writer.status == .cancelled { throw CancellationError() }
                throw failure(writer.error, "writing failed")
            }
        }

        private func failure(_ error: (any Error)?, _ fallback: String) -> CompressionError {
            .failed(error.map { PeelError.readable($0) } ?? fallback)
        }

        /// Feeds every sample from `output` to `input` on `queue`, returning
        /// when the output ends, the input fails or the reader is cancelled.
        fileprivate static func pump(
            _ output: Unsafe<AVAssetReaderOutput>, _ input: Unsafe<AVAssetWriterInput>, queue: DispatchQueue,
            onSample: (@Sendable (CMTime) -> Void)?
        ) async {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                input.value.requestMediaDataWhenReady(on: queue) {
                    while input.value.isReadyForMoreMediaData {
                        guard let sample = output.value.copyNextSampleBuffer(), input.value.append(sample) else {
                            input.value.markAsFinished()
                            done.resume()
                            return
                        }
                        onSample?(CMSampleBufferGetPresentationTimeStamp(sample))
                    }
                }
            }
        }
    }
}
#endif
