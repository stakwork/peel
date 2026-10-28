import Foundation
import Testing
@testable import PeelCore

struct CallChatWireTests {
    private func incoming(_ json: String) -> CallChatWire.Incoming? { CallChatWire.decode(Data(json.utf8)) }

    @Test func encodesTheFourFieldsTheOtherClientsRead() throws {
        let data = CallChatWire.encode(
            id: "abc", timestamp: Date(timeIntervalSince1970: 1_730_000_000.5), text: "hi", sender: "Alex"
        )
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["id", "timestamp", "message", "sender"])
        #expect(object["id"] as? String == "abc")
        #expect(object["message"] as? String == "hi")
        #expect(object["sender"] as? String == "Alex")
        #expect((object["timestamp"] as? NSNumber)?.int64Value == 1_730_000_000_500)
        // What Peel sends, Peel reads back.
        #expect(CallChatWire.decode(data) == .message(CallChatMessage(
            id: "abc", timestamp: Date(timeIntervalSince1970: 1_730_000_000.5), text: "hi", sender: "Alex"
        )))
    }

    @Test func readsAPersonsMessage() {
        let sample = #"{"id":"1","timestamp":1730000000000,"message":"hi","sender":"Alex"}"#
        #expect(incoming(sample) == .message(CallChatMessage(
            id: "1", timestamp: Date(timeIntervalSince1970: 1_730_000_000), text: "hi", sender: "Alex"
        )))
    }

    @Test func aMessageWithNoSenderIsJamies() throws {
        let sample = #"{"id":"2","timestamp":1730000001000,"message":"Three tasks merged.\n\n- [Notes](https://x.test/n)"}"#
        guard case .message(let message)? = incoming(sample) else {
            Issue.record("not a message")
            return
        }
        #expect(message.sender == nil)
        #expect(message.isFromJamie)
        #expect(message.text == "Three tasks merged.\n\n- [Notes](https://x.test/n)")
    }

    @Test func readsAStatusRowAsNoMessage() {
        let sample = #"{"id":"3","timestamp":1730000002000,"status":"processing","intent":"thinking","message":"Thinking…"}"#
        #expect(incoming(sample) == .status(id: "3"))
    }

    @Test func readsASpokenCommandAsThePersonsRow() {
        let sample = #"{"id":"4","timestamp":1730000003000,"message":"what shipped","sender":"Sam","voice":true}"#
        guard case .message(let message)? = incoming(sample) else {
            Issue.record("not a message")
            return
        }
        #expect(message.sender == "Sam")
        #expect(message.isVoice)
        #expect(!message.isFromJamie)
    }

    @Test(arguments: [
        #"{"type":"tts-toggle"}"#,
        "not json",
        #"{"id":"5","timestamp":1,"message":"   \n","sender":"Sam"}"#,
        #"{"id":"6","timestamp":1,"message":"","sender":"Sam"}"#,
    ])
    func ignoresWhatIsNotAMessage(json: String) {
        #expect(incoming(json) == nil)
    }

    @Test(arguments: ["@Jamie hi", "hey @jamie", "x\n@JAMIE", "@jamie"])
    func seesAMentionOfJamie(text: String) {
        #expect(CallChatWire.mentionsJamie(text))
    }

    @Test(arguments: ["jamie", "email@jamie.com", "@jamiex", "hi @jamie_ok"])
    func seesNoMentionInOtherText(text: String) {
        #expect(!CallChatWire.mentionsJamie(text))
    }

    @Test(arguments: [
        ("@", "@Jamie "), ("@j", "@Jamie "), ("@JAM", "@Jamie "), ("@jamie", "@Jamie "),
        ("hi @ja", "hi @Jamie "), ("a\n@Ji", "a\n@Jamie "),
    ])
    func tabCompletesAStartedMention(text: String, completed: String) {
        #expect(CallChatWire.completingJamie(text) == completed)
    }

    @Test(arguments: ["", "hi", "@Jamie ", "@jamiex", "@bob", "email@j", "hi @ ", "@ja me"])
    func tabLeavesOtherTextAlone(text: String) {
        #expect(CallChatWire.completingJamie(text) == nil)
    }
}

struct CallChatLogTests {
    private func message(_ id: String, sender: String? = "Alex") -> CallChatMessage {
        CallChatMessage(id: id, timestamp: Date(timeIntervalSince1970: 1_730_000_000), text: "text \(id)", sender: sender)
    }

    @Test func aStatusRowSetsThinkingAndIsNeverStored() {
        var log = CallChatLog()
        let row = log.receive(.status(id: "s"))
        #expect(row == nil)
        #expect(log.jamieThinking)
        #expect(log.rows.isEmpty)
    }

    @Test func theNextMessageFromJamieClearsThinking() {
        var log = CallChatLog()
        log.receive(.status(id: "s"))
        log.receive(.message(message("p")))
        #expect(log.jamieThinking, "a person's message does not end it")
        let row = log.receive(.message(message("j", sender: nil)))
        #expect(!log.jamieThinking)
        let fromJamie = row.map { log.isFromJamie($0) }
        #expect(fromJamie == true)
        #expect(log.rows.map(\.id) == ["p", "j"])
    }

    @Test func stopThinkingIgnoresATimerForAnEarlierStatusRow() {
        var log = CallChatLog()
        log.receive(.status(id: "a"))
        let first = log.thinkingSerial
        log.receive(.status(id: "b"))
        log.stopThinking(ifSerial: first)
        #expect(log.jamieThinking)
        log.stopThinking(ifSerial: log.thinkingSerial)
        #expect(!log.jamieThinking)
    }

    @Test func aRepeatedIdIsIgnored() {
        var log = CallChatLog()
        let first = log.receive(.message(message("1")))
        let repeated = log.receive(.message(message("1")))
        let added = log.appendLocal(message("1"))
        #expect(first != nil)
        #expect(repeated == nil)
        #expect(!added)
        #expect(log.rows.count == 1)
    }

    @Test func keepsTheNewestFiveHundred() {
        var log = CallChatLog()
        for index in 0..<(CallChatLog.cap + 20) { log.receive(.message(message("\(index)"))) }
        #expect(log.rows.count == CallChatLog.cap)
        #expect(log.rows.first?.id == "20")
        #expect(log.rows.last?.id == "\(CallChatLog.cap + 19)")
    }

    @Test func aLocalSendIsMineAndCanFailAndRetry() {
        var log = CallChatLog()
        log.appendLocal(message("m"))
        #expect(log.rows.first?.isMine == true)
        log.mark(id: "m", failed: true)
        #expect(log.rows.first?.failed == true)
        log.mark(id: "m", failed: false)
        #expect(log.rows.first?.failed == false)
    }
}
