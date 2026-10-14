import AVFoundation
import Foundation
import Testing
@testable import PeelCore
@testable import PeelTestSupport

/// Video and audio read from files named as the cache names them: no extension.
struct MediaInfoTests {
    let profile = TempProfile()

    /// A second of silence: 8 kHz, mono, 16-bit WAV.
    static func wav(seconds: Int = 1) -> Data {
        let rate: UInt32 = 8000
        let samples = Data(count: Int(rate) * 2 * seconds)
        func le<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        var data = Data("RIFF".utf8) + le(UInt32(36 + samples.count)) + Data("WAVEfmt ".utf8)
        data += le(UInt32(16)) + le(UInt16(1)) + le(UInt16(1)) + le(rate) + le(rate * 2) + le(UInt16(2)) + le(UInt16(16))
        return data + Data("data".utf8) + le(UInt32(samples.count)) + samples
    }

    /// A two-second H.264 QuickTime movie of `width`×`height` grey frames,
    /// written to `file` (which may lack an extension).
    static func writeVideo(to file: URL, width: Int = 64, height: Int = 36, seconds: Int = 2) async throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = file.deletingLastPathComponent().appendingPathComponent("staging.mov")
        let writer = try AVAssetWriter(outputURL: staging, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let fps: Int32 = 10
        for frame in 0..<(seconds * Int(fps)) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try #require(adaptor.pixelBufferPool), &buffer)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), 128, CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
        try FileManager.default.moveItem(at: staging, to: file)
    }

    @Test func aVideoInTheCacheHasItsDurationSizeAndPoster() async throws {
        let file = profile.url.appendingPathComponent("0f3a9c")
        try await Self.writeVideo(to: file)
        let data = try Data(contentsOf: file)
        #expect(AttachmentKind.verified(data, declared: .video) == .video)
        #expect(AttachmentKind.container(data)?.mimeType == "video/quicktime")

        let info = try #require(await MediaInfo.load(file, posterPixels: 32))
        #expect(abs((info.duration ?? 0) - 2) < 0.2)
        #expect(info.size == CGSize(width: 64, height: 36))
        let poster = try #require(info.poster)
        #expect(max(poster.width, poster.height) <= 32)
    }

    @Test func audioInTheCacheHasItsDurationAndNoPicture() async throws {
        let file = profile.url.appendingPathComponent("7be2d1")
        try FileManager.default.createDirectory(at: profile.url, withIntermediateDirectories: true)
        try Self.wav().write(to: file)
        #expect(AttachmentKind.verified(Self.wav(), declared: .audio) == .audio)
        let info = try #require(await MediaInfo.load(file))
        #expect(abs((info.duration ?? 0) - 1) < 0.05)
        #expect(info.size == nil)
    }

    @Test func somethingElseIsNotPlayable() async throws {
        let file = profile.url.appendingPathComponent("aa")
        try FileManager.default.createDirectory(at: profile.url, withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho hi\n".utf8).write(to: file)
        #expect(await MediaInfo.load(file) == nil)
    }

    /// A large video waits for a click; once cached it shows whatever its size.
    @Test func aDownloadUpToALimitRefusesALargerFileUnlessCached() async throws {
        let storage = try profile.storage()
        try storage.set("memes.example.com", for: .memesHost)
        let engine = try testEngine(storage)
        let token = MediaToken.base64URLEncode(Data("memes.example.com".utf8)) + ".muid1.AA.AA.AA.sig"
        var message = Message.fixture(
            type: MessageType.attachment,
            body: #"{"content":"","mediaKey":"k1","mediaType":"video/mov","mediaToken":"\#(token)"}"#, content: ""
        )
        message.mediaType = "video/mov"
        message.fileSize = 30_000_000
        let id = try #require(try storage.apply(Storage.Commit(messages: [(message, false, nil)])).stored.first?.id)

        await #expect(throws: Engine.Failure.largeAttachment(size: 30_000_000)) {
            try await engine.downloadAttachment(messageID: id, upTo: Engine.autoDownloadLimit)
        }
        let file = profile.url.appendingPathComponent("video")
        try await Self.writeVideo(to: file)
        _ = try MediaStore(profile: storage.directory).store(Data(contentsOf: file), muid: "muid1", key: "k1", limit: 1_000_000)
        let cached = try await engine.downloadAttachment(messageID: id, upTo: Engine.autoDownloadLimit)
        #expect(cached.cached && cached.kind == .video)
        // Unnamed by the server, it saves as the Mac app names its videos.
        #expect(cached.fileName == "video.mov")
    }

    @Test(arguments: [
        ([0, 0, 0, 0x14] + Array("ftypqt  ".utf8), "video/quicktime"),
        ([0, 0, 0, 0x18] + Array("ftypmp42".utf8), "video/mp4"),
        ([0, 0, 0, 0x18] + Array("ftypM4A ".utf8), "audio/mp4"),
        (Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WAVE".utf8), "audio/wav"),
        (Array("ID3".utf8) + [4, 0, 0, 0, 0, 0, 0, 0, 0], "audio/mpeg"),
        ([0xFF, 0xFB, 0x90, 0x64], "audio/mpeg"),
        ([0xFF, 0xF1, 0x50, 0x80], "audio/aac"),
        (Array("RIFF".utf8) + [0, 0, 0, 0] + Array("AVI ".utf8), nil),
        (Array("MZ\u{90}\u{0}".utf8), nil),
    ] as [([UInt8], String?)])
    func containersAreNamedFromTheirFirstBytes(head: [UInt8], type: String?) {
        #expect(AttachmentKind.container(Data(head))?.mimeType == type)
    }

    @Test(arguments: [(0.0, "0:00"), (7.9, "0:07"), (65, "1:05"), (750, "12:30"), (3723, "1:02:03"), (-3, "0:00")])
    func durationsReadAsAClock(seconds: TimeInterval, text: String) {
        #expect(MediaInfo.format(duration: seconds) == text)
    }

    @Test func namesFollowTheMacApp() {
        #expect(AttachmentKind.fallbackName(mediaType: "video/mov") == "video.mov")
        #expect(AttachmentKind.fallbackName(mediaType: "video/mp4") == "video.mp4")
        #expect(AttachmentKind.fallbackName(mediaType: "audio/wav") == "audio.wav")
        #expect(AttachmentKind.fallbackName(mediaType: "audio/x-m4a") == "audio.m4a")
        #expect(AttachmentKind.fallbackName(mediaType: "application/zip") == nil)
        #expect(AttachmentKind.fileExtension(mediaType: "video/mov") == "mov")
        #expect(AttachmentKind.fileExtension(mediaType: "application/pdf") == "pdf")
        #expect(AttachmentKind.fileExtension(mediaType: "video") == nil)
    }
}
