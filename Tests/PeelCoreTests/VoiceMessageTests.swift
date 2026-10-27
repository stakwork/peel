import Foundation
import Testing
@testable import PeelCore

struct VoiceMessageTests {
    @Test func audioTypesAreVoice() {
        #expect(VoiceMessage.isVoice(mediaType: "audio/wav"))
        #expect(VoiceMessage.isVoice(mediaType: "audio/mp4"))
        #expect(VoiceMessage.isVoice(mediaType: VoiceMessage.mediaType))
        #expect(!VoiceMessage.isVoice(mediaType: "image/jpg"))
        #expect(!VoiceMessage.isVoice(mediaType: nil))
    }

    @Test func aRecordingGoesUpAsAudioWav() {
        let wav = MediaInfoTests.wav()
        let file = OutgoingFile(name: "voice-123.wav", data: wav)
        #expect(file == OutgoingFile(fileName: "audio.wav", mediaType: "audio/wav"))
        #expect(file.field == "audio")
        // Not a WAV inside: a plain file.
        #expect(OutgoingFile(name: "x.wav", data: Data([1, 2, 3])).fileName == "x.wav")
    }

    @Test func releaseDecidesByTimeAndSlide() {
        #expect(VoiceMessage.outcome(elapsed: 3, dx: 0, dy: 0) == .send)
        #expect(VoiceMessage.outcome(elapsed: 0.4, dx: 0, dy: 0) == .tooShort)
        // A second exactly is dropped, as the Sphinx apps do; keeping needs more.
        #expect(VoiceMessage.outcome(elapsed: 1, dx: 0, dy: 0) == .tooShort)
        #expect(VoiceMessage.outcome(elapsed: 1.1, dx: 0, dy: 0) == .send)
        #expect(VoiceMessage.outcome(elapsed: 3, dx: -120, dy: 0) == .cancel)
        #expect(VoiceMessage.outcome(elapsed: 3, dx: 0, dy: -120) == .cancel)
        #expect(VoiceMessage.outcome(elapsed: 3, dx: 120, dy: 120) == .send)
        #expect(VoiceMessage.outcome(elapsed: 0.2, dx: -120, dy: 0) == .cancel)
    }

    @Test func clockAndLabels() {
        #expect(VoiceMessage.clock(7.9) == "0:07")
        #expect(VoiceMessage.clock(62) == "1:02")
        #expect(VoiceMessage.clock(-3) == "0:00")
        #expect(VoiceMessage.timeLabel(current: 7, total: 62) == "0:07 / 1:02")
        #expect(VoiceMessage.timeLabel(current: 7, total: nil) == "0:07")
    }

    @Test func progressAndSeek() {
        #expect(VoiceMessage.fraction(current: 5, total: 10) == 0.5)
        #expect(VoiceMessage.fraction(current: 15, total: 10) == 1)
        #expect(VoiceMessage.fraction(current: 5, total: 0) == 0)
        #expect(VoiceMessage.fraction(current: 5, total: nil) == 0)
        #expect(VoiceMessage.seekTime(x: 50, width: 200, total: 40) == 10)
        #expect(VoiceMessage.seekTime(x: -5, width: 200, total: 40) == 0)
        #expect(VoiceMessage.seekTime(x: 500, width: 200, total: 40) == 40)
        #expect(VoiceMessage.seekTime(x: 5, width: 0, total: 40) == 0)
    }

    @Test func recorderStateFollowsTheFinger() {
        var state = VoiceRecorderState()
        #expect(!state.isRecording)
        state.begin()
        #expect(state.phase == .recording)
        state.tick(elapsed: 4)
        #expect(state.clock == "0:04")
        state.drag(dx: -100, dy: 0)
        #expect(state.phase == .cancelling)
        state.drag(dx: -10, dy: 0)
        #expect(state.phase == .recording)
        let sent = state.finish(dx: -10, dy: 0)
        #expect(sent == .send)
        #expect(!state.isRecording)
        let again = state.finish(dx: 0, dy: 0)
        #expect(again == .cancel)
    }

    @Test func recorderStopsAtTheMaximum() {
        var state = VoiceRecorderState()
        state.begin()
        let early = state.tick(elapsed: 10)
        #expect(!early)
        let atLimit = state.tick(elapsed: VoiceMessage.maximumDuration + 2)
        #expect(atLimit)
        #expect(state.elapsed == VoiceMessage.maximumDuration)
        state.abort()
        #expect(state.elapsed == 0 && !state.isRecording)
    }

    @Test func audioTypesFromOtherClientsGetTheirExtension() {
        for type in ["audio/wav", "audio/x-wav", "audio/wave", "audio/vnd.wave", "AUDIO/WAV", "audio/wav; codecs=1"] {
            #expect(AttachmentKind.fileExtension(mediaType: type) == "wav")
            #expect(AttachmentKind(mediaType: type) == .audio)
        }
        #expect(AttachmentKind.fileExtension(mediaType: "audio/mpeg") == "mp3")
        #expect(AttachmentKind.fileExtension(mediaType: "audio/mp4") == "m4a")
        #expect(AttachmentKind.fileExtension(mediaType: "audio/x-m4a") == "m4a")
        #expect(AttachmentKind.fileExtension(mediaType: "audio/ogg") == "ogg")
        #expect(AttachmentKind.fallbackName(mediaType: "audio/vnd.wave") == "audio.wav")
    }

    @Test func aWavGoesUpAsAudioWavWhateverItsNameOrNone() {
        let wav = MediaInfoTests.wav()
        for name in ["recording.wav", "RECORDING.WAV", "voice", "voice.bin", ""] {
            #expect(OutgoingFile(name: name, data: wav) == OutgoingFile(fileName: "audio.wav", mediaType: "audio/wav"))
        }
    }

    @Test func wavHeadersOfTheSphinxAppsAreRead() throws {
        // Android's WavRecorder: 8 kHz mono 16-bit, one second.
        let android = try #require(WavHeader(Self.wav(rate: 8000, seconds: 1)))
        #expect(android.sampleRate == 8000 && android.channels == 1 && android.bitsPerSample == 16)
        #expect(android.duration == 1)
        // iOS's: 44.1 kHz mono, 2 seconds.
        #expect(try #require(WavHeader(Self.wav(rate: 44_100, seconds: 2))).duration == 2)
        // A header whose size was never fixed (zero, or all ones) reads what the file holds.
        var unfixed = Self.wav(rate: 8000, seconds: 3)
        unfixed.replaceSubrange(40..<44, with: [0, 0, 0, 0])
        #expect(WavHeader(unfixed)?.duration == 3)
        unfixed.replaceSubrange(40..<44, with: [0xFF, 0xFF, 0xFF, 0xFF])
        #expect(WavHeader(unfixed)?.duration == 3)
        #expect(WavHeader(Data("RIFF....WAVE".utf8)) == nil)
        #expect(WavHeader(Data([1, 2, 3])) == nil)
    }

    @Test func theRowShowsLoadingUntilItCanPlay() {
        typealias S = VoiceMessage
        #expect(S.rowState(uploading: true, hasFile: false, downloadFailed: false, loaded: false, unplayable: false) == .uploading)
        // Ours, uploading, with its file on disk: playable already.
        #expect(S.rowState(uploading: true, hasFile: true, downloadFailed: false, loaded: true, unplayable: false) == .ready)
        #expect(S.rowState(uploading: false, hasFile: false, downloadFailed: false, loaded: false, unplayable: false) == .loading)
        #expect(S.rowState(uploading: false, hasFile: true, downloadFailed: false, loaded: false, unplayable: false) == .loading)
        #expect(S.rowState(uploading: false, hasFile: false, downloadFailed: true, loaded: false, unplayable: false) == .failed)
        #expect(S.rowState(uploading: false, hasFile: true, downloadFailed: false, loaded: true, unplayable: true) == .failed)
        #expect(S.rowState(uploading: false, hasFile: true, downloadFailed: false, loaded: true, unplayable: false) == .ready)
    }

    /// A PCM WAV of silence, 16-bit mono.
    static func wav(rate: Int, seconds: Int) -> Data {
        func le(_ v: Int, _ n: Int) -> Data {
            var bytes: [UInt8] = []
            for i in 0..<n { bytes.append(UInt8(truncatingIfNeeded: v >> (8 * i))) }
            return Data(bytes)
        }
        let samples = Data(count: rate * 2 * seconds)
        var data = Data("RIFF".utf8)
        data.append(le(36 + samples.count, 4))
        data.append(Data("WAVEfmt ".utf8))
        data.append(le(16, 4))
        data.append(le(1, 2))
        data.append(le(1, 2))
        data.append(le(rate, 4))
        data.append(le(rate * 2, 4))
        data.append(le(2, 2))
        data.append(le(16, 2))
        data.append(Data("data".utf8))
        data.append(le(samples.count, 4))
        data.append(samples)
        return data
    }
}
