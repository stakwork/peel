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
        #expect(RecordingCaptions.fileName(at: date, calendar: calendar) == "Peel Segment 2026-10-28 at 14.03.07")
        #expect(RecordingCaptions.isRecordingName("Peel Segment 2026-10-28 at 14.03.07.mp4"))
        #expect(RecordingCaptions.isRecordingName("Peel Recording 2026-10-28 at 14.03.07.mp4"))
        #expect(RecordingCaptions.isRecordingName("Peel Segment 2026-10-28 at 14.03.07 2.mp4"))
        #expect(!RecordingCaptions.isRecordingName("Peel Segment 2026-10-28 at 14.03.07.mov"))
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

    @Test func withoutCaptionsTheCopyHasNoSubtitlesAndItsIndexFirst() async throws {
        let video = try await SyntheticVideo.make(at: temp("in.mp4"), seconds: 2)
        let out = temp("out.mp4")
        defer { try? FileManager.default.removeItem(at: video); try? FileManager.default.removeItem(at: out) }
        try await RecordingMedia.addCaptions([], to: video, writingTo: out)

        let asset = AVURLAsset(url: out)
        #expect(try await asset.loadTracks(withMediaType: .subtitle).isEmpty)
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        // The top-level boxes: the index (`moov`) before the media (`mdat`).
        let data = try Data(contentsOf: out)
        var boxes: [String] = []
        var at = 0
        while at + 8 <= data.count {
            var size = data[at..<(at + 4)].reduce(0) { $0 << 8 | Int($1) }
            boxes.append(String(decoding: data[(at + 4)..<(at + 8)], as: UTF8.self))
            // 1: the size is the 8 bytes after the name.
            if size == 1, at + 16 <= data.count { size = data[(at + 8)..<(at + 16)].reduce(0) { $0 << 8 | Int($1) } }
            guard size >= 8 else { break }
            at += size
        }
        let index = try #require(boxes.firstIndex(of: "moov"))
        let media = try #require(boxes.firstIndex(of: "mdat"))
        #expect(index < media)
    }

    @Test func aRecordingKeysEveryTenSecondsAndPlaysIfCutShort() async throws {
        let url = temp("rec.mp4")
        let cut = temp("cut.mp4")
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: cut) }
        let (width, height, fps) = (320, 180, 30)
        let file = try RecordingMedia.recordingWriter(at: url, width: width, height: height)
        let pixels = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: file.video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        #expect(file.writer.startWriting())
        file.writer.startSession(atSourceTime: .zero)
        // No sound here: a writer waiting for some would hold the picture back.
        file.audio.markAsFinished()
        // 22 s of a bar moving down the screen, fed as a live capture is.
        for frame in 0..<(22 * fps) {
            while !file.video.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            let pool = try #require(pixels.pixelBufferPool)
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            let pixel = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixel, [])
            let base = try #require(CVPixelBufferGetBaseAddress(pixel))
            let row = CVPixelBufferGetBytesPerRow(pixel)
            memset(base, 200, row * height)
            memset(base + row * (frame % (height - 10)), 20, row * 10)
            CVPixelBufferUnlockBaseAddress(pixel, [])
            #expect(pixels.append(pixel, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))))
            // What a crash at 15 s leaves: the file as it is on disk.
            if frame == 15 * fps { try FileManager.default.copyItem(at: url, to: cut) }
        }
        file.video.markAsFinished()
        await file.writer.finishWriting()
        #expect(file.writer.status == .completed)

        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let format = try #require(try await track.load(.formatDescriptions).first)
        #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_H264)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        #expect(reader.startReading())
        var keys: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
            if attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true { keys.append(sample.presentationTimeStamp.seconds) }
        }
        #expect(keys == [0, 10, 20])

        let left = AVURLAsset(url: cut)
        #expect(try await left.load(.isPlayable))
        // The fragments written by then: fed this fast, the encoder is a few
        // behind.
        #expect(try await left.load(.duration).seconds >= 2)
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

        let fps = 10
        var frame = 0
        let picture = Feed(video) {
            guard frame < seconds * fps, let pool = pixels.pixelBufferPool else { return false }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let pixel = buffer else { return false }
            CVPixelBufferLockBaseAddress(pixel, [])
            memset(CVPixelBufferGetBaseAddress(pixel), 128, CVPixelBufferGetDataSize(pixel))
            CVPixelBufferUnlockBaseAddress(pixel, [])
            pixels.append(pixel, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
            frame += 1
            return true
        }

        let rate = 44100
        let chunk = 1024
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(rate), channels: 1, interleaved: false))
        var description: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: format.streamDescription, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description)
        let tone = try #require(description)
        var sampleAt = 0
        let tune = Feed(audio) {
            guard sampleAt < seconds * rate else { return false }
            let start = sampleAt
            var samples = (0..<chunk).map { Float(sin(Double(start + $0) * 2 * .pi * 440 / Double(rate))) * 0.3 }
            let size = chunk * 4
            var block: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: size, blockAllocator: nil,
                                               customBlockSource: nil, offsetToData: 0, dataLength: size, flags: 0, blockBufferOut: &block)
            guard let block else { return false }
            CMBlockBufferReplaceDataBytes(with: &samples, blockBuffer: block, offsetIntoDestination: 0, dataLength: size)
            var sample: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: nil, dataBuffer: block, formatDescription: tone, sampleCount: chunk,
                presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(rate)),
                packetDescriptions: nil, sampleBufferOut: &sample
            )
            guard let sample else { return false }
            audio.append(sample)
            sampleAt += chunk
            return true
        }

        // Each track fed whenever it asks, on its own: an encoder that holds
        // frames back (a virtual Mac's, in CI) would stall feeding them in step.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await picture.run() }
            if sound { group.addTask { await tune.run() } }
        }
        await writer.finishWriting()
        #expect(writer.status == .completed)
        return url
    }

    /// One input fed from `next` (which appends one sample, or says there
    /// are no more) until it is done; `run` returns then.
    private final class Feed: @unchecked Sendable {
        private let input: AVAssetWriterInput
        private let next: () -> Bool
        private let queue = DispatchQueue(label: "peel.synthetic-video")

        init(_ input: AVAssetWriterInput, next: @escaping () -> Bool) {
            self.input = input
            self.next = next
        }

        func run() async {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                var finished = false
                input.requestMediaDataWhenReady(on: queue) { [self] in
                    while !finished, input.isReadyForMoreMediaData {
                        guard next() else {
                            finished = true
                            input.markAsFinished()
                            done.resume()
                            return
                        }
                    }
                }
            }
        }
    }
}

/// A pause leaves nothing in the file and no hole in its clock (docs/recording.md).
struct RecordingPausesTests {
    private func at(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }

    @Test func samplesBeforeAPauseKeepTheirTimes() throws {
        var pauses = RecordingPauses()
        let result = pauses.fileTime(of: at(5), after: at(4.9))
        let placed = try #require(result)
        #expect(placed.time == at(5))
        #expect(!placed.rejoined)
    }

    @Test func nothingIsWrittenWhilePaused() {
        var pauses = RecordingPauses()
        pauses.pause()
        let dropped = pauses.fileTime(of: at(6), after: at(5))
        #expect(dropped == nil)
    }

    @Test func theFileCarriesOnFromThePauseWithTimesAlwaysRising() throws {
        var pauses = RecordingPauses()
        pauses.pause()
        pauses.resume()
        _ = pauses.fileTime(of: at(125), after: at(5))
        let firstPlaced = pauses.fileTime(of: at(125.2), after: at(5))
        let first = try #require(firstPlaced)
        #expect(first.rejoined)
        #expect(first.time > at(5))
        #expect(first.time <= at(5.1))
        let nextPlaced = pauses.fileTime(of: at(126.2), after: first.time)
        let next = try #require(nextPlaced)
        #expect(!next.rejoined)
        #expect(next.time == first.time + at(1))
    }

    @Test func aSecondPauseIsTakenOutToo() throws {
        var pauses = RecordingPauses()
        pauses.pause()
        pauses.resume()
        _ = pauses.fileTime(of: at(100), after: at(5))
        let firstPlaced = pauses.fileTime(of: at(100.2), after: at(5))
        let first = try #require(firstPlaced)
        pauses.pause()
        pauses.resume()
        _ = pauses.fileTime(of: at(200), after: first.time)
        let secondPlaced = pauses.fileTime(of: at(200.2), after: first.time)
        let second = try #require(secondPlaced)
        #expect(second.time > first.time)
        #expect(second.time <= first.time + at(0.1))
    }

    @Test func theFirstMomentAfterResumeIsDropped() {
        var pauses = RecordingPauses()
        pauses.pause()
        pauses.resume()
        let first = pauses.fileTime(of: at(100), after: at(5))
        let inTheSettle = pauses.fileTime(of: at(100.1), after: at(5))
        #expect(first == nil)
        #expect(inTheSettle == nil)
    }

    @Test func aMovedSampleKeepsItsLengthAtTheNewTime() throws {
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: at(0.02), presentationTimeStamp: at(100), decodeTimeStamp: .invalid)
        CMSampleBufferCreate(
            allocator: nil, dataBuffer: nil, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: nil,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &sample)
        let original = try #require(sample)
        let moved = try #require(RecordingMedia.shifted(original, by: at(-95)))
        #expect(moved.presentationTimeStamp == at(5))
        #expect(moved.duration == at(0.02))
    }

    /// Real frames through the real writer, a two minute pause in the middle.
    @Test func aPausedRecordingWritesAFileWithoutTheGap() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("peel-pause-test-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try RecordingMedia.recordingWriter(at: url, width: 1280, height: 720)
        #expect(file.writer.startWriting())
        var pauses = RecordingPauses()
        var pixels: CVPixelBuffer?
        CVPixelBufferCreate(
            nil, 1280, 720, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels)
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: try #require(pixels), formatDescriptionOut: &format)
        var latest: CMTime?
        let arrivals = (0..<30).map { at(100 + Double($0) / 30) } + (0..<30).map { at(220 + Double($0) / 30) }
        for (index, time) in arrivals.enumerated() {
            if index == 30 {
                pauses.pause()
                pauses.resume()
            }
            guard let place = pauses.fileTime(of: time, after: latest) else { continue }
            if latest == nil {
                file.writer.startSession(atSourceTime: place.time)
                file.audio.markAsFinished()
            }
            var sample: CMSampleBuffer?
            var timing = CMSampleTimingInfo(duration: at(1.0 / 30), presentationTimeStamp: time, decodeTimeStamp: .invalid)
            CMSampleBufferCreateReadyWithImageBuffer(
                allocator: nil, imageBuffer: try #require(pixels), formatDescription: try #require(format),
                sampleTiming: &timing, sampleBufferOut: &sample)
            let original = try #require(sample)
            let moved = try #require(RecordingMedia.shifted(original, by: place.time - time))
            while !file.video.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            let appended = file.video.append(moved)
            #expect(appended, "\(String(describing: file.writer.error))")
            latest = place.time
        }
        file.video.markAsFinished()
        file.writer.endSession(atSourceTime: try #require(latest))
        await file.writer.finishWriting()
        #expect(file.writer.status == .completed)
        let seconds = try await AVURLAsset(url: url).load(.duration).seconds
        #expect(seconds > 1.7 && seconds < 2.1)
    }
}
