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

    @Test func transcriptsAreIgnoredWhileWaitingAndSpeaking() {
        var machine = started()
        _ = machine.apply(.transcript("hello"))
        _ = machine.apply(.command(.send))
        _ = machine.apply(.sendFinished(sent: true))
        _ = machine.apply(.transcript("noise"))
        #expect(machine.phase == .waiting)
        #expect(machine.draft == "")
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

    @Test func settingsReadDefaultsAndClamp() throws {
        let defaults = try #require(UserDefaults(suiteName: "VoiceModeStateTests"))
        defaults.removePersistentDomain(forName: "VoiceModeStateTests")
        #expect(VoiceSettings(defaults: defaults) == VoiceSettings())
        defaults.set(99.0, forKey: VoiceDefaults.autoSendSecondsKey)
        defaults.set(false, forKey: VoiceDefaults.autoSendKey)
        let settings = VoiceSettings(defaults: defaults)
        #expect(settings.autoSendSeconds == VoiceDefaults.autoSendRange.upperBound)
        #expect(!settings.autoSend)
        defaults.removePersistentDomain(forName: "VoiceModeStateTests")
    }

    @Test func backoffDoubles() {
        #expect(VoiceDefaults.backoff(attempt: 1) == 1)
        #expect(VoiceDefaults.backoff(attempt: 3) == 4)
    }
}
