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
        ("hi @ja", "hi @Jamie "), ("a\n@Ja", "a\n@Jamie "),
    ])
    func tabCompletesAStartedMention(text: String, completed: String) {
        #expect(CallChatWire.completingJamie(text) == completed)
    }

    @Test(arguments: ["", "hi", "@Jamie ", "@jamiex", "@bob", "email@j", "hi @ ", "@ja me"])
    func tabLeavesOtherTextAlone(text: String) {
        #expect(CallChatWire.completingJamie(text) == nil)
    }

    // MARK: strut's entries (sphinx-voice plans/call-artifacts.md)

    private func reply(_ entries: String, workspace: String = "acme") -> String {
        #"{"id":"r1","timestamp":1730000000000,"message":"Here.","strut":{"workspace":""# + workspace
            + #"","artifacts":["# + entries + "]}}"
    }

    private func artifacts(_ json: String, fromJamie: Bool = true) -> [AgentArtifact] {
        guard case .message(let message)? = CallChatWire.decode(Data(json.utf8), fromJamie: fromJamie) else { return [] }
        return message.artifacts
    }

    @Test func resolvesEachEntryAgainstTheWorkspace() {
        let read = artifacts(reply(#"""
            {"id":"plan","kind":"markdown","title":"Plan","label":"Plan","url":"/jobs/j-41/files/plan.md"},
            {"id":"ui","kind":"app","title":"Bench","url":"/apps/bench/v3/files/dist/index.html","app":{"name":"bench","version":"v3"}},
            {"id":"live","kind":"app","title":"Board","app":{"name":"hive/board"}},
            {"id":"shot","kind":"image","title":"Shot","peer":"web","job":"peer/j-7","path":"shots/a b.png"},
            {"id":"far","title":"Far","peer":"web","via":"billing","job":"j-9","path":"/r.md"},
            {"id":"pr","kind":"pull_request","title":"Fix login","url":"https://github.com/acme/web/pull/12"}
            """#))
        #expect(read.map(\.handle) == [
            .file("/peers/acme/jobs/j-41/files/plan.md"),
            .app("@acme/bench@v3"),
            .app("@acme/hive/board"),
            .file("/peers/acme/peers/web/jobs/peer%2Fj-7/files/shots/a%20b.png"),
            .file("/peers/acme/peers/web/peers/billing/jobs/j-9/files/r.md"),
            nil,
        ])
        #expect(read.first?.label == "Plan" && read.first?.url == nil)
        #expect(read.last?.url == URL(string: "https://github.com/acme/web/pull/12"))
        // The org's own strut is one hop nearer.
        #expect(read[4].handle?.onOrg?.value == "/peers/web/peers/billing/jobs/j-9/files/r.md")
    }

    @Test func opensNothingItCannotName() {
        let read = artifacts(reply(#"""
            {"id":"up","title":"Up","peer":"web","job":"j","path":"../secrets.json"},
            {"id":"bad","title":"Bad","peer":"a/b","job":"j","path":"x.md"},
            {"id":"peerapp","kind":"app","title":"Peer app","peer":"web","app":{"name":"bench"}},
            {"id":"host","title":"Host","url":"//evil.example/jobs/j/files/x"},
            {"id":"route","title":"Route","url":"/workflows/job/runs/r1"}
            """#))
        #expect(read.map(\.title) == ["Up", "Bad", "Peer app", "Host", "Route"])
        #expect(read.allSatisfy { $0.handle == nil && $0.url == nil })
        #expect(artifacts(reply(#"{"id":"x","title":"X","url":"/jobs/j/files/x"}"#, workspace: "../x")).first?.handle == nil)
    }

    @Test func readsAnAppByItsDocumentLink() {
        let read = artifacts(reply(#"""
            {"id":"a","kind":"app","title":"Canvas","url":"/apps/infinite-canvas/v21/files/dist/index.html"},
            {"id":"b","kind":"app","title":"Active","url":"/apps/tools%2Fboard/files/dist/index.html"},
            {"id":"c","kind":"app","title":"Other file","url":"/apps/infinite-canvas/v21/files/data.json"},
            {"id":"d","kind":"app","title":"Bad name","url":"/apps/bad%20name/v1/files/dist/index.html"}
            """#, workspace: "hive"))
        #expect(read.map(\.handle) == [.app("@hive/infinite-canvas@v21"), .app("@hive/tools/board"), nil, nil])
    }

    @Test func readsStrutOnlyFromJamieAndNeverLosesTheMessage() {
        let entry = #"{"id":"plan","title":"Plan","url":"/jobs/j/files/plan.md"}"#
        #expect(artifacts(reply(entry)).count == 1)
        #expect(artifacts(reply(entry), fromJamie: false).isEmpty)
        for strut in [#""x""#, "{}", #"{"workspace":"acme","artifacts":"x"}"#, #"{"workspace":"acme","artifacts":[{"id":"no-title"}]}"#] {
            let json = #"{"id":"r1","timestamp":1730000000000,"message":"Here.","strut":"# + strut + "}"
            guard case .message(let message)? = incoming(json) else { Issue.record(Comment(rawValue: strut)); continue }
            #expect(message.text == "Here." && message.artifacts.isEmpty)
        }
    }

    @Test func showsTheLinkListOnlyWhenNoArtifactLinesStandForIt() {
        let text = "Here's the plan.\n\n- [Plan](https://hive.example/p)\n* [Fix](https://github.com/a/b/pull/1)\n- not a link\n- [Inline](https://x.example) and more"
        let plan = AgentArtifact(id: "plan", title: "Plan")
        let with = CallChatMessage(id: "r", timestamp: .now, text: text, sender: nil, artifacts: [plan])
        #expect(with.shownText == "Here's the plan.\n\n- not a link\n- [Inline](https://x.example) and more")
        #expect(CallChatMessage(id: "r", timestamp: .now, text: text, sender: nil).shownText == text)
        #expect(CallChatMessage(id: "r", timestamp: .now, text: "- [Plan](https://hive.example/p)", sender: nil, artifacts: [plan]).shownText.isEmpty)
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
