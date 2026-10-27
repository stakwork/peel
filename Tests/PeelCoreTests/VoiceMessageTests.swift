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
        #expect(state.finish(dx: -10, dy: 0) == .send)
        #expect(!state.isRecording)
        #expect(state.finish(dx: 0, dy: 0) == .cancel)
    }

    @Test func recorderStopsAtTheMaximum() {
        var state = VoiceRecorderState()
        state.begin()
        #expect(!state.tick(elapsed: 10))
        #expect(state.tick(elapsed: VoiceMessage.maximumDuration + 2))
        #expect(state.elapsed == VoiceMessage.maximumDuration)
        state.abort()
        #expect(state.elapsed == 0 && !state.isRecording)
    }
}
