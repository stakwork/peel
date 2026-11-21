import Foundation
import Testing
@testable import PeelCore
@testable import PeelTestSupport
@testable import PeelUI

/// The Voice Mode setting, its modes, the reply it shows and the linen's
/// flecks: no window.
struct VoiceModeScreenTests {
    @Test func settingIsOffByDefaultUnderItsKey() {
        #expect(VoiceModeSetting.key == "voiceMode")
        #expect(VoiceModeSetting.defaultValue == false)
        let suite = "peel.voicemode.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(defaults.bool(forKey: VoiceModeSetting.key) == false)
    }

    @Test func settingPersists() {
        let suite = "peel.voicemode.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: VoiceModeSetting.key)
        #expect(UserDefaults(suiteName: suite)!.bool(forKey: VoiceModeSetting.key))
    }

    /// The reply is the agent's texts after your newest message, whatever
    /// sent it (the mic or the text box), so the text modes show it too.
    @Test func replyIsWhatTheAgentSaidSinceYourNewestMessage() {
        let first = Message.fixture(uuid: "m1", fromMe: true, content: "What did I miss?", timestamp: 1)
        let answer = Message.fixture(uuid: "a1", content: "Three chats.", timestamp: 2, replyUUID: "m1")
        let second = Message.fixture(uuid: "m2", fromMe: true, content: "Read them", timestamp: 3)
        let part1 = Message.fixture(uuid: "a2", content: "Kate says hi.", timestamp: 4)
        let part2 = Message.fixture(uuid: "a3", content: "Bob asks about Friday.", timestamp: 5, replyUUID: "m2")
        #expect(VoiceModeReply.latest(in: [first, answer], chat: dm) == [answer])
        // Your newer message has no answer yet.
        #expect(VoiceModeReply.latest(in: [first, answer, second], chat: dm).isEmpty)
        #expect(VoiceModeReply.latest(in: [first, answer, second, part1, part2], chat: dm) == [part1, part2])
        #expect(VoiceModeReply.text(of: [part1, part2]) == "Kate says hi.\n\nBob asks about Friday.")
        #expect(VoiceModeReply.text(of: []) == nil)
        // Another chat's messages are not the agent's.
        #expect(VoiceModeReply.latest(in: [first, answer], chat: "02bb").isEmpty)
    }

    /// A message that never went or a control line is no turn: the answer
    /// before it is still the reply.
    @Test func replySkipsWhatIsNoTurn() {
        let asked = Message.fixture(uuid: "m1", fromMe: true, content: "Hi", timestamp: 1)
        let answer = Message.fixture(uuid: "a1", content: "Hello.", timestamp: 2, replyUUID: "m1")
        let failed = Message.fixture(uuid: "m2", fromMe: true, content: "Again", timestamp: 3, status: "FAILED")
        let ack = Message.fixture(uuid: "m3", fromMe: true,
                                  body: #"{"content":"","metadata":"{\"peel\":{\"v\":1,\"op\":\"ack\",\"re\":\"r\"}}"}"#, timestamp: 4)
        #expect(VoiceModeReply.latest(in: [asked, answer, failed, ack], chat: dm) == [answer])
        // A picture you sent is a turn of its own, waiting for its answer.
        let picture = Message.fixture(uuid: "m4", type: MessageType.attachment, fromMe: true, content: nil, timestamp: 5)
        #expect(VoiceModeReply.latest(in: [asked, answer, picture], chat: dm).isEmpty)
    }

    @Test func fleckPlacementIsFixed() {
        let first = LinenFleck.make()
        #expect(first == LinenFleck.make())
        #expect(first.count == 70)
        #expect(first != LinenFleck.make(seed: 1))
        #expect(first.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) })
    }

    @Test func interactionModeDefaultAndKey() {
        #expect(VoiceModeInteraction.key == "voiceModeInteraction")
        #expect(VoiceModeInteraction.defaultValue == .speechInSpeechOut)
    }

    @Test func interactionModeUsesMic() {
        #expect(VoiceModeInteraction.speechInSpeechOut.usesMic)
        #expect(!VoiceModeInteraction.textInTextOut.usesMic)
        #expect(VoiceModeInteraction.speechInTextOut.usesMic)
        #expect(!VoiceModeInteraction.textInSpeechOut.usesMic)
    }

    @Test func interactionModeSpeaksReply() {
        #expect(VoiceModeInteraction.speechInSpeechOut.speaksReply)
        #expect(!VoiceModeInteraction.textInTextOut.speaksReply)
        #expect(!VoiceModeInteraction.speechInTextOut.speaksReply)
        #expect(VoiceModeInteraction.textInSpeechOut.speaksReply)
    }

    @Test func subtitlesDefaultAndKey() {
        #expect(VoiceModeSubtitlesSetting.key == "voiceModeSubtitles")
        #expect(VoiceModeSubtitlesSetting.defaultValue == false)
    }

    @Test func interactionModeRoundTrips() {
        // All cases survive a rawValue round-trip (needed for @AppStorage).
        for mode in VoiceModeInteraction.allCases {
            #expect(VoiceModeInteraction(rawValue: mode.rawValue) == mode)
        }
    }
}
