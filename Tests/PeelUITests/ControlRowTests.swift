import Foundation
import Testing
@testable import PeelCore
@testable import PeelTestSupport
@testable import PeelUI

private let dm = keyG
private let tribe = key2G

/// A control message's body: `content` as the official apps show it, and an ack in its metadata beside `tz`.
private func controlBody(_ content: String) -> String {
    let metadata = #"{"tz":"GMT+1","peel":{"v":1,"op":"ack","re":"r_1"}}"#
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

    /// Your device's own control message (an ack, a result) is not your
    /// send: it never pulls a list you are reading down to the newest.
    @Test func yourDevicesControlMessageIsNotYourArrival() {
        let rows = ChatRow.rows([message(0), message(1, fromMe: true, body: controlBody("Peel read your unread messages on your Mac")),
                                 message(2, fromMe: true)], parents: [:], inTribe: false, people: people)
        #expect(rows.map { $0.listRow(in: .chat(dm)).isOwn } == [false, false, true])
    }
}
