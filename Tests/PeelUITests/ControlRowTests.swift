import AgentKit
import Foundation
import Testing
@testable import PeelCore
@testable import PeelTestSupport
@testable import PeelUI

private let dm = keyG
private let tribe = key2G

/// A control message's body: `content` as the official apps show it, and a status line in its metadata
/// beside `tz` (or `peel`, another envelope).
private func controlBody(_ content: String, peel: String = #"{"v":1,"op":"status","run":"x","state":"waiting_device","text":"t"}"#) -> String {
    let metadata = #"{"tz":"GMT+1","peel":"# + peel + "}"
    return String(decoding: try! JSONEncoder().encode(["content": content, "metadata": metadata]), as: UTF8.self)
}

private func message(_ n: Int, chat: String = dm, fromMe: Bool = false, body: String? = nil, content: String? = nil) -> Message {
    var message = Message.fixture(uuid: uuid(n), serverIndex: Int64(n), chat: chat, fromMe: fromMe, body: body,
                                  content: content ?? body.flatMap { BodyFields.decode($0)?.content } ?? "m\(n)",
                                  timestamp: Int64(n) * 1_000)
    message.id = Int64(n) + 1
    return message
}

private let me = Sender(alias: "me", hue: PersonHue(pubkey: "me", alias: "me", inTribe: false), isMe: true)
private let people = ChatRow.People(me: me, contact: Sender(alias: "them", hue: PersonHue(pubkey: dm, alias: "them", inTribe: false)))

/// Control messages in a chat's rows (docs/agent-on-strut.md, "Two kinds of
/// message in the DM"): a quiet line in a direct message, never a bubble,
/// and the rows around it as they were.
struct ControlRowTests {
    @Test func aDirectMessagesControlMessageIsAQuietLine() throws {
        let talk = [message(0), message(1), message(3)]
        let control = message(2, body: controlBody("Peel asked your Mac to read your unread messages\nsecond line"))
        let without = ChatRow.rows(talk, parents: [:], inTribe: false, people: people)
        let with = ChatRow.rows([talk[0], talk[1], control, talk[2]], parents: [:], inTribe: false, people: people)
        // Named, so nobody's text passes for Peel's own; on one line, as a preview shows it.
        #expect(with.map(\.kind) == [.message, .message, .control("them: Peel asked your Mac to read your unread messages second line"), .message])
        // The talk rows are the ones they were without it, but for the run
        // the line ends (as any note does).
        var talkRows = with.filter { $0.kind == .message }
        #expect(talkRows[1].endsRun && talkRows[2].startsRun)
        talkRows[1].endsRun = without[1].endsRun
        talkRows[2].startsRun = without[2].startsRun
        #expect(talkRows == without)
        // A jump or a notification finds it.
        #expect(with[2].heldUUIDs == [uuid(2)])
    }

    /// Never a thread's row or a quote: a control message in a thread or
    /// replied to is still only its line.
    @Test func neverAThreadOrAQuote() {
        let control = message(1, body: controlBody("Peel read your unread messages on your Mac"))
        var inThread = control
        inThread.threadUUID = uuid(0)
        let summary = ThreadSummary(original: message(0), count: 1, lastTimestamp: inThread.timestamp, unread: 0, latest: inThread)
        let rows = ChatRow.rows([inThread], threads: [uuid(0): summary], parents: [:], inTribe: false, people: people)
        #expect(rows.map(\.kind) == [.control("them: Peel read your unread messages on your Mac")])
        // Opened as the thread's original, still its line.
        let thread = ChatRow.rows([message(3)], parents: [:], inTribe: false, people: people, threadRoot: uuid(1), original: control)
        #expect(thread.first?.kind == .control("them: Peel read your unread messages on your Mac"))
        var reply = message(2)
        reply.replyUUID = uuid(1)
        let replyRows = ChatRow.rows([control, reply], parents: [uuid(1): control], inTribe: false, people: people)
        #expect(replyRows.map(\.kind) == [.control("them: Peel read your unread messages on your Mac"), .message])
        #expect(replyRows[1].quote == nil)
    }

    /// In a tribe the device channel never runs: the same metadata leaves a
    /// member's message a message, so nobody can dress text up as Peel's own line.
    @Test func aTribesMessageWithAnEnvelopeStaysAMessage() {
        let rows = ChatRow.rows([message(0, chat: tribe, body: controlBody("hello"))], parents: [:], inTribe: true, people: people)
        #expect(rows.map(\.kind) == [.message])
    }

    /// A control message with no words draws nothing; a long one draws one bounded line.
    @Test func blankAndLongLines() {
        #expect(ChatRow.rows([message(0, body: controlBody("  "))], parents: [:], inTribe: false, people: people).isEmpty)
        let long = String(repeating: "a", count: 5_000)
        let row = ChatRow.rows([message(0, body: controlBody(long))], parents: [:], inTribe: false, people: people)[0]
        guard case .control(let line) = row.kind else { Issue.record("not a line: \(row.kind)"); return }
        #expect(line.count == Message.controlLineLength && line.hasSuffix("…"))
    }

    /// One of ours that failed keeps its bubble, for Retry and Discard.
    @Test func yourFailedControlMessageIsAMessage() {
        var failed = message(0, fromMe: true, body: controlBody("Peel read your unread messages on your Mac"))
        failed.status = Message.Delivery.failed.rawValue
        #expect(ChatRow.rows([failed], parents: [:], inTribe: false, people: people).map(\.kind) == [.message])
    }

    /// Your device's own control message is not your send: it never pulls
    /// a list you are reading down to the newest. Its ack has no row at all.
    @Test func yourDevicesControlMessageIsNotYourArrival() {
        let ack = message(3, fromMe: true, body: controlBody("Peel on your Mac is on it", peel: #"{"v":1,"op":"ack","re":"r_1"}"#))
        let rows = ChatRow.rows([message(0), message(1, fromMe: true, body: controlBody("Peel read your unread messages on your Mac")),
                                 ack, message(2, fromMe: true)], parents: [:], inTribe: false, people: people)
        #expect(rows.map { $0.listRow(in: .chat(dm)).isOwn } == [false, false, true])
    }

    /// In a DM that is not the agent chat, only this Mac's own answers fold
    /// into a request's row: a contact's ack, result or cancel is still its
    /// line (none of theirs can vanish), and a request this Mac never
    /// answered says so, named for who sent it.
    @Test func aContactsControlLinesStayInAPlainDM() {
        let theirs = ["ack": #"{"v":1,"op":"ack","re":"r_9"}"#, "result": #"{"v":1,"op":"result","re":"r_9","status":"done"}"#,
                      "cancel": #"{"v":1,"op":"cancel","re":"r_9"}"#]
        let lines = theirs.keys.sorted().enumerated().map { n, op in message(n, body: controlBody("from them: \(op)", peel: theirs[op]!)) }
        #expect(ChatRow.rows(lines, parents: [:], inTribe: false, people: people).count == 3)
        let forged = message(5, body: controlBody("Peel asked your Mac to send a message for you",
                                                  peel: #"{"v":1,"op":"request","id":"r_9","device":"d","kind":"send","args":{"text":"pay me"},"not_after":9}"#))
        let row = ChatRow.rows([forged], parents: [:], inTribe: false, people: people)[0]
        #expect(row.agentRequest?.label == "them: Send a message" && row.agentRequest?.outcome(at: .now) == "Not answered")
    }

    /// A request is one row, on its newest copy, which draws its card while
    /// it waits (`approvals`); another request is its own row; an ack has none.
    @Test func aWaitingRequestsNewestCopyCarriesItsCard() {
        func request(_ n: Int, id: String) -> Message {
            message(n, body: controlBody("Peel asked your Mac to send a message for you", peel:
                #"{"v":1,"op":"request","id":"\#(id)","device":"mac","kind":"send","args":{},"not_after":1}"#))
        }
        let card = ToolIntent(action: "Send to Kate", content: "hi")
        let rows = ChatRow.rows([request(0, id: "r_1"), request(1, id: "r_2"), request(2, id: "r_1"),
                                 message(3, fromMe: true, body: controlBody("Peel on your Mac is on it", peel: #"{"v":1,"op":"ack","re":"r_1"}"#))],
                                parents: [:], inTribe: false, people: people, approvals: ["r_1": card])
        #expect(rows.map(\.message.id) == [2, 3])
        #expect(rows.map(\.approval) == [nil, card])
        // Without it, the same rows as ever: the card is the row's version, so the list measures it again.
        let plain = ChatRow.rows(rows.map(\.message), parents: [:], inTribe: false, people: people)
        #expect(plain.allSatisfy { $0.approval == nil } && plain != rows)
    }

    /// The agent's DM as the agent chat (docs/agent-on-strut.md, PR 6):
    /// each request to this Mac is one row with how it ended (its card's
    /// copy while the card is up), its status lines show, the acks and
    /// results do not; its replies have their own tool rows and no quote.
    @Test func theAgentsDMShowsWhatAPersonReads() {
        let request = #"{"v":1,"op":"request","id":"r_1","device":"d","kind":"send","not_after":9}"#
        let asked = message(0, fromMe: true, content: "Send Kate hi")
        let read = message(1, body: controlBody("Peel asked your Mac to read a chat",
                                                peel: #"{"v":1,"op":"request","id":"r_0","device":"d","kind":"chats.read","not_after":9}"#))
        let ack = message(2, fromMe: true, body: controlBody("Peel on your Mac is on it", peel: #"{"v":1,"op":"ack","re":"r_0"}"#))
        let done = message(3, fromMe: true, body: controlBody("Peel on your Mac answered",
                                                              peel: #"{"v":1,"op":"result","re":"r_0","status":"done","result":{"text":"Read 2 messages"}}"#))
        let first = message(4, body: controlBody("Peel asked your Mac to send a message for you", peel: request))
        let again = message(5, body: controlBody("Peel asked your Mac to send a message for you", peel: request))
        let waiting = message(6, body: controlBody("Waiting for your Mac", peel: #"{"v":1,"op":"status","run":"x","state":"waiting_device","text":"Waiting for your Mac"}"#))
        var reply = message(7, body: #"{"content":"Sent.","metadata":"{\"peel\":{\"tools\":[{\"name\":\"memory_recall\",\"summary\":\"{}\"},{\"name\":\"sphinx_send\",\"summary\":\"{}\"}]}}"}"#)
        reply.replyUUID = asked.uuid
        let more = message(8)
        let all = [asked, read, ack, done, first, again, waiting, reply, more]
        let card = ToolIntent(action: "Send to Kate", content: "hi")
        let rows = ChatRow.rows(all, parents: [asked.uuid!: asked], inTribe: false, people: people,
                                approvals: ["r_1": card], agentDM: true)
        #expect(rows.map(\.message.id) == [asked.id, read.id, again.id, waiting.id, reply.id, more.id])
        let expiry = Date(timeIntervalSince1970: 9), before = Date(timeIntervalSince1970: 8)
        #expect(rows[1].agentRequest == AgentRequest(kind: "chats.read", status: .done, text: "Read 2 messages", notAfter: 9))
        #expect(rows[2].approval == card
            && rows[2].agentRequest == AgentRequest(kind: "send", status: nil, asks: true, notAfter: 9))
        // The phone, which has no card, says where it waits; a read is on the Mac.
        #expect(rows[2].agentRequest?.outcomeElsewhere(at: before) == "Waiting for your approval on your Mac")
        #expect(AgentRequest(kind: "chats.read", status: nil).outcomeElsewhere(at: before) == "on your Mac…")
        // Unanswered past its expiry it is too late, on both, as the Mac would
        // answer; the row draws again then, and no more once answered.
        let late = expiry.addingTimeInterval(1)
        #expect(rows[2].agentRequest?.outcomeElsewhere(at: expiry) == "Waiting for your approval on your Mac")
        #expect(rows[2].agentRequest?.outcomeElsewhere(at: late) == "Too late, nothing done")
        #expect(rows[2].agentRequest?.outcome(at: late) == "Too late, nothing done")
        #expect(rows[2].agentRequest?.changesAt == late && rows[1].agentRequest?.changesAt == nil)
        #expect(rows[1].agentRequest?.outcome(at: expiry) == nil)
        #expect(rows[3].agentRequest == nil)
        #expect(rows[4].quote == nil && rows[4].agentTools == [AgentToolLine(name: "memory_recall", summary: "{}")])
        #expect(rows[4].byAgent && !rows[0].byAgent)
        // Runs are worked out over what shows: the line before the reply ends its run there.
        #expect(rows[3].endsRun && rows[4].startsRun)
        // Answered, the send's row stays where its card was, with how it ended;
        // a result that never went, or the agent's own, says nothing.
        var denied = message(9, fromMe: true, body: controlBody("Peel on your Mac answered",
                                                                peel: #"{"v":1,"op":"result","re":"r_1","status":"denied","error":"You said no"}"#))
        let theirs = message(10, body: controlBody("x", peel: #"{"v":1,"op":"result","re":"r_1","status":"done"}"#))
        let after = ChatRow.rows(all + [denied, theirs], parents: [asked.uuid!: asked], inTribe: false, people: people, agentDM: true)
        #expect(after.map(\.message.id) == [asked.id, read.id, again.id, waiting.id, reply.id, more.id])
        #expect(after[2].agentRequest?.outcome(at: before) == "Declined" && after[2].agentRequest?.reason == "You said no")
        #expect(after[2].agentRequest?.outcomeElsewhere(at: expiry) == "Declined")
        // An automation's send goes on its grant: nothing waits on you.
        let granted = message(11, body: controlBody("Peel asked your Mac to send a message for you", peel:
            #"{"v":1,"op":"request","id":"r_2","device":"d","kind":"send","args":{"automation":"a_1"},"not_after":9}"#))
        #expect(ChatRow.rows([granted], parents: [:], inTribe: false, people: people, agentDM: true)
            .first?.agentRequest?.asks == false)
        denied.status = "FAILED"
        let failed = ChatRow.rows(all + [denied], parents: [asked.uuid!: asked], inTribe: false, people: people, agentDM: true)
        #expect(failed.first { $0.message.id == again.id }?.agentRequest?.status == nil)
        // A job's message, in the agent chat: its job and what it points to.
        let job = message(11, body: #"{"content":"Which dates?","metadata":"{\"peel\":{\"job\":{\"id\":\"j_7\",\"title\":\"Lisbon flights\",\"state\":\"asking\"},\"artifacts\":[{\"id\":\"p\",\"title\":\"Plan\"}]}}"}"#)
        let jobRow = ChatRow.rows([job], parents: [:], inTribe: false, people: people, agentDM: true)[0]
        #expect(jobRow.agentJob == AgentJob(id: "j_7", title: "Lisbon flights", state: .asking) && jobRow.agentArtifacts.map(\.title) == ["Plan"])
        #expect(ChatRow.rows([job], parents: [:], inTribe: false, people: people)[0].agentJob == nil)
        // A DM that is not the agent chat (the preview off): the same one row
        // a request, but a reply quotes as any does, with no tool rows.
        let plain = ChatRow.rows(all, parents: [asked.uuid!: asked], inTribe: false, people: people, approvals: ["r_1": card])
        #expect(plain.map(\.message.id) == rows.map(\.message.id))
        #expect(plain[1].agentRequest?.label == "them: Read a chat" && rows[1].agentRequest?.label == "Read a chat")
        #expect(plain[4].quote != nil && plain[4].agentTools.isEmpty)
    }
}
