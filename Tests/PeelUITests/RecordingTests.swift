import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import PeelUI

/// A recording's words as captions (docs/recording.md).
struct RecordingCaptionsTests {
    private func words(_ spec: [(String, TimeInterval)]) -> [TimedWord] {
        spec.map { TimedWord(text: $0.0, start: $0.1) }
    }

    @Test func wordsRunTogetherUntilTheNextCue() {
        let cues = RecordingCaptions.cues(from: words([("Hello", 0.5), ("there.", 0.9), ("This", 1.6), ("is", 1.8), ("Peel", 2.0)]), duration: 10)
        #expect(cues == [
            CaptionCue(start: 0.5, end: 1.6, text: "Hello there."),
            CaptionCue(start: 1.6, end: 2.8, text: "This is Peel"),
        ])
    }

    @Test func aPauseEndsACueSoon() {
        let cues = RecordingCaptions.cues(from: words([("One", 0), ("two", 5)]), duration: 10)
        #expect(cues == [CaptionCue(start: 0, end: 0.8, text: "One"), CaptionCue(start: 5, end: 5.8, text: "two")])
    }

    @Test func aCueStaysOneLine() {
        let many = (0..<20).map { ("word\($0)", Double($0) * 0.2) }
        let cues = RecordingCaptions.cues(from: words(many), duration: 10)
        #expect(cues.count > 1)
        #expect(cues.allSatisfy { $0.text.count <= RecordingCaptions.maxCharacters })
        #expect(cues.map(\.text).joined(separator: " ") == many.map(\.0).joined(separator: " "))
    }

    @Test func noCueOutlastsTheRecording() {
        let cues = RecordingCaptions.cues(from: words([("Bye", 4.9)]), duration: 5)
        #expect(cues == [CaptionCue(start: 4.9, end: 5, text: "Bye")])
        #expect(RecordingCaptions.cues(from: words([("late", 5)]), duration: 5).isEmpty)
        #expect(RecordingCaptions.cues(from: [], duration: 5).isEmpty)
    }

    @Test func aLongRecordingIsCutAtItsPauses() {
        // 50 s of speech at 20 frames a second, quiet at 12 s and 30 s.
        var levels = [Float](repeating: 100, count: 1000)
        levels[240] = 1
        levels[600] = 1
        let pieces = RecordingCaptions.pieces(levels: levels, frame: 0.05)
        #expect(pieces == [0..<240, 240..<600, 600..<1000])
    }

    @Test func aPieceIsNeverLongerThanStrutCanFix() {
        // No pause at all: cut at the longest a piece may be, end to end.
        let pieces = RecordingCaptions.pieces(levels: [Float](repeating: 100, count: 1000), frame: 0.05)
        #expect(pieces.allSatisfy { $0.count <= 400 })
        #expect(pieces.first?.lowerBound == 0 && pieces.last?.upperBound == 1000)
        #expect(zip(pieces, pieces.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound })
    }

    @Test func aShortRecordingIsOnePiece() {
        #expect(RecordingCaptions.pieces(levels: [Float](repeating: 100, count: 300), frame: 0.05) == [0..<300])
    }

    @Test func theVocabularysWordsTakeTheHeardTimes() {
        let heard = words([("ask", 1), ("the", 1.2), ("stack", 1.4), ("work", 1.7), ("team", 2)])
        let timed = RecordingCaptions.retimed(heard, as: "Ask the Stakwork team.")
        #expect(timed == words([("Ask", 1), ("the", 1.2), ("Stakwork", 1.4), ("team.", 2)]))
    }

    @Test func wordsTheFixerAddsTakeTheTimeBeforeThem() {
        let heard = words([("send", 0.5), ("it", 0.9), ("now", 1.3)])
        #expect(RecordingCaptions.retimed(heard, as: "Send it over now.") ==
                words([("Send", 0.5), ("it", 0.9), ("over", 0.9), ("now.", 1.3)]))
        #expect(RecordingCaptions.retimed(heard, as: "") == heard)
        #expect(RecordingCaptions.retimed([], as: "Hello") == [])
    }

    @Test func fileName() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 14, minute: 3, second: 7)))
        #expect(RecordingCaptions.fileName(at: date, calendar: calendar) == "Peel Recording 2026-10-28 at 14.03.07")
        #expect(RecordingCaptions.isRecordingName("Peel Recording 2026-10-28 at 14.03.07.mp4"))
        #expect(RecordingCaptions.isRecordingName("Peel Recording 2026-10-28 at 14.03.07 2.mp4"))
        #expect(!RecordingCaptions.isRecordingName("Peel Recording 2026-10-28 at 14.03.07.mov"))
        #expect(!RecordingCaptions.isRecordingName("holiday.mp4"))
    }
}

/// The file's audio read out, and captions written in, on a made-up video.
@Suite(.timeLimit(.minutes(1)))
struct RecordingMediaTests {
    private func temp(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("peel-recording-test-\(UUID().uuidString)-\(name)")
    }

    @Test func audioComesOutAsDictationsWAV() async throws {
        let video = try await SyntheticVideo.make(at: temp("in.mp4"), seconds: 2)
        let wav = temp("out.wav")
        defer { try? FileManager.default.removeItem(at: video); try? FileManager.default.removeItem(at: wav) }
        let seconds = try await RecordingMedia.extractAudio(from: video, to: wav)
        #expect(abs(seconds - 2) < 0.1)
        let data = try Data(contentsOf: wav)
        #expect(data.prefix(4) == Data("RIFF".utf8))
        #expect(data.count == 44 + Int(seconds * 16000) * 2)
    }

    @Test func captionsBecomeASubtitleTrackBesideTheOriginals() async throws {
        let video = try await SyntheticVideo.make(at: temp("in.mp4"), seconds: 3)
        let out = temp("out.mp4")
        defer { try? FileManager.default.removeItem(at: video); try? FileManager.default.removeItem(at: out) }
        let cues = [CaptionCue(start: 0.5, end: 1.4, text: "Hello there."), CaptionCue(start: 1.6, end: 2.5, text: "This is Peel")]
        try await RecordingMedia.addCaptions(cues, to: video, writingTo: out)

        let asset = AVURLAsset(url: out)
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
        let subtitles = try await asset.loadTracks(withMediaType: .subtitle)
        let track = try #require(subtitles.first)
        #expect(try await track.load(.languageCode) == "eng")
        #expect(abs(try await asset.load(.duration).seconds - 3) < 0.1)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        #expect(reader.startReading())
        var texts: [String] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var bytes = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
            _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: &bytes)
            let length = Int(bytes[0]) << 8 | Int(bytes[1])
            texts.append(String(decoding: bytes[2..<(2 + length)], as: UTF8.self))
        }
        #expect(texts.filter { !$0.isEmpty } == ["Hello there.", "This is Peel"])
    }

    @Test func piecesStartWhereTheyAreInTheRecording() async throws {
        // 30 s of tone, silent from 15 s to 15.5 s.
        let wav = temp("in.wav")
        let folder = temp("pieces")
        defer { try? FileManager.default.removeItem(at: wav); try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let writer = try WAVFileWriter(url: wav, sampleRate: 16000)
        let pause = (15 * 16000)..<(31 * 8000)
        let samples: [Int16] = (0..<(30 * 16000)).map { at in
            if pause.contains(at) { return 0 }
            return at % 64 < 32 ? 3000 : -3000
        }
        try writer.append(samples)
        try writer.finish()

        let pieces = try await RecordingMedia.pieces(of: wav, in: folder)
        #expect(pieces.map(\.start) == [0, 15])
        let sizes = try pieces.map { try Data(contentsOf: $0.url).count - 44 }
        #expect(sizes == [15 * 16000 * 2, 15 * 16000 * 2])
    }

    @Test func aVideoWithoutSoundHasNoAudio() async throws {
        let video = try await SyntheticVideo.make(at: temp("in.mp4"), seconds: 1, sound: false)
        defer { try? FileManager.default.removeItem(at: video) }
        await #expect(throws: RecordingMedia.Failure.noAudio) {
            try await RecordingMedia.extractAudio(from: video, to: temp("out.wav"))
        }
    }
}

/// A small H.264 and AAC MP4: grey frames and a tone.
private enum SyntheticVideo {
    static func make(at url: URL, seconds: Int, sound: Bool = true) async throws -> URL {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
        ])
        let pixels = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 64,
            kCVPixelBufferHeightKey as String: 64,
        ])
        writer.add(video)
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000,
        ])
        if sound { writer.add(audio) }
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        // Picture and sound a frame at a time: a writer holds back one track
        // until the other catches up, so writing all of one first can stall.
        let fps = 10
        let rate = 44100
        let chunk = 1024
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(rate), channels: 1, interleaved: false))
        var description: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: format.streamDescription, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description)
        var sampleAt = 0
        for frame in 0..<(seconds * fps) {
            try await ready(video, of: writer)
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try #require(pixels.pixelBufferPool), &buffer)
            let pixel = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixel, [])
            memset(CVPixelBufferGetBaseAddress(pixel), 128, CVPixelBufferGetDataSize(pixel))
            CVPixelBufferUnlockBaseAddress(pixel, [])
            pixels.append(pixel, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
            guard sound else { continue }
            while sampleAt < (frame + 1) * rate / fps {
                try await ready(audio, of: writer)
                let start = sampleAt
                var samples = (0..<chunk).map { Float(sin(Double(start + $0) * 2 * .pi * 440 / Double(rate))) * 0.3 }
                var block: CMBlockBuffer?
                let size = chunk * 4
                CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: size, blockAllocator: nil,
                                                   customBlockSource: nil, offsetToData: 0, dataLength: size, flags: 0, blockBufferOut: &block)
                CMBlockBufferReplaceDataBytes(with: &samples, blockBuffer: block!, offsetIntoDestination: 0, dataLength: size)
                var sample: CMSampleBuffer?
                CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                    allocator: nil, dataBuffer: block!, formatDescription: description!, sampleCount: chunk,
                    presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(rate)),
                    packetDescriptions: nil, sampleBufferOut: &sample
                )
                audio.append(sample!)
                sampleAt += chunk
            }
        }
        video.markAsFinished()
        if sound { audio.markAsFinished() }
        await writer.finishWriting()
        #expect(writer.status == .completed)
        return url
    }

    /// Waits for `input` to take more, or throws once `writer` has failed or
    /// stalled: a failed writer is never ready again, and would wait for ever.
    private static func ready(_ input: AVAssetWriterInput, of writer: AVAssetWriter) async throws {
        let until = ContinuousClock.now + .seconds(10)
        while !input.isReadyForMoreMediaData {
            if writer.status == .failed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
            guard ContinuousClock.now < until else { throw CocoaError(.fileWriteUnknown) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
