import Foundation
import Testing
@testable import PeelCore
@testable import PeelTestSupport
@testable import PeelUI

/// The proposals' watch (`ProposalWatch`): what it keeps and draws, how it
/// reads Peel's own strut's records and the workspaces' lists, and how it
/// decides a workspace's as the person.
@MainActor
struct ProposalWatchTests {
    let profile = TempProfile()

    private func record(_ id: String, status: ProposalRecord.Status = .pending, actor: String? = "tom", step: String = "graph/create-node") -> ProposalRecord {
        ProposalRecord(id: id, step: step, title: "Add Concept: \(id)", status: status, createdAt: Date(timeIntervalSince1970: 1_800_000_000),
                       by: .init(workflow: "orchestrator", runId: "r1", actor: actor), input: .object(["name": .string(id)]))
    }

    nonisolated private static func json(_ record: ProposalRecord) -> String {
        """
        {"id":"\(record.id)","step":"\(record.step)","title":"\(record.title)","status":"\(record.status.rawValue)",
         "createdAt":"2026-10-31T10:00:00Z","by":{"workflow":"orchestrator","runId":"r1"\(record.by.actor.map { #","actor":"\#($0)""# } ?? "")},
         "input":{"name":"\(record.id)"}}
        """
    }

    /// A watch over `storage` with a clock of its own, in front.
    private func makeWatch(_ storage: Storage, now: @escaping @MainActor () -> Date = { Date() }) async -> ProposalWatch {
        let watch = ProposalWatch()
        watch.now = now
        await watch.open(storage)
        return watch
    }

    /// Peel's own strut's proposal: kept with its request and expiry, found
    /// by its request, read again from strut after the Mac's answer until it
    /// is final, and back as it was after a reopen; a card past its time is
    /// expired here whatever strut says, and never read again.
    @Test func aLocalProposalIsKeptReadAgainAfterTheAnswerAndSurvivesAReopen() async throws {
        let storage = try profile.storage()
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let watch = await makeWatch(storage) { clock.now }
        let reads = Reads()
        watch.readLocal = { id in await reads.add(id); return try await reads.answer(id) }
        await reads.set("p1", .record(record("p1")))
        watch.keep(record("p1"), source: .local, request: "proposal:p1", notAfter: 1_800_000_000 + 3600)
        let kept = try #require(watch.kept(request: "proposal:p1"))
        #expect(kept.source == .local && kept.record.status == .pending && kept.notAfter == 1_800_000_000 + 3600)
        #expect(watch.orgCards.isEmpty, "Peel's own strut's cards are on their lines, not at the end")
        // Not answered yet: read every half minute at most.
        await watch.tick()
        #expect(await reads.ids.isEmpty)
        clock.advance(31)
        await watch.tick()
        #expect(await reads.ids == ["p1"])
        // Answered: read soon, then once it is applied, no more.
        watch.answered(request: "proposal:p1")
        #expect(watch.kept(request: "proposal:p1")?.answeredAt == clock.now)
        clock.advance(3)
        await watch.tick()
        #expect(await reads.ids == ["p1", "p1"])
        await reads.set("p1", .record(record("p1", status: .applied)))
        clock.advance(5)
        await watch.tick()
        #expect(watch.kept(request: "proposal:p1")?.record.status == .applied)
        #expect(watch.kept(request: "proposal:p1")?.ending == .final(clock.now))
        clock.advance(600)
        await watch.tick()
        #expect(await reads.ids.count == 3, "a final record is not read again")
        // strut not answering keeps what is shown.
        await reads.set("p2", nil)
        watch.keep(record("p2"), source: .local, request: "proposal:p2", notAfter: 1_800_000_000 + 7200)
        watch.answered(request: "proposal:p2")
        clock.advance(3)
        await watch.tick()
        #expect(watch.kept(request: "proposal:p2")?.record.status == .pending && watch.notes.isEmpty)
        // Gone from strut: said, and over.
        await reads.set("p2", .gone)
        clock.advance(10)
        await watch.tick()
        #expect(watch.notes[ProposalKey(source: .local, id: "p2")] == "strut no longer has this proposal.")
        #expect(watch.kept(request: "proposal:p2")?.ending == .gone(clock.now))
        // Closed and opened again (as the account locks and unlocks, on the one
        // watch the app has): as kept, the last writes landed first.
        watch.close()
        #expect(watch.kept(request: "proposal:p1") == nil)
        await watch.open(storage)
        #expect(watch.kept(request: "proposal:p1")?.record.status == .applied)
        #expect(watch.kept(request: "proposal:p2")?.ending == .gone(clock.now))
        // A card past its time, still pending on strut: expired here, read no more.
        await reads.set("p3", .record(record("p3")))
        watch.readLocal = { id in await reads.add(id); return try await reads.answer(id) }
        watch.keep(record("p3"), source: .local, request: "proposal:p3", notAfter: Int64(clock.now.timeIntervalSince1970) + 10)
        clock.advance(11)
        let p3 = try #require(watch.kept(request: "proposal:p3"))
        #expect(p3.isExpired(at: clock.now))
        let before = await reads.ids.count
        clock.advance(60)
        await watch.tick()
        #expect(await reads.ids.count == before)
    }

    /// The workspaces' pending proposals of the person, listed with their
    /// token: another person's never shown; one no longer listed read by
    /// itself; the cards at the end of the chat while open and for a while
    /// after; a decision made here as the person, and what strut says of
    /// it: decided, decided before, not this person's (and on a strut that
    /// listed everyone's, that it needs an update), gone.
    @Test func aWorkspacesProposalsAreListedDecidedAndShownAtTheEnd() async throws {
        let storage = try profile.storage()
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let state = StrutState()
        state.keep(record("a1"))
        state.keep(record("a2"))
        state.keep(record("k1", actor: "kate"))
        let strut = try await HTTPStub { _, request in
            let line = String(request.prefix { $0 != "\r" })
            return state.answer(line, body: String(request[(request.range(of: "\r\n\r\n")?.upperBound ?? request.endIndex)...]), json: Self.json)
        }
        defer { strut.stop() }
        let watch = await makeWatch(storage) { clock.now }
        let acme = HivePeer(id: "acme", baseUrl: "http://127.0.0.1:\(strut.port)", token: "t", label: "Acme")
        watch.orgs = { ([acme], "tom") }
        await watch.tick()
        #expect(watch.orgCards.map(\.kept.record.id) == ["a1", "a2"], "\(watch.orgCards.map(\.kept.record.id))")
        #expect(watch.orgCards.first?.org == "Acme" && watch.orgName(.org("acme")) == "Acme" && watch.orgName(.local) == nil)
        let a1 = ProposalKey(source: .org("acme"), id: "a1")
        // Decided here: strut's record after, final at once, and the card stays a while.
        await watch.decide(a1, accept: true)
        #expect(watch.kept[a1]?.record.status == .applied && watch.kept[a1]?.ending == .final(clock.now))
        #expect(state.decisions == ["a1 accept"])
        #expect(watch.orgCards.map(\.kept.record.id) == ["a1", "a2"])
        clock.advance(ProposalWatch.shownAfterOver + 1)
        await watch.tick()
        #expect(watch.orgCards.map(\.kept.record.id) == ["a2"])
        // Decided in Stadeum meanwhile: no longer listed, read by itself, its state shown a while, then gone.
        state.keep(record("a2", status: .rejected))
        clock.advance(ProposalWatch.listEvery)
        await watch.tick()
        #expect(watch.kept[ProposalKey(source: .org("acme"), id: "a2")]?.record.status == .rejected)
        #expect(watch.orgCards.map(\.kept.record.id) == ["a2"])
        clock.advance(ProposalWatch.shownAfterOver + 1)
        state.keep(record("a3"))
        await watch.tick()
        let a3 = ProposalKey(source: .org("acme"), id: "a3")
        #expect(watch.orgCards.map(\.kept.record.id) == ["a3"])
        // Decided twice: 409 with the record, kept as it stands.
        state.keep(record("a3", status: .applied))
        await watch.decide(a3, accept: false)
        #expect(watch.kept[a3]?.record.status == .applied && state.decisions.count == 1, "409: nothing decided twice")
        #expect(watch.orgCards.map(\.kept.record.id) == ["a3"], "final, shown a while")
        clock.advance(ProposalWatch.shownAfterOver + 1)
        // Not this person's to decide: said on the card, and the strut listed others' (an old one).
        let k1 = ProposalKey(source: .org("acme"), id: "k1")
        #expect(watch.kept[k1] == nil, "another person's proposal is never kept")
        state.keep(record("a4"))
        state.forbid("a4")
        await watch.tick()
        let a4 = ProposalKey(source: .org("acme"), id: "a4")
        #expect(watch.orgCards.map(\.kept.record.id) == ["a4"])
        await watch.decide(a4, accept: true)
        #expect(watch.notes[a4]?.hasPrefix("You can't decide this one here: Acme's workspace runs an older strut") == true)
        #expect(watch.kept[a4]?.record.status == .pending && watch.orgCards.map(\.kept.record.id) == ["a4"])
        #expect(watch.orgCards.first?.note == watch.notes[a4], "the card carries its note")
        // Not to be decided yet (it waits on another proposal first): 409 with the pending record and strut's words.
        state.keep(record("a5"))
        state.hold("a5")
        clock.advance(ProposalWatch.listEvery)
        await watch.tick()
        let a5 = ProposalKey(source: .org("acme"), id: "a5")
        await watch.decide(a5, accept: true)
        #expect(watch.kept[a5]?.record.status == .pending && watch.notes[a5] == "Proposal \"a5\" applies after \"a0\": decide that one first.")
        // Gone: said, and over.
        state.remove("a4")
        await watch.decide(a4, accept: true)
        #expect(watch.notes[a4] == "Acme no longer has this proposal." && watch.kept[a4]?.ending == .gone(clock.now))
        // The token refused: said on the cards, not "not answering".
        state.refuseToken()
        clock.advance(ProposalWatch.listEvery)
        await watch.tick()
        #expect(watch.refused["acme"]?.hasPrefix("Acme no longer takes this device's token") == true && watch.unreachable.isEmpty)
        #expect(watch.orgCards.allSatisfy { $0.note == watch.refused["acme"] || $0.note == watch.notes[$0.key] })
        state.takeToken()
        // A workspace that does not answer keeps what is shown and is marked.
        strut.stop()
        clock.advance(ProposalWatch.listEvery)
        await watch.tick()
        #expect(watch.unreachable == ["acme"] && watch.kept[a4] != nil)
        // Closed and opened again: a workspace's are kept too, and with no workspace
        // paired now there is nothing of a workspace's to decide here, so no card.
        watch.close()
        watch.orgs = { ([], nil) }
        await watch.open(storage)
        #expect(watch.kept[a1]?.record.status == .applied && watch.kept[a3] != nil)
        #expect(watch.orgCards.isEmpty)
    }

    /// The clock a test moves.
    @MainActor private final class Clock {
        var now: Date
        init(_ now: Date) { self.now = now }
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    /// Peel's own strut as the watch reads it: each id's answer, and the reads made.
    private actor Reads {
        private(set) var ids: [String] = []
        private var answers: [String: ProposalRead?] = [:]
        func add(_ id: String) { ids.append(id) }
        func set(_ id: String, _ read: ProposalRead?) { answers[id] = .some(read) }
        func answer(_ id: String) throws -> ProposalRead {
            guard let read = answers[id] ?? nil else { throw PeelError("strut is not running") }
            return read
        }
    }

    /// A workspace's strut: its records, who may not decide, and the decisions taken.
    private final class StrutState: @unchecked Sendable {
        private let lock = NSLock()
        private var records: [String: ProposalRecord] = [:]
        private var forbidden: Set<String> = []
        private var held: Set<String> = []
        private var refusing = false
        private var decided: [String] = []
        var decisions: [String] { lock.withLock { decided } }
        func keep(_ record: ProposalRecord) { lock.withLock { records[record.id] = record } }
        func remove(_ id: String) { lock.withLock { records[id] = nil } }
        func forbid(_ id: String) { lock.withLock { forbidden.insert(id) } }
        /// `id` applies after another proposal, still pending.
        func hold(_ id: String) { lock.withLock { held.insert(id) } }
        func refuseToken() { lock.withLock { refusing = true } }
        func takeToken() { lock.withLock { refusing = false } }

        func answer(_ line: String, body: String, json: (ProposalRecord) -> String) -> (Int, String) {
            lock.withLock {
                if refusing { return (401, #"{"error":"unauthorized"}"#) }
                if line.hasPrefix("GET /proposals?status=pending ") {
                    // As a strut from before #404 answers: everyone's.
                    let pending = records.values.filter { $0.status == .pending }.sorted { $0.id < $1.id }.map(json)
                    return (200, #"{"proposals":[\#(pending.joined(separator: ","))]}"#)
                }
                let parts = line.split(separator: " ")
                guard parts.count >= 2 else { return (400, "{}") }
                let path = parts[1].split(separator: "/").map(String.init)
                guard path.count >= 2, path[0] == "proposals", let record = records[path[1]] else { return (404, #"{"error":"No proposal"}"#) }
                if parts[0] == "GET" { return (200, json(record)) }
                guard parts[0] == "POST", path.count == 3, path[2] == "decide" else { return (404, "{}") }
                if forbidden.contains(record.id) { return (403, #"{"error":"forbidden: not yours"}"#) }
                if held.contains(record.id) {
                    return (409, #"{"error":"Proposal \"\#(record.id)\" applies after \"a0\": decide that one first.","proposal":\#(json(record))}"#)
                }
                guard record.status == .pending else { return (409, #"{"error":"decided","proposal":\#(json(record))}"#) }
                let accept = body.contains(#""action":"accept""#)
                decided.append("\(record.id) \(accept ? "accept" : "reject")")
                var after = record
                after.status = accept ? .applied : .rejected
                records[record.id] = after
                return (200, json(after))
            }
        }
    }
}
