import Foundation
import Testing
@testable import PeelCore
#if canImport(AVFoundation)
import AVFoundation
@testable import PeelTestSupport
#endif

/// The arithmetic of compressing a video to fit the send limit.
struct VideoCompressionTests {
    @Test func theLimitsAgree() {
        #expect(Engine.sendLimit == 100_000_000)
        #expect(Engine.sendLimit <= Engine.attachmentLimit)
        #expect(Engine.compressionTarget < Engine.sendLimit)
    }

    @Test func bitrateIsTheTargetOverTheLengthLessTheAudio() {
        let target = 95 * 1024 * 1024
        #expect(VideoCompression.videoBitrate(duration: 600) == target * 8 / 600 - 128_000)
        #expect(VideoCompression.videoBitrate(duration: 600, target: 1_000_000) == 1_000_000 * 8 / 600 - 128_000)
        #expect(VideoCompression.videoBitrate(duration: 0) > 100_000_000)
    }

    @Test func tiersChangeAtTheirBitrates() {
        func box(_ bitrate: Int) -> [Int] { let tier = VideoCompression.tier(forBitrate: bitrate); return [tier.long, tier.short] }
        #expect(box(6_500_000) == [1920, 1080])
        #expect(box(6_499_999) == [1280, 720])
        #expect(box(2_500_000) == [1280, 720])
        #expect(box(2_499_999) == [854, 480])
        #expect(box(750_000) == [854, 480])
        #expect(box(749_999) == [640, 360])
        #expect(box(-5) == [640, 360])
    }

    @Test func dimensionsKeepTheAspectAreEvenAndNeverGrow() {
        // Larger than the box: scaled down to it.
        #expect(VideoCompression.dimensions(width: 3840, height: 2160, bitrate: 7_000_000) == (1920, 1080))
        #expect(VideoCompression.dimensions(width: 3840, height: 2160, bitrate: 1_000_000) == (854, 480))
        // Portrait fits the same box turned.
        #expect(VideoCompression.dimensions(width: 2160, height: 3840, bitrate: 3_000_000) == (720, 1280))
        // Smaller than the box: left alone.
        #expect(VideoCompression.dimensions(width: 640, height: 360, bitrate: 9_000_000) == (640, 360))
        // Odd results are made even; the aspect stays near.
        let odd = VideoCompression.dimensions(width: 1001, height: 563, bitrate: 1_000_000)
        #expect(odd.width % 2 == 0 && odd.height % 2 == 0)
        #expect(abs(Double(odd.width) / Double(odd.height) - 1001.0 / 563.0) < 0.05)
        #expect(odd.width <= 854 && odd.height <= 480)
        // Nothing sensible to scale.
        #expect(VideoCompression.dimensions(width: 0, height: 10, bitrate: 1_000_000) == (2, 2))
    }

    @Test func aPlanIsRefusedUnderTheFloor() throws {
        let plan = try VideoCompression.plan(duration: 300, width: 1920, height: 1080)
        #expect(plan.videoBitrate == VideoCompression.videoBitrate(duration: 300))
        #expect((plan.width, plan.height) == (1280, 720))
        // About 21 minutes is as long as the floor allows.
        _ = try VideoCompression.plan(duration: 1200, width: 1920, height: 1080)
        #expect(throws: CompressionError.tooLong(minutes: 25)) {
            try VideoCompression.plan(duration: 1500, width: 1920, height: 1080)
        }
        // The floor is a parameter.
        _ = try VideoCompression.plan(duration: 1500, width: 1920, height: 1080, floor: 300_000)
        #expect(CompressionError.tooLong(minutes: 25).description.contains("25"))
    }

    #if canImport(AVFoundation)
    /// A real encode of a small video: an .mp4 of the same size, the source untouched.
    @Test func compressesToAnMP4AndLeavesTheSource() async throws {
        let profile = TempProfile()
        let source = profile.url.appendingPathComponent("clip/source.mov")
        try await MediaInfoTests.writeVideo(to: source)
        let before = try Data(contentsOf: source)
        let output = profile.url.appendingPathComponent("out.mp4")
        try await VideoCompressor.compress(source, to: output) { _ in }
        #expect(FileManager.default.fileExists(atPath: output.path))
        let track = try #require(try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(Int(size.width) == 64 && Int(size.height) == 36)
        #expect(try Data(contentsOf: source) == before)
    }

    @Test func aCancelledCompressionLeavesNoFile() async throws {
        let profile = TempProfile()
        let source = profile.url.appendingPathComponent("clip/source.mov")
        try await MediaInfoTests.writeVideo(to: source)
        let output = profile.url.appendingPathComponent("out.mp4")
        let task = Task { try await VideoCompressor.compress(source, to: output) { _ in } }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }
    #endif
}
