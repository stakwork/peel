import AVFoundation
import CoreMedia
import Foundation
import Synchronization

/// What a finished recording's file goes through (docs/recording.md): its
/// audio read out for strut, and its captions written into it. Nothing is
/// re-encoded but that audio.
public enum RecordingMedia {
    public enum Failure: Error, Equatable { case noAudio, unreadable, unwritable }

    /// The recording's sound as 16 kHz mono PCM16 in a WAV at `wav`, as
    /// dictation sends it; its length in seconds.
    public static func extractAudio(from video: URL, to wav: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: video)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw Failure.noAudio }
        let rate = Int(DictationDefaults.sampleRate)
        return try await Task.detached {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            guard reader.canAdd(output) else { throw Failure.unreadable }
            reader.add(output)
            let writer = try WAVFileWriter(url: wav, sampleRate: rate)
            guard reader.startReading() else { writer.discard(); throw Failure.unreadable }
            do {
                while let buffer = output.copyNextSampleBuffer() {
                    guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
                    // The reader's own bytes, made contiguous only if they are not.
                    var contiguous: CMBlockBuffer?
                    guard CMBlockBufferCreateContiguous(
                        allocator: nil, sourceBuffer: block, blockAllocator: nil, customBlockSource: nil,
                        offsetToData: 0, dataLength: 0, flags: 0, blockBufferOut: &contiguous
                    ) == noErr, let contiguous else { throw Failure.unreadable }
                    var length = 0
                    var bytes: UnsafeMutablePointer<CChar>?
                    guard CMBlockBufferGetDataPointer(
                        contiguous, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &bytes
                    ) == noErr, let bytes else { throw Failure.unreadable }
                    try writer.append(UnsafeRawBufferPointer(start: bytes, count: length))
                }
                guard reader.status == .completed else { throw Failure.unreadable }
                try writer.finish()
            } catch {
                writer.discard()
                throw error
            }
            return writer.duration
        }.value
    }

    /// A copy of `video` at `destination` with `cues` as an English subtitle
    /// track (3GPP timed text, which QuickTime and AVPlayer show as
    /// captions); its picture and sound are copied as they are.
    public static func addCaptions(_ cues: [CaptionCue], to video: URL, writingTo destination: URL) async throws {
        let asset = AVURLAsset(url: video)
        let tracks = try await asset.loadTracks(withMediaType: .video) + asset.loadTracks(withMediaType: .audio)
        let duration = try await asset.load(.duration)
        var copies: [(AVAssetReaderTrackOutput, AVAssetWriterInput)] = []
        let reader = try AVAssetReader(asset: asset)
        try? FileManager.default.removeItem(at: destination)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        for track in tracks {
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            let hint = try await track.load(.formatDescriptions).first
            let input = AVAssetWriterInput(mediaType: track.mediaType, outputSettings: nil, sourceFormatHint: hint)
            input.expectsMediaDataInRealTime = false
            if track.mediaType == .video { input.transform = try await track.load(.preferredTransform) }
            guard reader.canAdd(output), writer.canAdd(input) else { throw Failure.unwritable }
            reader.add(output)
            writer.add(input)
            copies.append((output, input))
        }
        let format = try TimedText.format()
        let text = AVAssetWriterInput(mediaType: .subtitle, outputSettings: nil, sourceFormatHint: format)
        text.languageCode = "eng"
        text.extendedLanguageTag = "en"
        text.expectsMediaDataInRealTime = false
        guard writer.canAdd(text) else { throw Failure.unwritable }
        writer.add(text)
        let samples = try TimedText.samples(cues, until: duration, format: format)

        guard reader.startReading(), writer.startWriting() else { throw Failure.unwritable }
        writer.startSession(atSourceTime: .zero)
        let feeds = copies.map { output, input in Feed(input: input) { output.copyNextSampleBuffer() } }
            + [Feed(input: text, samples: samples)]
        await withTaskGroup(of: Void.self) { group in
            for feed in feeds { group.addTask { await feed.run() } }
            // A writer or reader that fails stops asking for data: the feeds
            // are let go, rather than waiting for it forever.
            let watched = Watched(reader: reader, writer: writer)
            group.addTask {
                while !feeds.allSatisfy(\.isDone) {
                    if watched.failed { return feeds.forEach { $0.giveUp() } }
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        }
        if writer.status != .failed { await writer.finishWriting() }
        guard writer.status == .completed, reader.status == .completed else {
            try? FileManager.default.removeItem(at: destination)
            throw Failure.unwritable
        }
    }
}

/// The reader and writer of a copy, read for whether either failed.
private struct Watched: @unchecked Sendable {
    let reader: AVAssetReader
    let writer: AVAssetWriter
    var failed: Bool { reader.status == .failed || writer.status == .failed }
}

/// One writer input fed until its source runs dry, on its own queue.
private final class Feed: @unchecked Sendable {
    private let input: AVAssetWriterInput
    private let next: () -> CMSampleBuffer?
    private let queue = DispatchQueue(label: "peel.recording.feed")
    /// Done (the input ran dry, or `giveUp`), and the `run` waiting for it,
    /// resumed once.
    private struct State {
        var done = false
        var waiting: CheckedContinuation<Void, Never>?
    }
    private let state = Mutex(State())
    var isDone: Bool { state.withLock { $0.done } }

    init(input: AVAssetWriterInput, next: @escaping () -> CMSampleBuffer?) {
        self.input = input
        self.next = next
    }

    convenience init(input: AVAssetWriterInput, samples: [CMSampleBuffer]) {
        var remaining = samples[...]
        self.init(input: input) { remaining.popFirst() }
    }

    func run() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let gaveUp = state.withLock { state in
                if !state.done { state.waiting = continuation }
                return state.done
            }
            if gaveUp { return continuation.resume() }
            input.requestMediaDataWhenReady(on: queue) { [self] in
                while input.isReadyForMoreMediaData, !isDone {
                    guard let buffer = next(), input.append(buffer) else {
                        input.markAsFinished()
                        return resume()
                    }
                }
            }
        }
    }

    /// The writer failed: stop waiting for it.
    func giveUp() { resume() }

    private func resume() {
        state.withLock { state in
            state.done = true
            state.waiting?.resume()
            state.waiting = nil
        }
    }
}

/// 3GPP timed text (`tx3g`), the subtitle format an MP4 carries: a sample
/// is the text's UTF-8 length, big-endian, then the text. Every moment has
/// a sample, empty between cues, as players expect.
private enum TimedText {
    static func format() throws -> CMFormatDescription {
        let extensions: [CFString: Any] = [
            kCMTextFormatDescriptionExtension_DisplayFlags: 0,
            kCMTextFormatDescriptionExtension_BackgroundColor: [
                kCMTextFormatDescriptionColor_Red: 0, kCMTextFormatDescriptionColor_Green: 0,
                kCMTextFormatDescriptionColor_Blue: 0, kCMTextFormatDescriptionColor_Alpha: 255,
            ],
            kCMTextFormatDescriptionExtension_DefaultTextBox: [
                kCMTextFormatDescriptionRect_Top: 0, kCMTextFormatDescriptionRect_Left: 0,
                kCMTextFormatDescriptionRect_Bottom: 0, kCMTextFormatDescriptionRect_Right: 0,
            ],
            kCMTextFormatDescriptionExtension_DefaultStyle: [
                kCMTextFormatDescriptionStyle_StartChar: 0, kCMTextFormatDescriptionStyle_EndChar: 0,
                kCMTextFormatDescriptionStyle_Font: 1, kCMTextFormatDescriptionStyle_FontFace: 0,
                kCMTextFormatDescriptionStyle_FontSize: 18,
                kCMTextFormatDescriptionStyle_ForegroundColor: [
                    kCMTextFormatDescriptionColor_Red: 255, kCMTextFormatDescriptionColor_Green: 255,
                    kCMTextFormatDescriptionColor_Blue: 255, kCMTextFormatDescriptionColor_Alpha: 255,
                ],
            ],
            kCMTextFormatDescriptionExtension_HorizontalJustification: 1,
            kCMTextFormatDescriptionExtension_VerticalJustification: -1,
            kCMTextFormatDescriptionExtension_FontTable: ["1": "Helvetica"],
        ]
        var format: CMFormatDescription?
        let status = CMFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, mediaType: kCMMediaType_Subtitle, mediaSubType: kCMSubtitleFormatType_3GText,
            extensions: extensions as CFDictionary, formatDescriptionOut: &format
        )
        guard status == noErr, let format else { throw RecordingMedia.Failure.unwritable }
        return format
    }

    /// The cues, with an empty sample in each gap, from zero to `until`.
    static func samples(_ cues: [CaptionCue], until: CMTime, format: CMFormatDescription) throws -> [CMSampleBuffer] {
        let end = max(until.seconds, cues.last?.end ?? 0)
        var spans: [(start: TimeInterval, end: TimeInterval, text: String)] = []
        var at: TimeInterval = 0
        for cue in cues where cue.end > at {
            let start = max(cue.start, at)
            if start > at { spans.append((at, start, "")) }
            spans.append((start, cue.end, cue.text))
            at = cue.end
        }
        if end > at { spans.append((at, end, "")) }
        return try spans.map { try sample($0.text, from: $0.start, to: $0.end, format: format) }
    }

    private static func sample(_ text: String, from start: TimeInterval, to end: TimeInterval, format: CMFormatDescription) throws -> CMSampleBuffer {
        let utf8 = Array(text.utf8)
        var bytes = withUnsafeBytes(of: UInt16(utf8.count).bigEndian) { Array($0) } + utf8
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: bytes.count, flags: 0, blockBufferOut: &block
        ) == noErr, let block,
            CMBlockBufferReplaceDataBytes(with: &bytes, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count) == noErr
        else { throw RecordingMedia.Failure.unwritable }
        let scale: CMTimeScale = 600
        var timing = CMSampleTimingInfo(
            duration: CMTime(seconds: end - start, preferredTimescale: scale),
            presentationTimeStamp: CMTime(seconds: start, preferredTimescale: scale), decodeTimeStamp: .invalid
        )
        var size = bytes.count
        var buffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &buffer
        ) == noErr, let buffer else { throw RecordingMedia.Failure.unwritable }
        return buffer
    }
}
