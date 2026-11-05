import Foundation
import Testing
@testable import PeelUI

/// Voice mode's transitions (`VoiceMachine`), with no audio and no model.
struct VoiceModeStateTests {
    private func started() -> VoiceMachine {
        var machine = VoiceMachine()
        _ = machine.apply(.start)
        return machine
    }

    @Test func startListensAndEndsOnStop() {
        var machine = VoiceMachine()
        #expect(machine.apply(.start) == [.begin])
        #expect(machine.phase == .listening)
        #expect(machine.apply(.start) == [])
        #expect(machine.apply(.stop) == [.end])
        #expect(machine.phase == .idle)
        #expect(machine.apply(.stop) == [])
    }

    @Test func transcriptMakesADraftAndSilenceSendsIt() {
        var machine = started()
        _ = machine.apply(.transcript("add a screen"))
        #expect(machine.phase == .hearing)
        #expect(machine.apply(.silence) == [.send("add a screen")])
        #expect(machine.phase == .sending)
        #expect(machine.apply(.sendFinished(sent: true)) == [])
        #expect(machine.phase == .waiting)
        #expect(machine.draft == "")
    }

    @Test func sendCommandNeedsADraft() {
        var machine = started()
        #expect(machine.apply(.command(.send)) == [])
        #expect(machine.phase == .listening)
        _ = machine.apply(.transcript("hello"))
        #expect(machine.apply(.command(.send)) == [.send("hello")])
    }

    @Test func aFailedSendKeepsTheDraft() {
        var machine = started()
        _ = machine.apply(.transcript("hello"))
        _ = machine.apply(.command(.send))
        _ = machine.apply(.sendFinished(sent: false))
        #expect(machine.phase == .hearing)
        #expect(machine.draft == "hello")
    }

    @Test func discardClearsTheDraft() {
        var machine = started()
        _ = machine.apply(.transcript("hello"))
        #expect(machine.apply(.command(.discard)) == [.clearDraft])
        #expect(machine.phase == .listening)
        #expect(machine.draft == "")
    }

    @Test func theNextMessageCanBeSaidWhileWaiting() {
        var machine = started()
        _ = machine.apply(.transcript("hello"))
        _ = machine.apply(.command(.send))
        _ = machine.apply(.sendFinished(sent: true))
        _ = machine.apply(.transcript(" "))
        #expect(machine.phase == .waiting)
        #expect(machine.draft == "")
        _ = machine.apply(.transcript("and another thing"))
        #expect(machine.phase == .hearing)
        #expect(machine.draft == "and another thing")
        #expect(machine.apply(.command(.send)) == [.send("and another thing")])
    }

    @Test func transcriptsAreIgnoredWhileSendingAndSpeaking() {
        var machine = started()
        _ = machine.apply(.transcript("hello"))
        _ = machine.apply(.command(.send))
        _ = machine.apply(.transcript("noise"))
        #expect(machine.phase == .sending)
        #expect(machine.draft == "hello")
        _ = machine.apply(.sendFinished(sent: true))
        _ = machine.apply(.speechStarted)
        _ = machine.apply(.transcript("the reply itself"))
        #expect(machine.phase == .speaking)
        #expect(machine.draft == "")
    }

    @Test func aReplyWithNothingToReadListensAgain() {
        var machine = started()
        _ = machine.apply(.transcript("hello"))
        _ = machine.apply(.command(.send))
        _ = machine.apply(.sendFinished(sent: true))
        _ = machine.apply(.replyReady(hasReply: false))
        #expect(machine.phase == .listening)
    }

    @Test func speakingControls() {
        var machine = started()
        _ = machine.apply(.speechStarted)
        #expect(machine.apply(.command(.skip)) == [.skipSpeech])
        #expect(machine.phase == .speaking)
        #expect(machine.apply(.command(.repeatReply)) == [.speakLastReply])
        #expect(machine.apply(.command(.readAll)) == [.speakFullReply])
        #expect(machine.apply(.command(.stopSpeaking)) == [.stopSpeech, .clearDraft])
        #expect(machine.phase == .listening)
    }

    @Test func speechEndingReturnsToListening() {
        var machine = started()
        _ = machine.apply(.speechStarted)
        #expect(machine.apply(.speechEnded) == [.clearDraft])
        #expect(machine.phase == .listening)
    }

    @Test func awaitReplyWaitsAfterSpeechInBetween() {
        var machine = started()
        _ = machine.apply(.speechStarted)
        _ = machine.apply(.speechEnded)
        _ = machine.apply(.awaitReply)
        #expect(machine.phase == .waiting)
    }

    @Test func stopAgentWorksWhileWaiting() {
        var machine = started()
        _ = machine.apply(.transcript("go"))
        _ = machine.apply(.command(.send))
        _ = machine.apply(.sendFinished(sent: true))
        #expect(machine.apply(.command(.stopAgent)) == [.stopAgent])
        #expect(machine.phase == .waiting)
    }

    @Test func deactivateAndFailureEnd() {
        var machine = started()
        #expect(machine.apply(.command(.deactivate)) == [.end])
        #expect(machine.phase == .idle)
        _ = machine.apply(.start)
        #expect(machine.apply(.failure("no microphone")) == [.end])
        #expect(machine.phase == .failed("no microphone"))
        #expect(machine.apply(.start) == [.begin])
    }

    @Test func muteFreezesTheDraftAndUnmuteResumes() {
        var machine = started()
        _ = machine.apply(.transcript("hello"))
        #expect(machine.apply(.command(.mute)) == [.mute])
        #expect(machine.isMuted)
        #expect(machine.context == .muted)
        #expect(machine.apply(.transcript("chatter in the car")) == [])
        #expect(machine.draft == "hello")
        #expect(machine.apply(.silence) == [])
        #expect(machine.apply(.command(.send)) == [])
        #expect(machine.apply(.command(.discard)) == [])
        #expect(machine.phase == .hearing)
        #expect(machine.draft == "hello")
        #expect(machine.apply(.command(.mute)) == [])
        #expect(machine.apply(.command(.unmute)) == [.unmute])
        #expect(!machine.isMuted)
        #expect(machine.context == .dictating)
        _ = machine.apply(.transcript("hello world"))
        #expect(machine.draft == "hello world")
        #expect(machine.apply(.command(.send)) == [.send("hello world")])
    }

    @Test func unmuteWhenNotMutedDoesNothing() {
        var machine = started()
        #expect(machine.apply(.command(.unmute)) == [])
        #expect(!machine.isMuted)
        var idle = VoiceMachine()
        #expect(idle.apply(.command(.mute)) == [])
        #expect(!idle.isMuted)
    }

    @Test func muteWhileSpeakingReturnsToSpeaking() {
        var machine = started()
        _ = machine.apply(.speechStarted)
        #expect(machine.apply(.command(.mute)) == [.mute])
        #expect(machine.phase == .speaking)
        #expect(machine.context == .muted)
        #expect(machine.apply(.command(.unmute)) == [.unmute])
        #expect(machine.phase == .speaking)
        #expect(machine.context == .speaking)
    }

    @Test func speechEndingWhileMutedStaysMuted() {
        var machine = started()
        _ = machine.apply(.speechStarted)
        _ = machine.apply(.command(.mute))
        #expect(machine.apply(.speechEnded) == [.clearDraft])
        #expect(machine.phase == .listening)
        #expect(machine.isMuted)
        _ = machine.apply(.command(.unmute))
        #expect(machine.context == .dictating)
    }

    @Test func muteWhileWaitingReturnsToWaiting() {
        var machine = started()
        _ = machine.apply(.transcript("go"))
        _ = machine.apply(.command(.send))
        _ = machine.apply(.sendFinished(sent: true))
        #expect(machine.apply(.command(.mute)) == [.mute])
        #expect(machine.phase == .waiting)
        #expect(machine.context == .muted)
        _ = machine.apply(.command(.unmute))
        #expect(machine.phase == .waiting)
        #expect(machine.context == .dictating)
    }

    @Test func aSendInFlightFinishesWhileMuted() {
        var machine = started()
        _ = machine.apply(.transcript("go"))
        _ = machine.apply(.command(.send))
        _ = machine.apply(.command(.mute))
        _ = machine.apply(.sendFinished(sent: true))
        #expect(machine.phase == .waiting)
        #expect(machine.isMuted)
    }

    @Test func endingVoiceModeWorksWhileMutedAndClearsIt() {
        var machine = started()
        _ = machine.apply(.command(.mute))
        #expect(machine.apply(.command(.deactivate)) == [.end])
        #expect(!machine.isMuted)
        #expect(machine.context == nil)
        _ = machine.apply(.start)
        _ = machine.apply(.command(.mute))
        _ = machine.apply(.stop)
        _ = machine.apply(.start)
        #expect(!machine.isMuted)
    }

    @Test func settingsReadDefaultsAndClamp() throws {
        let defaults = try #require(UserDefaults(suiteName: "VoiceModeStateTests"))
        defaults.removePersistentDomain(forName: "VoiceModeStateTests")
        #expect(VoiceSettings(defaults: defaults) == VoiceSettings())
        defaults.set(99.0, forKey: VoiceDefaults.autoSendSecondsKey)
        defaults.set(true, forKey: VoiceDefaults.autoSendKey)
        var settings = VoiceSettings(defaults: defaults)
        #expect(settings.autoSendSeconds == VoiceDefaults.autoSendRange.upperBound)
        #expect(settings.autoSend)
        defaults.set(0.5, forKey: VoiceDefaults.autoSendSecondsKey)
        settings = VoiceSettings(defaults: defaults)
        #expect(settings.autoSendSeconds == VoiceDefaults.autoSendRange.lowerBound)
        defaults.removePersistentDomain(forName: "VoiceModeStateTests")
    }

    @Test func autoSendIsOffByDefaultWithAFiveSecondPause() {
        let settings = VoiceSettings()
        #expect(!settings.autoSend)
        #expect(settings.autoSendSeconds == 5)
        #expect(VoiceDefaults.autoSendRange == 2.0...15.0)
    }

    @Test func oldAutoSendValuesAreNotRead() throws {
        let defaults = try #require(UserDefaults(suiteName: "VoiceModeStateTestsLegacy"))
        defaults.removePersistentDomain(forName: "VoiceModeStateTestsLegacy")
        // What the first version stored: on, 2 s.
        defaults.set(true, forKey: "voice.autoSend")
        defaults.set(2.0, forKey: "voice.autoSendSeconds")
        let settings = VoiceSettings(defaults: defaults)
        #expect(!settings.autoSend)
        #expect(settings.autoSendSeconds == 5)
        defaults.removePersistentDomain(forName: "VoiceModeStateTestsLegacy")
    }

    @Test func backoffDoubles() {
        #expect(VoiceDefaults.backoff(attempt: 1) == 1)
        #expect(VoiceDefaults.backoff(attempt: 3) == 4)
    }
}
