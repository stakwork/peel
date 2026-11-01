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

    /// A watch over `storage` with a clock of its own, in front. Its
    /// tribes are known only once it is open, as `AppModel` opens it: the
    /// account lists its tribes after.
    private func makeWatch(_ storage: Storage, now: @escaping @MainActor () -> Date = { Date() }) async -> ProposalWatch {
        let watch = ProposalWatch()
        watch.now = now
        await watch.open(storage)
        watch.isTribe = { ["02tribe", "02other"].contains($0) }
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

    /// A proposal on Jamie's post in a tribe (docs/hive-tribes.md,
    /// "Proposals in a tribe"): kept from the post as it arrives, never
    /// listed as a workspace's card nor read from the workspace's strut
    /// (that would say "not yours" to anyone but the owner); answered by
    /// the owner's reply to the post with the card's own word; ended by
    /// Jamie's reply in the post's thread and by no one else's, in
    /// whichever order the posts come; a reply that could not go said on
    /// the card; and back after a reopen with its post and answer.
    @Test func aProposalOnJamiesPostIsKeptAnsweredByAReplyAndEndedByJamiesWord() async throws {
        let storage = try profile.storage()
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        // The workspace lists the same proposal to its owner, and has no record to read by itself (404).
        let state = StrutState()
        let json = Self.json
        let strut = try await HTTPStub { _, request in
            let line = String(request.prefix { $0 != "\r" })
            if line.hasPrefix("GET /proposals/") { return (404, #"{"error":"No proposal"}"#) }
            return state.answer(line, body: "", json: json)
        }
        defer { strut.stop() }
        state.keep(record("p-install-1", step: "package/install"))
        let watch = await makeWatch(storage) { clock.now }
        watch.orgs = { ([HivePeer(id: "acme", baseUrl: "http://127.0.0.1:\(strut.port)", token: "t", label: "Acme")], "tom") }
        let replies = Replies()
        watch.sendReply = { text, tribe, post in try await replies.send(text, tribe, post) }
        let tribe = "02tribe"
        let key = ProposalKey(source: .org("acme"), id: "p-install-1")
        let t0 = Int64(1_800_000_000_000)
        let (post1, post2, post3) = (uuid(1), uuid(2), uuid(3))

        // Jamie's post that made it: a card under that post, not at the end of the agent chat.
        watch.noticed(try Self.tribePost(uuid: post1, in: tribe, proposals: Self.proposedEntries, at: t0))
        let kept = try #require(watch.kept[key])
        #expect(kept.post == TribePost(tribe: tribe, uuid: post1, poster: "Jamie") && kept.record.status == .pending && kept.record.card?.accept == "Install")
        #expect(kept.readAt == Date(millisecondsSince1970: t0))
        await watch.tick()
        #expect(watch.orgCards.isEmpty, "the card is under the post alone")
        clock.advance(ProposalWatch.listEvery + ProposalWatch.reReadEvery)
        await watch.tick()
        #expect(watch.kept[key]?.ending == nil && watch.notes[key] == nil, "never read from the workspace's strut by itself")
        #expect(watch.kept[key]?.post != nil)
        // Your own post, a deleted one, a copy of the post again: nothing new.
        var mine = try Self.tribePost(uuid: uuid(20), in: tribe, proposals: Self.proposedEntries, at: t0 + 1)
        mine.fromMe = true
        watch.noticed(mine)
        watch.noticed(try Self.tribePost(uuid: post1, in: tribe, proposals: Self.proposedEntries, at: t0))
        #expect(watch.kept[key]?.post?.uuid == post1 && watch.kept.count == 1)

        // The owner's answer: a reply to the post with the card's word; the reply, arriving
        // as any message of yours, is the answer (from this device or the other).
        await watch.answerInTribe(key, accept: true)
        #expect(await replies.sent == [["Install", tribe, post1]])
        #expect(watch.kept[key]?.answer == nil, "the reply itself says so")
        watch.answered(byOwn: Self.ownReply("Install", uuid: uuid(21), in: tribe, replyTo: post1, at: t0 + 1_000))
        #expect(watch.kept[key]?.answer == true && watch.kept[key]?.answeredAt == Date(millisecondsSince1970: t0 + 1_000))
        #expect(watch.kept[key]?.record.status == .pending)
        // A reply of yours with other words, in another thread, or older: not an answer.
        watch.answered(byOwn: Self.ownReply("Looks fine", uuid: uuid(22), in: tribe, replyTo: post1, at: t0 + 1_100))
        watch.answered(byOwn: Self.ownReply("Don't install", uuid: uuid(23), in: tribe, replyTo: uuid(9), at: t0 + 1_200))
        watch.answered(byOwn: Self.ownReply("Don't install", uuid: uuid(24), in: tribe, replyTo: post1, at: t0 + 900))
        #expect(watch.kept[key]?.answer == true)
        // A later reply the other way (from your other device, say) is the answer now.
        watch.answered(byOwn: Self.ownReply("Don't install", uuid: uuid(25), in: tribe, replyTo: post1, at: t0 + 1_300))
        #expect(watch.kept[key]?.answer == false)
        // Someone else's word in the thread, Jamie's elsewhere: not its end.
        watch.noticed(try Self.tribePost(uuid: uuid(11), in: tribe, proposals: Self.outcomeEntries, replyTo: post1, alias: "Kate", at: t0 + 2_000))
        watch.noticed(try Self.tribePost(uuid: uuid(12), in: tribe, proposals: Self.outcomeEntries, replyTo: uuid(9), at: t0 + 3_000))
        watch.noticed(try Self.tribePost(uuid: uuid(13), in: "02other", proposals: Self.outcomeEntries, replyTo: post1, at: t0 + 3_500))
        #expect(watch.kept[key]?.record.status == .pending && watch.kept[key]?.isOver == false)
        // Jamie's word in the post's thread: ended.
        watch.noticed(try Self.tribePost(uuid: uuid(14), in: tribe, proposals: Self.outcomeEntries, replyTo: post1, at: t0 + 4_000))
        let ended = try #require(watch.kept[key])
        #expect(ended.record.status == .failed && ended.record.result?.error == "npm said no" && ended.ending == .final(Date(millisecondsSince1970: t0 + 4_000)))
        #expect(ended.post?.uuid == post1 && ended.record.card?.accept == "Install")
        await watch.answerInTribe(key, accept: false)
        #expect(await replies.sent.count == 1, "nothing to answer once it is over")

        // Jamie's word before its post (history in another order): kept as ended, then the post fills in the card.
        let node = ProposalKey(source: .org("acme"), id: "p-node-2")
        let nodeDone = #"[{"id":"p-node-2","status":"applied","title":"Create a node","step":"graph/create-node"}]"#
        watch.noticed(try Self.tribePost(uuid: uuid(15), in: tribe, proposals: nodeDone, replyTo: post2, at: t0 + 9_000))
        #expect(watch.kept[node]?.record.status == .applied && watch.kept[node]?.post == TribePost(tribe: tribe, uuid: post2, poster: "Jamie"))
        watch.noticed(try Self.tribePost(uuid: post2, in: tribe, proposals: Self.nodeEntries, at: t0 + 8_000))
        #expect(watch.kept[node]?.record.status == .applied && watch.kept[node]?.record.title == "Create a node" && watch.kept[node]?.isOver == true)
        watch.answered(byOwn: Self.ownReply("Accept", uuid: uuid(26), in: tribe, replyTo: post2, at: t0 + 9_500))
        #expect(watch.kept[node]?.answer == nil, "nothing to answer once it is over")
        // Another post claiming the first proposal is not its card.
        watch.noticed(try Self.tribePost(uuid: uuid(9), in: tribe, proposals: Self.proposedEntries, at: t0 + 8_500))
        #expect(watch.kept[key]?.post?.uuid == post1, "the first post keeps its proposal")

        // A reply that could not go: said on the card, the card not answered.
        state.keep(record("p-grant-3", step: "app/grant"))
        let grant = ProposalKey(source: .org("acme"), id: "p-grant-3")
        let grantMade = #"[{"id":"p-grant-3","step":"app/grant","title":"Let app todo talk to the assistant","status":"pending","url":"/proposals/p-grant-3"}]"#
        watch.noticed(try Self.tribePost(uuid: post3, in: tribe, proposals: grantMade, at: t0 + 10_000))
        await replies.fail(true)
        await watch.answerInTribe(grant, accept: false)
        #expect(watch.notes[grant] == "Could not send your answer. The tribe is not reachable." && watch.kept[grant]?.answer == nil)
        await replies.fail(false)
        await watch.answerInTribe(grant, accept: false)
        #expect(await replies.sent.last == ["Reject", tribe, post3], "a card without strut's own words: Accept and Reject")
        #expect(watch.notes[grant] == nil)
        watch.answered(byOwn: Self.ownReply("Reject", uuid: uuid(27), in: tribe, replyTo: post3, at: t0 + 10_500))
        #expect(watch.kept[grant]?.answer == false)
        // Listed from the workspace's strut first (the owner's), then its post: the card
        // goes under the post, keeping strut's input, dated by the posts from then on, and
        // the list leaves it alone after (a reply dated before the list's read still counts).
        state.keep(record("p-move-5", step: "graph/create-node"))
        clock.advance(ProposalWatch.listEvery)
        await watch.tick()
        let moved = ProposalKey(source: .org("acme"), id: "p-move-5")
        #expect(watch.orgCards.map(\.key) == [moved] && watch.kept[moved]?.record.input != nil)
        let moveMade = #"[{"id":"p-move-5","step":"graph/create-node","title":"Add Concept: p-move-5","status":"pending","url":"/proposals/p-move-5"}]"#
        watch.noticed(try Self.tribePost(uuid: uuid(5), in: tribe, proposals: moveMade, at: t0 + 11_000))
        #expect(watch.kept[moved]?.post?.uuid == uuid(5) && watch.kept[moved]?.record.input != nil && watch.orgCards.isEmpty)
        #expect(watch.kept[moved]?.readAt == Date(millisecondsSince1970: t0 + 11_000))
        clock.advance(ProposalWatch.listEvery)
        await watch.tick()
        let moveDone = #"[{"id":"p-move-5","status":"applied","title":"Add Concept: p-move-5","step":"graph/create-node"}]"#
        watch.noticed(try Self.tribePost(uuid: uuid(28), in: tribe, proposals: moveDone, replyTo: uuid(5), at: t0 + 11_500))
        #expect(watch.kept[moved]?.record.status == .applied && watch.kept[moved]?.isOver == true)
        // Someone else's reply before the post (a forged end): the post, when it comes,
        // is the card, open again, and only its member's word then ends it.
        let forged = ProposalKey(source: .org("acme"), id: "p-forged-6")
        let forgedEnd = #"[{"id":"p-forged-6","status":"rejected","title":"Install acme/evil","step":"package/install"}]"#
        let forgedMade = #"[{"id":"p-forged-6","step":"package/install","title":"Install acme/evil","status":"pending","url":"/proposals/p-forged-6"}]"#
        watch.noticed(try Self.tribePost(uuid: uuid(17), in: tribe, proposals: forgedEnd, replyTo: uuid(6), alias: "Kate", at: t0 + 13_000))
        #expect(watch.kept[forged]?.isOver == true && watch.kept[forged]?.post?.poster == "Kate")
        watch.noticed(try Self.tribePost(uuid: uuid(6), in: tribe, proposals: forgedMade, at: t0 + 12_500))
        #expect(watch.kept[forged]?.isOver == false && watch.kept[forged]?.record.status == .pending && watch.kept[forged]?.post?.poster == "Jamie")
        watch.noticed(try Self.tribePost(uuid: uuid(18), in: tribe, proposals: forgedEnd, replyTo: uuid(6), alias: "Kate", at: t0 + 14_000))
        #expect(watch.kept[forged]?.isOver == false, "Kate's word is not its member's")
        // The owner's answer before the watch has the post: the post is taken up first.
        let seeded = ProposalKey(source: .org("acme"), id: "p-seed-7")
        let seedMade = #"[{"id":"p-seed-7","step":"graph/create-node","title":"Add Concept: seed","status":"pending","url":"/proposals/p-seed-7"}]"#
        let seedPost = try Self.tribePost(uuid: uuid(7), in: tribe, proposals: seedMade, at: t0 + 15_000)
        watch.sendReply = { text, tribe, post in try await replies.send(text, tribe, post) }
        await watch.answerInTribe(seeded, accept: true, on: seedPost)
        #expect(await replies.sent.last == ["Accept", tribe, uuid(7)] && watch.kept[seeded]?.post?.uuid == uuid(7))
        // A reply with no alias ends nothing.
        var nameless = try Self.tribePost(uuid: uuid(16), in: tribe, proposals: Self.outcomeEntries, replyTo: post3, at: t0 + 12_000)
        nameless.sender = sender()
        watch.noticed(nameless)
        #expect(watch.kept[grant]?.record.status == .pending)
        // Not the owner's device (nothing sends): nothing happens.
        watch.sendReply = nil
        await watch.answerInTribe(key, accept: true)
        #expect(await replies.sent.count == 3)

        // Closed and opened again: back with its post and the answer.
        watch.close()
        await watch.open(storage)
        #expect(watch.kept[key]?.post == TribePost(tribe: tribe, uuid: post1, poster: "Jamie") && watch.kept[key]?.answer == false)
        #expect(watch.kept[key]?.record.status == .failed && watch.kept[grant]?.answer == false && watch.kept[node]?.post?.uuid == post2)
        #expect(watch.orgCards.isEmpty)
    }

    /// Posts that came while nothing watched (to the CLI on the profile,
    /// or before this build): taken up from the store as the watch opens,
    /// in a tribe only, so the owner's card has its buttons all the same;
    /// before the account has listed its tribes.
    @Test func aTribesPostsFromBeforeTheWatchAreTakenUpAsItOpens() async throws {
        let storage = try profile.storage()
        let (post1, reply1, dmPost) = (uuid(31), uuid(32), uuid(33))
        let t0 = Int64(1_800_000_000_000)
        var inDM = try Self.tribePost(uuid: dmPost, in: "02dm", proposals: Self.nodeEntries, at: t0)
        inDM.chat = "02dm"
        _ = try storage.apply(Storage.Commit(
            contacts: [(pubkey: "02tribe", ready: true), (pubkey: "02dm", ready: true)],
            messages: [
                (try Self.tribePost(uuid: post1, in: "02tribe", proposals: Self.proposedEntries, at: t0), false, nil),
                (try Self.tribePost(uuid: reply1, in: "02tribe", proposals: Self.outcomeEntries, replyTo: post1, at: t0 + 5_000), false, nil),
                (inDM, false, nil),
            ],
            tribes: [Tribe(pubkey: "02tribe", name: "jamie", isOwner: true)]
        ))
        let watch = await makeWatch(storage)
        let key = ProposalKey(source: .org("acme"), id: "p-install-1")
        #expect(watch.kept[key]?.post == TribePost(tribe: "02tribe", uuid: post1, poster: "Jamie"))
        #expect(watch.kept[key]?.record.status == .failed && watch.kept[key]?.record.card?.accept == "Install")
        #expect(watch.kept[ProposalKey(source: .org("acme"), id: "p-node-2")] == nil, "a direct message's is no tribe post")
        #expect(watch.kept.count == 1)
    }

    /// Your own reply in a post's thread.
    nonisolated private static func ownReply(_ text: String, uuid: String, in tribe: String, replyTo: String, at timestamp: Int64) -> Message {
        Message.fixture(uuid: uuid, chat: tribe, fromMe: true, content: text, timestamp: timestamp, replyUUID: replyTo, threadUUID: replyTo)
    }

    /// Jamie's post in a tribe, or a reply of Jamie's (or `alias`'s) in a thread.
    nonisolated private static func tribePost(uuid: String, in tribe: String, proposals: String, replyTo: String? = nil,
                                              alias: String = "Jamie", at timestamp: Int64) throws -> Message {
        let metadata = #"{"strut":{"workspace":"acme","artifacts":[],"proposals":\#(proposals)}}"#
        return Message.fixture(uuid: uuid, chat: tribe, fromMe: false, sender: sender(alias: alias),
                               body: try Engine.json(["content": "Waiting for Tom to approve", "metadata": metadata]),
                               content: "Waiting for Tom to approve", timestamp: timestamp, replyUUID: replyTo, threadUUID: replyTo)
    }

    nonisolated private static let proposedEntries = #"""
        [{"id":"p-install-1","step":"package/install","title":"Install the package acme/linear",
          "card":{"v":1,"title":"Install the package acme/linear","fields":[{"label":"Runs code","value":"Yes","danger":true}],
                  "actions":{"accept":"Install","reject":"Don't install"},"full":true},
          "status":"pending","url":"/proposals/p-install-1","rationale":"You asked for Linear."}]
        """#

    nonisolated private static let nodeEntries = #"""
        [{"id":"p-node-2","step":"graph/create-node","title":"Create a node","status":"pending","url":"/proposals/p-node-2"}]
        """#

    nonisolated private static let outcomeEntries = #"""
        [{"id":"p-install-1","status":"failed","title":"Install the package acme/linear","step":"package/install","error":"npm said no"}]
        """#

    /// The owner's replies in the tribe, as the watch asks for them.
    private actor Replies {
        private(set) var sent: [[String]] = []
        private var failing = false
        func fail(_ failing: Bool) { self.failing = failing }
        func send(_ text: String, _ tribe: String, _ post: String) throws {
            if failing { throw PeelError("the tribe is not reachable") }
            sent.append([text, tribe, post])
        }
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
