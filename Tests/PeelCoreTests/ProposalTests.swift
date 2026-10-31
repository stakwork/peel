import Foundation
import Testing
@testable import PeelCore
@testable import PeelTestSupport

/// A strut proposal as Peel reads it (`ProposalRecord`, `ProposalCard`):
/// each status, strut's card as #404 writes it, a record from before it,
/// the words cleaned, the store, and a workspace's strut asked with the
/// person's token.
struct ProposalTests {
    /// A record as strut writes one (`src/proposals.ts`), with `fields` in place.
    static func json(_ fields: String) -> Data {
        Data("""
        {"id":"p3f9aKq2xy","step":"package/install","input":{"package":"acme/linear"},
         "rationale":"You asked for Linear.","title":"Install the package acme/linear",
         "summary":"acme/linear 1.0.0 (MIT) from acme — key abcdefgh…uvwxyz, listed by the index main.\\nIt brings 1 app (A), 2 workflows, 1 step — TypeScript that runs inside this strut.\\nIt needs the secret LINEAR_KEY.",
         "card":{"v":1,"title":"Install the package acme/linear",
                 "fields":[{"label":"Version and license","value":"1.0.0 (MIT)"},{"label":"Publisher key","value":"abcdefgh…uvwxyz","kind":"code"},
                           {"label":"Needs","value":"LINEAR_KEY"},{"label":"Runs code","value":"Yes: its own TypeScript","danger":true},
                           {"label":"Docs","value":"[a page]","kind":"markdown"},{"label":"Odd","value":"?","kind":"hologram","extra":1},
                           {"label":"no value"},"not an object"],
                 "actions":{"accept":"Install","reject":"Don't install"},"full":true,"unknown":"ignored"},
         "createdAt":"2026-10-31T10:00:00.000Z",
         "by":{"workflow":"orchestrator","runId":"r1","path":"orchestrator/agent/t3","actor":"tom","principal":"peel"},
         \(fields)
         "unknown":{"deep":true}}
        """.utf8)
    }

    @Test func strutsRecordIsReadWithItsCardAndEachStatus() throws {
        let pending = try ProposalRecord(strut: Self.json(#""status":"pending","#))
        #expect(pending.id == "p3f9aKq2xy" && pending.step == "package/install" && pending.status == .pending && pending.isOpen)
        #expect(pending.title == "Install the package acme/linear" && pending.rationale == "You asked for Linear.")
        #expect(pending.summary?.hasPrefix("acme/linear 1.0.0 (MIT) from acme") == true && pending.summary?.contains("\n") == true)
        #expect(pending.by == .init(workflow: "orchestrator", runId: "r1", actor: "tom"))
        #expect(pending.createdAt == Date(iso8601: "2026-10-31T10:00:00Z"))
        #expect(pending.input == .object(["package": .string("acme/linear")]) && !pending.inputCut)
        let card = try #require(pending.card)
        #expect(card.title == "Install the package acme/linear" && card.accept == "Install" && card.reject == "Don't install" && card.full)
        // Fields that are a label and a value, in order; a kind not known reads as text; extras ignored.
        #expect(card.fields.map(\.label) == ["Version and license", "Publisher key", "Needs", "Runs code", "Docs", "Odd"])
        #expect(card.fields.map(\.kind) == [.text, .code, .text, .text, .markdown, .text])
        #expect(card.fields.map(\.danger) == [false, false, false, true, false, false] && card.hasDanger)
        #expect(pending.shownCard == card)

        let accepted = try ProposalRecord(strut: Self.json(#""status":"accepted","decision":{"action":"accept","by":"tom","at":"2026-10-31T10:05:00Z"},"#))
        #expect(accepted.status == .accepted && accepted.isOpen && accepted.decision == .init(accepted: true, by: "tom", at: Date(iso8601: "2026-10-31T10:05:00Z")))
        let applied = try ProposalRecord(strut: Self.json(#""status":"applied","decision":{"action":"accept","at":"2026-10-31T10:05:00Z"},"result":{"output":{"installed":true},"cost":0.01,"at":"2026-10-31T10:05:03Z"},"#))
        #expect(applied.status == .applied && applied.status.isFinal && applied.result == .init(error: nil, at: Date(iso8601: "2026-10-31T10:05:03Z")))
        let rejected = try ProposalRecord(strut: Self.json(#""status":"rejected","decision":{"action":"reject","reason":"Not now"},"#))
        #expect(rejected.status == .rejected && rejected.decision?.accepted == false && rejected.decision?.reason == "Not now")
        let failed = try ProposalRecord(strut: Self.json(#""status":"failed","decision":{"action":"accept","at":"2026-10-31T10:05:00Z"},"result":{"error":"The index did not answer.","at":"2026-10-31T10:05:03Z"},"#))
        #expect(failed.status == .failed && failed.result?.error == "The index did not answer.")
        // A status Peel does not know, or no id or step: refused, never guessed.
        #expect(throws: PeelError.self) { try ProposalRecord(strut: Self.json(#""status":"withdrawn","#)) }
        #expect(throws: PeelError.self) { try ProposalRecord(strut: Data(#"{"id":"p3f9aKq2xy","status":"pending","by":{}}"#.utf8)) }
        #expect(throws: PeelError.self) { try ProposalRecord(strut: Data(#"{"id":"../x","step":"x","status":"pending","by":{}}"#.utf8)) }
        #expect(throws: PeelError.self) { try ProposalRecord(strut: Data("[]".utf8)) }
        #expect(ProposalRecord.isID("p3f9aKq2xy") && !ProposalRecord.isID("p3f9aKq2xy\n") && !ProposalRecord.isID("../x") && !ProposalRecord.isID(""))
        // No `by`: read, and no one's (no actor to match a person token).
        let orphan = try ProposalRecord(strut: Data(#"{"id":"p3f9aKq2xy","step":"x","status":"pending"}"#.utf8))
        #expect(orphan.by == .init(workflow: "", runId: "", actor: nil) && orphan.title == "x")
    }

    /// A record from before strut#404 has no card: one is built from the
    /// title, the summary and the input as strut builds a generic one, a
    /// value over the cap cut with strut's marker and `full` false; a card
    /// of another version is as none.
    @Test func aRecordWithoutACardIsDrawnFromItsInput() throws {
        let long = String(repeating: "x", count: 700)
        let record = try ProposalRecord(strut: Data("""
        {"id":"old-record-1","step":"graph/create-node","status":"pending","by":{"workflow":"orchestrator","runId":"r1"},
         "title":"Create a node in the strut knowledge graph.","summary":"S",
         "input":{"node_type":"Concept","node_data":{"name":"Rate limits","docs":"\(long)"},"count":3,"flag":true,"nothing":null}}
        """.utf8))
        #expect(record.card == nil)
        let card = record.shownCard
        #expect(card.title == record.title && card.summary == "S" && card.accept == "Accept" && card.reject == "Reject")
        #expect(card.fields.map(\.label) == ["count", "flag", "node_data", "node_type"])
        #expect(card.fields.map(\.kind) == [.code, .code, .code, .text])
        #expect(card.fields[3].value == "Concept" && card.fields[0].value == "3")
        #expect(card.fields[2].value.hasSuffix(ProposalCard.cutMarker) && card.fields[2].value.count <= ProposalCard.maxValue)
        #expect(!card.full)
        #expect(record.inputText?.contains("\"name\" : \"Rate limits\"") == true)

        let small = ProposalCard.generic(title: "T", summary: nil, input: .object(["a": .string("hi")]))
        #expect(small.fields == [.init(label: "a", value: "hi")] && small.full)
        let many = ProposalCard.generic(title: "T", summary: nil, input: .object(Dictionary(uniqueKeysWithValues: (0..<15).map { ("k\($0)", JSONValue.int(Int64($0))) })))
        #expect(many.fields.count == ProposalCard.maxFields && !many.full)
        #expect(ProposalCard.generic(title: "T", summary: nil, input: .string("just text")).fields == [.init(label: "input", value: "just text", kind: .code)])
        #expect(ProposalCard.generic(title: "T", summary: nil, input: nil).fields.isEmpty)
        // An input more than Peel keeps: left out, and the card says not everything is shown.
        let huge = try ProposalRecord(strut: Data("""
        {"id":"huge-record-1","step":"x/y","status":"pending","by":{"workflow":"w","runId":"r"},"title":"T",
         "input":{"blob":"\(String(repeating: "y", count: ProposalRecord.maxInputBytes))"}}
        """.utf8))
        #expect(huge.input == nil && huge.inputCut && huge.inputText == nil && !huge.shownCard.full && huge.shownCard.fields.isEmpty)
        // Another card version is a card Peel cannot read: the input stands in, never whole, and no key accepts it.
        let v2 = try ProposalRecord(strut: Data(#"{"id":"v2-record-11","step":"x/y","status":"pending","by":{"workflow":"w","runId":"r"},"title":"T","card":{"v":2,"title":"T","fields":[{"label":"Node","value":"n1","danger":true}]},"input":{"ref_id":"n1"}}"#.utf8))
        #expect(v2.card == nil && v2.cardUnreadable && !v2.shownCard.full && !v2.acceptsByKey)
        #expect(v2.shownCard.fields == [.init(label: "ref_id", value: "n1")])
        #expect(!record.cardUnreadable && record.acceptsByKey, "no card at all is an old record, read whole from its input")
        #expect(!(try ProposalRecord(strut: Self.json(#""status":"pending","#))).acceptsByKey, "a field warns")
    }

    /// Every word on a card was written by a model or another host: hidden
    /// and direction characters go, a field keeps its lines, a title is one
    /// line, and strut's caps hold whoever wrote the record.
    @Test func theRecordsWordsAreCleanedAndCapped() throws {
        let record = try ProposalRecord(strut: Data("""
        {"id":"clean-record-1","step":"x/y\\u202E","status":"pending","by":{"workflow":"w","runId":"r"},
         "title":"Add\\u200B Concept:\\nTea\\u202E","summary":"one\\r\\ntwo\\n\\n\\n\\nthree\\u0007","rationale":"\\u2066why\\u2069",
         "card":{"v":1,"title":"Add Concept: Tea","fields":[{"label":"a\\nb","value":"line\\tone\\nline two\\u200B","danger":"true"},
                 {"label":"long","value":"\(String(repeating: "z", count: 3000))"},
                 {"label":"code","value":"{\\n  \\"a\\": 1,  \\n    \\"b\\": 2\\n}\\n\\n\\n","kind":"code"}],"actions":{"accept":"<<<Go\\n","reject":""},"full":"false"}}
        """.utf8))
        #expect(record.step == "x/y" && record.title == "Add Concept: Tea" && record.summary == "one\ntwo\n\nthree" && record.rationale == "why")
        let card = try #require(record.card)
        #expect(card.fields[0].label == "a b" && card.fields[0].value == "line\tone\nline two" && card.fields[0].danger)
        #expect(card.fields[1].value.count == ProposalCard.maxValue && card.fields[1].value.hasSuffix("…"))
        // Indentation stays (code reads as code); trailing blanks and lines go.
        #expect(card.fields[2].value == "{\n  \"a\": 1,\n    \"b\": 2\n}")
        #expect(card.accept == "<< <Go" && card.reject == "Reject" && !card.full)
    }

    /// What is kept of a proposal survives a reopen as it was read, a later
    /// read replaces it (its first final read noted once), and a
    /// workspace's long final one is forgotten while Peel's own strut's stay.
    @Test func keptProposalsSurviveAReopenAndOldWorkspaceOnesGo() throws {
        let profile = TempProfile()
        let record = try ProposalRecord(strut: Self.json(#""status":"pending","#))
        let readAt = Date(timeIntervalSince1970: 1_800_000_000)
        do {
            let storage = try profile.storage()
            try storage.keepProposal(KeptProposal(source: .local, record: record, request: "proposal:p3f9aKq2xy", notAfter: 1_800_086_400, readAt: readAt))
            var org = KeptProposal(source: .org("acme"), record: record, readAt: readAt)
            org.record.id = "acme-record-01"
            try storage.keepProposal(org)
            var old = org
            old.record.id = "acme-record-02"
            old.record.status = .applied
            old.ending = .final(readAt.addingTimeInterval(-8 * 24 * 3600))
            try storage.keepProposal(old)
            var oldLocal = KeptProposal(source: .local, record: record, request: "proposal:older", readAt: readAt, answeredAt: readAt)
            oldLocal.record.id = "local-record-02"
            oldLocal.record.status = .rejected
            oldLocal.ending = old.ending
            try storage.keepProposal(oldLocal)
            var gone = org
            gone.record.id = "acme-record-03"
            gone.ending = .gone(readAt)
            try storage.keepProposal(gone)
        }
        let storage = try profile.storage()
        var kept = try storage.proposals()
        #expect(kept.count == 5)
        let local = try #require(kept.first { $0.record.id == "p3f9aKq2xy" })
        #expect(local.source == .local && local.request == "proposal:p3f9aKq2xy" && local.notAfter == 1_800_086_400 && local.readAt == readAt && !local.isOver)
        #expect(kept.first { $0.record.id == "local-record-02" }?.answeredAt == readAt)
        #expect(kept.first { $0.record.id == "acme-record-03" }?.ending == .gone(readAt), "how it ended comes back")
        #expect(local.record == record && local.key == ProposalKey(source: .local, id: "p3f9aKq2xy"))
        #expect(kept.first { $0.record.id == "acme-record-01" }?.source == .org("acme"))
        // Expired while open on this Mac: past the card's time, and never a workspace's.
        #expect(local.isExpired(at: Date(timeIntervalSince1970: 1_800_086_401)) && !local.isExpired(at: Date(timeIntervalSince1970: 1_800_086_400)))
        #expect(!kept.first { $0.record.id == "acme-record-01" }!.isExpired(at: .distantFuture))
        // A later read: the record in its place, final noted once.
        var applied = record
        applied.status = .applied
        let later = local.updated(with: applied, at: readAt.addingTimeInterval(60))
        #expect(later.ending == .final(readAt.addingTimeInterval(60)) && later.readAt == readAt.addingTimeInterval(60))
        #expect(later.updated(with: applied, at: readAt.addingTimeInterval(120)).ending == .final(readAt.addingTimeInterval(60)))
        // strut says it is open after all: open again here.
        #expect(later.updated(with: record, at: readAt.addingTimeInterval(180)).ending == nil)
        try storage.keepProposal(later)
        kept = try storage.proposals()
        #expect(kept.count == 5 && kept.first { $0.record.id == "p3f9aKq2xy" }?.record.status == .applied)
        try storage.forgetOrgProposals(endedBefore: readAt.addingTimeInterval(-7 * 24 * 3600))
        #expect(Set(try storage.proposals().map(\.record.id)) == ["p3f9aKq2xy", "acme-record-01", "acme-record-03", "local-record-02"])
    }

    /// A workspace's strut asked with the person's token: only their own
    /// pending proposals (another person's never shown, though a strut from
    /// before #404 lists them), one record by id (gone, or not theirs), and a
    /// decision as strut answers it.
    @Test func aWorkspacesProposalsAreReadAndDecidedWithThePersonsToken() async throws {
        let mine = String(decoding: Self.json(#""status":"pending","#), as: UTF8.self)
        let theirs = mine.replacingOccurrences(of: #""actor":"tom""#, with: #""actor":"kate""#).replacingOccurrences(of: "p3f9aKq2xy", with: "kates-record")
        let applied = String(decoding: Self.json(#""status":"applied","decision":{"action":"accept","by":"tom","at":"2026-10-31T10:05:00Z"},"result":{"at":"2026-10-31T10:05:03Z"},"#), as: UTF8.self)
        let strut = try await HTTPStub { _, request in
            guard request.contains("Authorization: Bearer person-token") else { return (401, #"{"error":"unauthorized"}"#) }
            let line = request.prefix { $0 != "\r" }
            switch true {
            case line.hasPrefix("GET /lab/proposals?status=pending "):
                return (200, #"{"proposals":[\#(mine),\#(theirs),{"id":"odd","status":"strange"}]}"#)
            case line.hasPrefix("GET /lab/proposals/p3f9aKq2xy "): return (200, mine)
            case line.hasPrefix("GET /lab/proposals/another-one "): return (200, mine)
            case line.hasPrefix("GET /lab/proposals/kates-record "): return (404, #"{"error":"No proposal"}"#)
            case line.hasPrefix("GET /lab/proposals/secret-one "): return (403, #"{"error":"forbidden"}"#)
            case line.hasPrefix("GET /lab/proposals/broken-one "): return (500, #"{"error":"boom"}"#)
            case line.hasPrefix("POST /lab/proposals/p3f9aKq2xy/decide "):
                return request.contains(#"{"action":"accept"}"#) ? (200, applied) : (400, #"{"error":"action must be 'accept' or 'reject'"}"#)
            case line.hasPrefix("POST /lab/proposals/kates-record/decide "): return (403, #"{"error":"forbidden: proposal \"kates-record\" is not yours to decide"}"#)
            case line.hasPrefix("POST /lab/proposals/done-before/decide "):
                return (409, #"{"error":"Proposal is applied","proposal":\#(applied.replacingOccurrences(of: "p3f9aKq2xy", with: "done-before"))}"#)
            case line.hasPrefix("POST /lab/proposals/odd-answer/decide "): return (409, #"{"error":"decided","proposal":\#(applied)}"#)
            case line.hasPrefix("POST /lab/proposals/vanished/decide "): return (404, "{}")
            default: return (500, "{}")
            }
        }
        defer { strut.stop() }
        let peer = HivePeer(id: "acme", baseUrl: "http://127.0.0.1:\(strut.port)/lab", token: "person-token", label: "Acme")
        let (listed, others) = try await peer.pendingProposals(actor: "tom")
        #expect(listed.map(\.id) == ["p3f9aKq2xy"] && others == 1)
        #expect(try await peer.proposal("p3f9aKq2xy") == .record(listed[0]))
        #expect(try await peer.proposal("kates-record") == .gone)
        #expect(try await peer.proposal("secret-one") == .forbidden)
        await #expect(throws: PeelError.self) { try await peer.proposal("../etc") }
        // A strut answering for another proposal is not read; one failing refuses by status.
        await #expect(throws: PeelError.self) { try await peer.proposal("another-one") }
        await #expect(throws: StrutRefusal(status: 500, name: "Acme")) { try await peer.proposal("broken-one") }
        guard case .decided(let after) = try await peer.decide("p3f9aKq2xy", accept: true) else {
            Issue.record("not decided")
            return
        }
        #expect(after.status == .applied && after.decision?.by == "tom")
        #expect(try await peer.decide("kates-record", accept: false) == .notYours("forbidden: proposal \"kates-record\" is not yours to decide"))
        var doneBefore = after
        doneBefore.id = "done-before"
        #expect(try await peer.decide("done-before", accept: true) == .alreadyDecided(doneBefore, "Proposal is applied"))
        // A 409 whose record is another proposal's: the words alone.
        #expect(try await peer.decide("odd-answer", accept: true) == .alreadyDecided(nil, "decided"))
        #expect(try await peer.decide("vanished", accept: true) == .gone)
        // Decided with the token, the action alone, never an edit to the input.
        let decide = try #require(strut.requests.first { $0.hasPrefix("POST /lab/proposals/p3f9aKq2xy/decide") })
        #expect(decide.hasSuffix(#"{"action":"accept"}"#) && decide.contains("Authorization: Bearer person-token"))
        // A workspace whose address Peel would not send a token to; one that no longer takes the token.
        let plain = HivePeer(id: "acme", baseUrl: "http://acme.example/lab", token: "person-token")
        await #expect(throws: PeelError.self) { try await plain.pendingProposals(actor: "tom") }
        let stale = HivePeer(id: "acme", baseUrl: "http://127.0.0.1:\(strut.port)/lab", token: "old-token", label: "Acme")
        await #expect(throws: StrutRefusal(status: 401, name: "Acme")) { try await stale.pendingProposals(actor: "tom") }
        #expect(StrutRefusal(status: 401, name: "Acme").isAuth && !StrutRefusal(status: 500, name: "Acme").isAuth)
    }
}

// MARK: - In a tribe

extension ProposalTests {
    /// Jamie's post in a tribe, with the proposals it made (`metadata.strut`,
    /// docs/hive-tribes.md, "Proposals in a tribe").
    static func post(workspace: String = "acme", proposals: String, type: Int = MessageType.text, deleted: Bool = false,
                     uuid: String = "post-1", replyTo: String? = nil, alias: String = "Jamie", at timestamp: Int64 = 1_800_000_000_000) throws -> Message {
        let metadata = #"{"strut":{"workspace":"\#(workspace)","artifacts":[],"proposals":\#(proposals)}}"#
        var message = Message.fixture(uuid: uuid, type: type, chat: "02tribe", fromMe: false, sender: sender(alias: alias),
                                      body: try Engine.json(["content": "Waiting for Tom to approve", "metadata": metadata]),
                                      content: "Waiting for Tom to approve", timestamp: timestamp, replyUUID: replyTo, threadUUID: replyTo)
        message.deleted = deleted
        return message
    }

    static let proposedEntries = #"""
        [{"id":"p-install-1","step":"package/install","title":"Install the package acme/linear",
          "summary":"acme/linear 1.0.0 (MIT) from acme.\nIt needs the secret LINEAR_KEY.",
          "card":{"v":1,"title":"Install the package acme/linear","fields":[{"label":"Version","value":"1.0.0 (MIT)"},{"label":"Runs code","value":"Yes","danger":true}],
                  "actions":{"accept":"Install","reject":"Don't install"},"full":true},
          "status":"pending","url":"/proposals/p-install-1","rationale":"You asked for Linear.","createdAt":"2026-10-31T10:00:00Z","extra":1},
         {"id":"p-node-2","step":"graph/create-node","title":"Create a node","status":"pending","url":"/proposals/p-node-2"},
         {"id":"bad status","step":"x","status":"weird","url":"/proposals/x"},
         {"id":"no-step","status":"pending","url":"/proposals/no-step"},
         {"id":"p-install-1","step":"package/install","title":"Twice","status":"pending","url":"/proposals/p-install-1"},
         "not an object"]
        """#

    static let outcomeEntries = #"""
        [{"id":"p-install-1","status":"failed","title":"Install the package acme/linear","step":"package/install","error":"npm said no‮"}]
        """#

    /// A post that made proposals gives each as a card (one with strut's
    /// card, one without); a reply says how one ended; what Peel cannot
    /// read is skipped; a workspace that is no peer id, a post that is not
    /// text, a deleted one, or one naming no proposal gives nothing.
    @Test func aTribePostsProposalsAndTheirOutcomesAreRead() throws {
        let post = try #require(Self.post(proposals: Self.proposedEntries).strutProposals)
        #expect(post.workspace == "acme" && post.outcomes.isEmpty)
        #expect(post.proposed.map(\.id) == ["p-install-1", "p-node-2"], "a status not known, no step, not an object, an id twice: skipped")
        let install = post.proposed[0]
        #expect(install.step == "package/install" && install.status == .pending && install.rationale == "You asked for Linear.")
        #expect(install.summary == "acme/linear 1.0.0 (MIT) from acme.\nIt needs the secret LINEAR_KEY.")
        #expect(install.card?.accept == "Install" && install.card?.hasDanger == true && install.card?.fields.count == 2)
        #expect(install.createdAt == Date(iso8601: "2026-10-31T10:00:00Z") && install.input == nil)
        #expect(post.proposed[1].card == nil && post.proposed[1].shownCard.title == "Create a node" && post.proposed[1].shownCard.fields.isEmpty)
        #expect(post.proposed[1].acceptsByKey, "a card built from the post, nothing in it warns")

        let reply = try #require(Self.post(proposals: Self.outcomeEntries, uuid: "reply-1", replyTo: "post-1").strutProposals)
        #expect(reply.proposed.isEmpty && reply.outcomes.count == 1)
        #expect(reply.outcomes[0].id == "p-install-1" && reply.outcomes[0].status == .failed && reply.outcomes[0].result?.error == "npm said no", "the error cleaned")

        #expect(try Self.post(workspace: "not a peer id!", proposals: Self.proposedEntries).strutProposals == nil)
        #expect(try Self.post(proposals: Self.proposedEntries, type: MessageType.attachment).strutProposals == nil)
        #expect(try Self.post(proposals: Self.proposedEntries, deleted: true).strutProposals == nil)
        #expect(try Self.post(proposals: "[]").strutProposals == nil)
        #expect(try Self.post(proposals: #"[{"id":"p-install-1","step":"package/install","status":"pending"}]"#).strutProposals == nil,
                "an outcome saying pending says nothing")
        #expect(try Self.post(proposals: #"["not an object"]"#).strutProposals == nil)
        let artifactsOnly = Message.fixture(uuid: "d1", chat: "02tribe", sender: sender(alias: "Jamie"),
                                            body: try Engine.json(["content": "a plan", "metadata": #"{"strut":{"workspace":"acme","artifacts":[{"title":"Plan","url":"https://acme.example/plan"}]}}"#]))
        #expect(artifactsOnly.strutProposals == nil && artifactsOnly.strutArtifacts.count == 1)
    }

    /// What the tribe's posts say of a kept proposal, in whichever order
    /// they come: the post that made it gives the card and where it is,
    /// its reply how it ended, and the later word wins, so a copy of the
    /// post coming round again never reopens a decided one, nor does a
    /// reply; a record read from strut first keeps its input and takes the
    /// posts' clock; the owner's answer that Jamie has not ended in time
    /// is stale, and only then.
    @Test func aTribesPostsMoveAKeptProposalInAnyOrder() throws {
        let made = try #require(Self.post(proposals: Self.proposedEntries).strutProposals).proposed[0]
        let ended = try #require(Self.post(proposals: Self.outcomeEntries, uuid: "reply-1", replyTo: "post-1").strutProposals).outcomes[0]
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let t1 = t0.addingTimeInterval(60)
        let post = TribePost(tribe: "02tribe", uuid: "post-1", poster: "Jamie")
        // Made, then ended.
        var kept = KeptProposal(source: .org("acme"), record: made, readAt: t0, post: post)
        #expect(!kept.isOver && kept.post == post && !kept.fromStrut)
        kept.take(outcome: ended, at: t1)
        #expect(kept.record.status == .failed && kept.record.result?.error == "npm said no" && kept.ending == .final(t1) && kept.readAt == t1)
        #expect(kept.record.card?.accept == "Install", "the card stays")
        kept.take(carrier: made, on: post, at: t0)
        #expect(kept.record.status == .failed && kept.ending == .final(t1) && kept.readAt == t1, "the post coming round again changes nothing")
        // Ended, then made.
        var late = KeptProposal(source: .org("acme"), record: ended, readAt: t1, post: post)
        #expect(late.isOver && late.record.card == nil)
        late.take(carrier: made, on: post, at: t0)
        #expect(late.record.card?.accept == "Install" && late.record.rationale == "You asked for Linear.")
        #expect(late.record.status == .failed && late.record.result?.error == "npm said no" && late.ending == .final(t1) && late.post == post)
        // A reply never reopens a decided one, nor says "pending" of it; an older reply says nothing.
        var open = ended
        open.status = .pending
        late.take(outcome: open, at: t1.addingTimeInterval(60))
        var applied = ended
        applied.status = .applied
        late.take(outcome: applied, at: t0)
        #expect(late.record.status == .failed && late.ending == .final(t1))
        // strut's record read first (the owner's list, dated by this Mac's clock) keeps its input
        // when the post has none, and takes the posts' clock from the post on.
        var listed = KeptProposal(source: .org("acme"), record: made, readAt: t1.addingTimeInterval(3600))
        listed.record.input = .object(["package": .string("acme/linear")])
        #expect(listed.fromStrut)
        listed.take(carrier: made, on: post, at: t0)
        #expect(listed.record.input != nil && listed.post == post && listed.readAt == t0 && !listed.fromStrut)
        listed.take(outcome: ended, at: t1)
        #expect(listed.record.status == .failed, "a reply dated before the list's read still counts")
        // The owner's answer, waiting on Jamie.
        var answered = KeptProposal(source: .org("acme"), record: made, readAt: t0, answeredAt: t1, post: post, answer: true)
        #expect(answered.answerStaleAt == t1.addingTimeInterval(KeptProposal.answerPatience))
        #expect(!answered.isAnswerStale(at: t1.addingTimeInterval(KeptProposal.answerPatience - 1)))
        #expect(answered.isAnswerStale(at: t1.addingTimeInterval(KeptProposal.answerPatience)))
        answered.record.status = .accepted
        #expect(answered.answerStaleAt == nil, "the step runs: Jamie has it")
        answered.record.status = .pending
        answered.ending = .final(t1)
        #expect(answered.answerStaleAt == nil)
        var notInATribe = answered
        notInATribe.ending = nil
        notInATribe.post = nil
        #expect(notInATribe.answerStaleAt == nil)
    }

    /// A tribe's proposal comes back from the store with its post and the
    /// owner's answer, and is never forgotten with a workspace's old ones.
    @Test func aTribesProposalIsKeptWithItsPostAndAnswer() throws {
        let profile = TempProfile()
        let made = try #require(Self.post(proposals: Self.proposedEntries).strutProposals).proposed[0]
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let post = TribePost(tribe: "02tribe", uuid: "post-1", poster: "Jamie")
        do {
            let storage = try profile.storage()
            try storage.keepProposal(KeptProposal(source: .org("acme"), record: made, readAt: t0, answeredAt: t0.addingTimeInterval(5), post: post, answer: false))
            var over = KeptProposal(source: .org("acme"), record: made, readAt: t0, ending: .final(t0.addingTimeInterval(-30 * 24 * 3600)), post: post)
            over.record.id = "p-old-tribe"
            over.record.status = .applied
            try storage.keepProposal(over)
            var orgs = KeptProposal(source: .org("acme"), record: made, readAt: t0, ending: .final(t0.addingTimeInterval(-30 * 24 * 3600)))
            orgs.record.id = "p-old-org"
            orgs.record.status = .applied
            try storage.keepProposal(orgs)
        }
        let storage = try profile.storage()
        let kept = try #require(try storage.proposals().first { $0.record.id == "p-install-1" })
        #expect(kept.post == post && kept.answer == false && kept.answeredAt == t0.addingTimeInterval(5) && kept.record.card?.accept == "Install")
        try storage.forgetOrgProposals(endedBefore: t0)
        #expect(Set(try storage.proposals().map(\.record.id)) == ["p-install-1", "p-old-tribe"], "a tribe's stays with its post")
    }

    /// The tribes' posts that may name a proposal, read from where the last
    /// look got to: someone else's text in a tribe whose body says
    /// `proposals`, never a direct message's or your own; the mark moves to
    /// the highest message stored, so the next look reads nothing twice.
    @Test func theTribesPostsNamingProposalsAreReadFromTheLastLook() throws {
        let profile = TempProfile()
        let storage = try profile.storage()
        let post = try Self.post(proposals: Self.proposedEntries, uuid: uuid(1))
        var mine = try Self.post(proposals: Self.proposedEntries, uuid: uuid(2))
        mine.fromMe = true
        var inDM = try Self.post(proposals: Self.proposedEntries, uuid: uuid(3))
        inDM.chat = "02dm"
        let plain = Message.fixture(uuid: uuid(4), chat: "02tribe", sender: sender(alias: "Kate"), content: "no proposals here", timestamp: 1_800_000_001_000)
        _ = try storage.apply(Storage.Commit(
            contacts: [(pubkey: "02tribe", ready: true), (pubkey: "02dm", ready: true)],
            messages: [(post, false, nil), (mine, false, nil), (inDM, false, nil), (plain, false, nil)],
            tribes: [Tribe(pubkey: "02tribe", name: "jamie", isOwner: true)]
        ))
        #expect(try storage.proposalPostsScanned() == 0)
        let first = try storage.proposalPosts(after: 0)
        #expect(first.posts.map(\.uuid) == [uuid(1)], "\(first.posts.map(\.uuid))")
        #expect(first.upTo >= 4)
        try storage.setProposalPostsScanned(first.upTo)
        #expect(try storage.proposalPostsScanned() == first.upTo)
        #expect(try storage.proposalPosts(after: first.upTo).posts.isEmpty)
        let later = try Self.post(proposals: Self.outcomeEntries, uuid: uuid(5), replyTo: uuid(1), at: 1_800_000_002_000)
        _ = try storage.apply(Storage.Commit(messages: [(later, false, nil)]))
        let next = try storage.proposalPosts(after: first.upTo)
        #expect(next.posts.map(\.uuid) == [uuid(5)] && next.upTo > first.upTo)
    }
}
