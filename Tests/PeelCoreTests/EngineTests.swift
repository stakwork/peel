import Foundation
import Sphinxrs
import Testing
@testable import PeelCore
@testable import PeelTestSupport

struct MnemonicTests {
    @Test func wordsSplitOnWhitespaceAndCommasAndLowercase() {
        #expect(Engine.words(in: "  Apple, BANANA\ncherry\t,, date ") == ["apple", "banana", "cherry", "date"])
        #expect(Engine.words(in: "").isEmpty)
        #expect(Engine.words(in: " ,\n ").isEmpty)
    }

    @Test func validateReturnsCanonicalWords() throws {
        let messy = "  " + abandon.map { $0.uppercased() }.joined(separator: ",\n ") + " "
        #expect(try Engine.validate(mnemonic: messy) == abandon.joined(separator: " "))
    }

    @Test func generatedMnemonicIsTwelveValidWords() throws {
        let mnemonic = try Engine.generateMnemonic()
        #expect(Engine.words(in: mnemonic).count == 12)
        #expect(try Engine.validate(mnemonic: mnemonic) == mnemonic)
        #expect(try Engine.generateMnemonic() != mnemonic)
    }

    /// The agent's account comes from the user's seed, so the words recover it
    /// only while the linked core derives exactly what upstream does: the
    /// vectors are sphinx's `agent_seed_vectors` (signer/derive.rs).
    @Test(arguments: [
        ([UInt8](repeating: 0, count: 32), UInt32(1), "6b7c00dcafc11be785c740e8bde0cc5ec5458e2666940788f406abc258509071"),
        ([UInt8](repeating: 0, count: 32), UInt32(2), "a1d8805df73ab1a657815b746f1922da2c5308619fab2a84fc52ce7d72ec4ec0"),
        ([UInt8](0..<32), UInt32(1), "b13c64eb614fc62c744d1a3f0b82cdb5ab219fe985f725226392814693c30492"),
    ])
    func theAgentsSeedMatchesTheCoresVectors(seed: [UInt8], n: UInt32, agent: String) throws {
        #expect(try agentSeed(seed: seed.hex, n: n) == agent)
    }
}

struct AgentAccountTests {
    let profile = TempProfile()

    @Test func theAgentIsItsOwnAccountFromTheSameWords() async throws {
        let engine = try testEngine(try registeredStorage(profile))
        let agent = try await engine.agentAccount()
        #expect(try agent.seed == agentSeed(seed: Engine.seed(of: abandon.joined(separator: " ")), n: 1))
        #expect(agent.pubkey != agent.owner)
        #expect(agent.owner == (await engine.accountKey))
        #expect(agent.broker == "127.0.0.1:1")
        #expect(try await engine.agentAccount() == agent)
        // The phone knows the agent's DM by the same key.
        #expect(try await engine.agentPubkey() == agent.pubkey)
    }

    @Test func itsSeedIsNeverPrinted() async throws {
        let agent = try await testEngine(try registeredStorage(profile)).agentAccount()
        var dumped = ""
        dump(agent, to: &dumped)
        for text in [String(describing: agent), String(reflecting: agent), "\(agent)", dumped] {
            #expect(!text.contains(agent.seed))
            #expect(text.contains(agent.pubkey))
        }
    }

    @Test func refusesNoServerAndTLSRunnerWouldNotUse() async throws {
        let others = (0..<4).map { _ in TempProfile() }
        await #expect(throws: Engine.Failure.noServer) { try await testEngine(try others[0].storage()).agentAccount() }
        for (other, (server, refused)) in zip(others.dropFirst(), [
            ("mqtts://broker.example:8883", false), ("mqtts://broker.example:1883", true), ("mqtt://127.0.0.1:8883", true),
        ]) {
            let storage = try other.storage()
            var commit = Storage.Commit()
            commit.settings[.server] = server
            _ = try storage.apply(commit)
            let engine = try testEngine(storage)
            if refused {
                await #expect(throws: PeelError.self) { try await engine.agentAccount() }
            } else {
                #expect(try await engine.agentAccount().broker == "broker.example:8883")
            }
        }
    }
}

struct InviteTests {
    /// Builds an invite the way the core's `invite_qr` does.
    private func invite(host: String, code: [UInt8], contact: (key: [UInt8], lsp: [UInt8], scid: UInt64, alias: String)?) -> String {
        var link = "sphinx.chat://?action=i&d=" + base64URL(code + Array(host.utf8))
        if let contact {
            let scid = withUnsafeBytes(of: contact.scid.bigEndian, Array.init)
            link += "&c=" + base64URL(contact.key + contact.lsp + scid + Array(contact.alias.utf8))
        }
        return link
    }

    private func base64URL(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }

    @Test func parsesHostAndCode() throws {
        let code = [UInt8](0..<32)
        let parsed = try Engine.parseInvite("  " + invite(host: "broker.example.com:8883", code: code, contact: nil) + "\n")
        #expect(parsed.code == code.map { String(format: "%02x", $0) }.joined())
        #expect(parsed.server == "broker.example.com:8883")
        #expect(parsed.inviterContactInfo == nil)
        #expect(parsed.inviterAlias == nil)
    }

    @Test func parsesInviter() throws {
        let key = [UInt8](repeating: 2, count: 33)
        let lsp = [UInt8](repeating: 3, count: 33)
        let link = invite(host: "h:1", code: Array(repeating: 0, count: 32), contact: (key, lsp, 1234, "Ann"))
        let parsed = try Engine.parseInvite(link)
        #expect(parsed.inviterContactInfo == "\(String(repeating: "02", count: 33))_\(String(repeating: "03", count: 33))_1234")
        #expect(parsed.inviterAlias == "Ann")
    }

    @Test func rejectsInviteWithoutData() {
        #expect(throws: (any Error).self) { try Engine.parseInvite("sphinx.chat://?action=i&x=1") }
        #expect(throws: (any Error).self) { try Engine.parseInvite("d=!!!") }
    }
}

struct EngineOfflineTests {
    let profile = TempProfile()

    @Test func freshAccountIsUnregisteredWithNoContacts() async throws {
        let storage = try profile.storage()
        let engine = try testEngine(storage)
        #expect(await engine.isRegistered == false)
        #expect(try await engine.contacts().isEmpty)
        #expect(try Engine.contacts(in: storage).isEmpty)
        #expect(await engine.connection == .offline(retryIn: nil))
    }

    @Test func deviceIDIsCreatedOnceAndKept() throws {
        let deviceID: String?
        do {
            let storage = try profile.storage()
            _ = try testEngine(storage)
            deviceID = try storage.value(for: .deviceID)
        }
        #expect(deviceID != nil)
        let storage = try profile.storage()
        _ = try testEngine(storage)
        #expect(try storage.value(for: .deviceID) == deviceID)
    }
}

/// Whether the twelve words were written down (finding N5): stored per
/// account, set by three words typed back or by a restore, never by a
/// new account on its own.
struct WordsConfirmationTests {
    let profile = TempProfile()
    let server = ServerAddress("127.0.0.1:1")!

    /// A restore typed all twelve words; a new account has had none typed back.
    @Test(arguments: [false, true]) func onlyARestoreStartsConfirmed(restore: Bool) async throws {
        let local = Profile(developmentAt: profile.url)
        let engine = if restore {
            try await Account.restore(local, mnemonic: abandon.joined(separator: " "), pin: "", server: server)
        } else {
            try await Account.create(local, alias: "Ann", pin: "", server: server).engine
        }
        #expect(try await engine.wordsConfirmed() == restore)
    }

    private func storeSent(_ engine: Engine, alias: String?, photo: String?) async throws {
        try await engine.storage.upsertContact(pubkey: "02aa", alias: "Ann")
        _ = try await engine.storage.apply(Storage.Commit(messages: [
            (.fixture(uuid: "u1", serverIndex: 1, chat: "02aa", fromMe: true, sender: sender("02bb", alias: "Old", photo: "https://img/old.png")),
             false, nil),
            (.fixture(uuid: "u2", serverIndex: 2, chat: "02aa", fromMe: true, sender: sender("02bb", alias: alias, photo: photo)), false, nil),
        ]))
    }

    private func profileEvents(_ engine: Engine) async -> [String] {
        await engine.close()
        var seen: [String] = []
        for await case .profile(let alias, let photoURL) in engine.events { seen.append("\(alias)|\(photoURL ?? "")") }
        return seen
    }

    /// A restore asks for no name; the newest sent messages give it and the photo back.
    @Test func restoreRecoversNameAndPhotoFromSentMessages() async throws {
        let engine = try await Account.restore(
            Profile(developmentAt: profile.url), mnemonic: abandon.joined(separator: " "), pin: "", server: server)
        #expect(await engine.myAlias == "")
        try await storeSent(engine, alias: "Ann Me", photo: "https://img/me.png")
        await engine.recoverOwnProfile()
        #expect(await engine.myAlias == "Ann Me")
        #expect(await engine.myPhotoURL == "https://img/me.png")
        #expect(await engine.profileRecoveryDone)
        #expect(await profileEvents(engine).contains("Ann Me|https://img/me.png"))
    }

    @Test func recoveryTakesASchemeLessPhotoLinkFromSentMessages() async throws {
        let engine = try await Account.restore(
            Profile(developmentAt: profile.url), mnemonic: abandon.joined(separator: " "), pin: "", server: server)
        try await storeSent(engine, alias: "Ann Me", photo: "memes.sphinx.chat/public/me")
        await engine.recoverOwnProfile()
        #expect(await engine.myPhotoURL == "https://memes.sphinx.chat/public/me")
    }

    @Test func recoverySkipsAnEmptyNewestPhotoAndEmitsTheFinalPairLast() async throws {
        let engine = try await Account.restore(
            Profile(developmentAt: profile.url), mnemonic: abandon.joined(separator: " "), pin: "", server: server)
        try await engine.storage.upsertContact(pubkey: "02aa", alias: "Ann")
        _ = try await engine.storage.apply(Storage.Commit(messages: [
            (.fixture(uuid: "u1", serverIndex: 1, chat: "02aa", fromMe: true, sender: sender("02bb", alias: "Old", photo: "https://img/real.png")),
             false, nil),
            (.fixture(uuid: "u2", serverIndex: 2, chat: "02aa", fromMe: true, sender: sender("02bb", alias: "Ann Me", photo: "")), false, nil),
        ]))
        await engine.recoverOwnProfile()
        #expect(await engine.myAlias == "Ann Me")
        #expect(await engine.myPhotoURL == "https://img/real.png")
        #expect(await profileEvents(engine).last == "Ann Me|https://img/real.png")
    }

    @Test func recoveryWithNoSentMessagesSetsNothingAndRetries() async throws {
        let engine = try await Account.restore(
            Profile(developmentAt: profile.url), mnemonic: abandon.joined(separator: " "), pin: "", server: server)
        await engine.recoverOwnProfile()
        #expect(await engine.myAlias == "")
        #expect(await engine.myPhotoURL == nil)
        #expect(await !engine.profileRecoveryDone)
        #expect(await profileEvents(engine).isEmpty)
    }

    @Test func recoveryKeepsANameSetBeforehand() async throws {
        let engine = try await Account.restore(
            Profile(developmentAt: profile.url), mnemonic: abandon.joined(separator: " "), pin: "", server: server)
        try await engine.setAlias("Chosen")
        try await storeSent(engine, alias: "Recovered", photo: "https://img/me.png")
        await engine.recoverOwnProfile()
        #expect(await engine.myAlias == "Chosen")
        #expect(await engine.myPhotoURL == "https://img/me.png")
    }

    @Test func rightWordsConfirmAndAreKept() async throws {
        do {
            let engine = try testEngine(try profile.storage())
            #expect(try await engine.wordsConfirmed() == false)
            // As typed from paper: any case, stray spaces.
            try await engine.confirmWords(
                [0: " Abandon", 5: "abandon ", 11: "ABOUT"], mnemonic: abandon.joined(separator: " ")
            )
            #expect(try await engine.wordsConfirmed())
        }
        #expect(try await testEngine(try profile.storage()).wordsConfirmed())
    }

    @Test func wrongWordsNameTheirPositionsAndConfirmNothing() async throws {
        let engine = try testEngine(try profile.storage())
        let words = abandon.joined(separator: " ")
        // The account's own words, but not the ones at these places.
        await #expect(throws: Engine.Failure.wrongWords(positions: [6, 12])) {
            try await engine.confirmWords([0: "abandon", 5: "about", 11: "abandon"], mnemonic: words)
        }
        // Another account's words, typed back right, are not this one's.
        let others = try Engine.generateMnemonic()
        let answers = Dictionary(uniqueKeysWithValues: [1, 4, 9].map { ($0, Engine.words(in: others)[$0]) })
        await #expect(throws: Engine.Failure.notThisAccountsWords) { try await engine.confirmWords(answers, mnemonic: others) }
        // One word, right as it is, is not the check.
        await #expect(throws: PeelError.self) { try await engine.confirmWords([11: "about"], mnemonic: words) }
        #expect(try await engine.wordsConfirmed() == false)
        // What the person reads names positions, never a word.
        #expect("\(Engine.Failure.wrongWords(positions: [6, 12]))" == "words 6 and 12 do not match")
    }
}

/// What the core calls ours is kept only when our key signed it, or a tribe
/// we know signed it in its own chat: the tag and the date that make it
/// ours are a contact's to arrange (docs/phases/04-money.md, "Who may write
/// ours"). `keyG` is a tribe, `key2G` a person, `strangerKey` anyone.
struct OursTests {
    let profile = TempProfile()

    private static func copy(
        signedBy signer: String, to chat: String?, fromMe: Bool = true, type: Int = MessageType.text, host: String? = nil
    ) -> Msg {
        Msg(message: #"{"content":"hi"}"#, type: UInt8(type), uuid: uuid(1), tag: "aa", index: "7",
            sender: sender(signer, host: host), msat: nil, timestamp: 1_000, sentTo: chat, fromMe: fromMe,
            paymentHash: nil, error: nil)
    }

    /// The row the copy left in `chat`, if any, with the core's `state`
    /// changes and the tribes stored first.
    private func stored(
        _ msg: @Sendable () -> Msg, in chat: String, expectedSender: String? = nil, state: [String: Data] = [:], tribes: [Tribe] = []
    ) async throws -> Message? {
        let storage = try profile.storage()
        _ = try storage.apply(Storage.Commit(tribes: tribes))
        let engine = try testEngine(storage)
        _ = try await engine.commit(coreResult(msgs: [msg()], state: state), time: "1", expectedSender: expectedSender)
        return try storage.message(uuid: uuid(1), in: chat)
    }

    @Test func ourKeysCopyIsKept() async throws {
        let other = TempProfile()
        let ours = await (try testEngine(other.storage())).accountKey
        let row = try #require(try await stored({ Self.copy(signedBy: ours, to: key2G) }, in: key2G))
        #expect(row.fromMe)
    }

    @Test func aKnownTribesForwardOfOursIsKept() async throws {
        let row = try #require(try await stored({ Self.copy(signedBy: keyG, to: keyG) }, in: keyG, tribes: [Tribe(pubkey: keyG)]))
        #expect(row.fromMe)
    }

    /// Our own join forwarded back with the tribe's host, as on a restore,
    /// makes the tribe known, and is kept.
    @Test func ourJoinThatIntroducesTheTribeIsKept() async throws {
        let row = try await stored({
            Self.copy(signedBy: keyG, to: keyG, type: MessageType.groupJoin, host: "tribes.example")
        }, in: keyG, state: coreContact(keyG, contactKey: nil))
        #expect(row?.fromMe == true)
        #expect(try profile.storage().tribes().contains { $0.pubkey == keyG })
    }

    /// Signed by us it is ours wherever it is filed, a tribe Peel does not
    /// know included (our echo on another device).
    @Test func ourKeysCopyInAnUnknownTribeShapedChatIsKept() async throws {
        let other = TempProfile()
        let ours = await (try testEngine(other.storage())).accountKey
        let row = try await stored({ Self.copy(signedBy: ours, to: keyG) }, in: keyG, state: coreContact(keyG, contactKey: nil))
        #expect(row?.fromMe == true)
    }

    @Test func aCopyWithNoSenderIsDropped() async throws {
        let msg: @Sendable () -> Msg = {
            Msg(message: #"{"content":"hi"}"#, type: UInt8(MessageType.text), uuid: uuid(1), tag: "aa", index: "7",
                sender: nil, msat: nil, timestamp: 1_000, sentTo: key2G, fromMe: true, paymentHash: nil, error: nil)
        }
        #expect(try await stored(msg, in: key2G) == nil)
    }

    @Test func aCopySignedByTheChatsPersonIsDropped() async throws {
        #expect(try await stored({ Self.copy(signedBy: key2G, to: key2G) }, in: key2G) == nil)
    }

    @Test func aDMCopySignedByAnotherKeyIsDropped() async throws {
        #expect(try await stored({ Self.copy(signedBy: strangerKey, to: key2G) }, in: key2G) == nil)
    }

    @Test func aCopyInATribeSignedByAnotherKeyIsDropped() async throws {
        #expect(try await stored({ Self.copy(signedBy: strangerKey, to: keyG) }, in: keyG, tribes: [Tribe(pubkey: keyG)]) == nil)
    }

    /// The core files a signer as a contact at the index it wrote to,
    /// without a contact key if they leave it out: tribe-shaped, not a tribe.
    /// With no host to introduce it, it is no tribe Peel knows (with one, it
    /// would be: documented residual).
    @Test func aCopyInAContactThatOnlyLooksLikeATribeIsDropped() async throws {
        let minted = coreContact(strangerKey, contactKey: nil)
        #expect(try await stored({ Self.copy(signedBy: strangerKey, to: strangerKey) }, in: strangerKey, state: minted) == nil)
    }

    /// Someone else's message is filed by the topic as before.
    @Test func notOursIsUnchanged() async throws {
        let row = try #require(try await stored({ Self.copy(signedBy: key2G, to: nil, fromMe: false) }, in: key2G, expectedSender: key2G))
        #expect(!row.fromMe)
    }

    // MARK: A tribe joined on another device of this account

    /// A tribes server's forward as this device's core reports one when it
    /// does not know the tribe yet: no `sentTo`, signed by `signer`.
    private static func unfiledCopy(
        _ n: Int, type: Int, signer: String = keyG, host: String? = "tribes.example", fromMe: Bool = true,
        alias: String? = nil, role: Int? = nil, words: String = ""
    ) -> Msg {
        Msg(message: #"{"content":"\#(words)"}"#, type: UInt8(type), uuid: uuid(n), tag: fromMe ? "t\(n)" : nil,
            index: String(n), sender: sender(signer, alias: alias, host: host, role: role), msat: nil,
            timestamp: UInt64(n) * 1_000, sentTo: nil, fromMe: fromMe, paymentHash: nil, error: nil)
    }

    /// An engine on our tribes host, named Ann, with `tribes` stored, after
    /// a core call that returned `msgs`.
    private func heard(_ msgs: @Sendable () -> [Msg], tribes: [Tribe] = []) async throws -> (Storage, Engine) {
        let storage = try profile.storage()
        try storage.set("tribes.example", for: .tribeHost)
        try storage.set("Ann", for: .alias)
        _ = try storage.apply(Storage.Commit(tribes: tribes))
        let engine = try testEngine(storage)
        _ = try await engine.commit(coreResult(msgs: msgs()), time: "1", expectedSender: nil)
        return (storage, engine)
    }

    private static func listed(deleted: Bool = false) -> @Sendable (String, String) async throws -> TribeInfo {
        { pubkey, _ in
            try JSONDecoder().decode(TribeInfo.self, from: Data(
                #"{"pubkey":"\#(pubkey)","name":"club","price_per_message":0,"deleted":\#(deleted)}"#.utf8
            ))
        }
    }

    private static let notListed: @Sendable (String, String) async throws -> TribeInfo = { _, _ in
        throw TribeInfo.NotServed(status: 404)
    }

    /// Our join on another device: nothing is stored until our registry
    /// lists the tribe; then it is joined, with the registry's name, and
    /// what was heard there meanwhile is ours.
    @Test func ourJoinFromAnotherDeviceJoinsOnceOurRegistryListsTheTribe() async throws {
        let (storage, engine) = try await heard({ [
            Self.unfiledCopy(1, type: MessageType.groupJoin), Self.unfiledCopy(2, type: MessageType.text, words: "hi"),
        ] })
        #expect(try storage.tribes().isEmpty)
        #expect(try storage.message(uuid: uuid(1), in: keyG) == nil)
        await engine.confirmTribes(fetch: Self.listed())
        let tribe = try #require(try storage.tribes().first)
        #expect(tribe.pubkey == keyG && tribe.name == "club" && !tribe.left && tribe.status == .active && !tribe.isOwner)
        #expect(tribe.host == "tribes.example")
        #expect(try storage.message(uuid: uuid(2), in: keyG)?.fromMe == true)
        #expect(await engine.heldChats.isEmpty)
    }

    /// The owner's own join (role 0) makes the tribe ours to run here too.
    @Test func ourOwnTribeFromAnotherDeviceIsOwned() async throws {
        let (storage, engine) = try await heard({ [Self.unfiledCopy(1, type: MessageType.groupJoin, role: 0)] })
        await engine.confirmTribes(fetch: Self.listed())
        #expect(try storage.tribes().first?.isOwner == true)
    }

    /// Joined and left on the other device before this one heard back from
    /// the registry: left here too, whatever order the calls came in.
    @Test func joinedThenLeftOnAnotherDeviceIsLeft() async throws {
        let (storage, engine) = try await heard({ [Self.unfiledCopy(1, type: MessageType.groupJoin)] })
        _ = try await engine.commit(coreResult(msgs: [Self.unfiledCopy(2, type: MessageType.groupLeave)]), time: "2", expectedSender: nil)
        await engine.confirmTribes(fetch: Self.listed())
        #expect(try storage.tribes().first?.left == true)
    }

    /// The owner's approval naming us (a private tribe) lets us in.
    @Test func anApprovalNamingUsFromAnotherDeviceJoins() async throws {
        let (storage, engine) = try await heard({ [
            Self.unfiledCopy(1, type: MessageType.memberApprove, fromMe: false, alias: "Ann", role: 0),
        ] })
        await engine.confirmTribes(fetch: Self.listed())
        #expect(try storage.tribes().first?.status == .active)
    }

    /// A key our registry does not list (a throwaway that signed a copy of
    /// "ours") is recorded nowhere, and not asked about again.
    @Test func whatOurRegistryDoesNotListIsNoTribe() async throws {
        let (storage, engine) = try await heard({ [Self.unfiledCopy(1, type: MessageType.groupJoin, signer: strangerKey)] })
        await engine.confirmTribes(fetch: Self.notListed)
        #expect(try storage.tribes().isEmpty)
        _ = try await engine.commit(coreResult(msgs: [Self.unfiledCopy(2, type: MessageType.groupJoin, signer: strangerKey)]),
                                    time: "2", expectedSender: nil)
        #expect(await engine.heldChats.isEmpty)
    }

    /// A registry that fails otherwise (here a 500) is asked again later,
    /// with nothing lost.
    @Test func aRegistryFailureKeepsWhatWasHeld() async throws {
        let (storage, engine) = try await heard({ [Self.unfiledCopy(1, type: MessageType.groupJoin)] })
        await engine.confirmTribes(fetch: { _, _ in throw TribeInfo.NotServed(status: 500) })
        #expect(try storage.tribes().isEmpty)
        #expect(await engine.heldChats == [keyG])
        await engine.confirmTribes(fetch: Self.listed())
        #expect(try storage.tribes().first?.status == .active)
    }

    /// Joined here while the registry could not be asked: what was held
    /// is filed, but an older leave from the other device does not undo
    /// the join made here.
    @Test func aTribeJoinedHereMeanwhileKeepsItsJoin() async throws {
        let (storage, engine) = try await heard({ [
            Self.unfiledCopy(1, type: MessageType.groupJoin), Self.unfiledCopy(2, type: MessageType.text, words: "hi"),
            Self.unfiledCopy(3, type: MessageType.groupLeave),
        ] })
        await engine.confirmTribes(fetch: { _, _ in throw TribeInfo.NotServed(status: 500) })
        // Known here meanwhile: our join, with the tribe in the core.
        _ = try await engine.commit(coreResult(msgs: [Self.copy(
            signedBy: keyG, to: keyG, type: MessageType.groupJoin, host: "tribes.example"
        )], state: coreContact(keyG, contactKey: nil)), time: "2", expectedSender: nil)
        #expect(try storage.tribes().first?.left == false)
        await engine.confirmTribes(fetch: Self.listed())
        #expect(try storage.tribes().first?.left == false)
        #expect(try storage.message(uuid: uuid(2), in: keyG)?.fromMe == true)
        // Stored without leaving, so its tag is held.
        #expect(try storage.message(uuid: uuid(3), in: keyG)?.tag == "t3")
        #expect(await engine.heldChats.isEmpty)
    }

    @Test func aDeletedTribeIsNotRecorded() async throws {
        let (storage, engine) = try await heard({ [Self.unfiledCopy(1, type: MessageType.groupJoin)] })
        await engine.confirmTribes(fetch: Self.listed(deleted: true))
        #expect(try storage.tribes().isEmpty)
    }

    @Test(arguments: [
        // Another host: never fetched from a host a message names.
        (MessageType.groupJoin, "elsewhere.example", true, nil as String?, nil as Int?),
        // Not a join: a text or our leave alone names nothing.
        (MessageType.text, "tribes.example", true, nil, nil),
        (MessageType.groupLeave, "tribes.example", true, nil, nil),
        // An approval of someone else, or not from the owner.
        (MessageType.memberApprove, "tribes.example", false, "Bob", 0),
        (MessageType.memberApprove, "tribes.example", false, "Ann", nil),
    ])
    func nothingElseIsHeld(type: Int, host: String, fromMe: Bool, alias: String?, role: Int?) async throws {
        let (storage, engine) = try await heard({ [Self.unfiledCopy(1, type: type, host: host, fromMe: fromMe, alias: alias, role: role)] })
        #expect(await engine.heldChats.isEmpty)
        #expect(try storage.message(uuid: uuid(1), in: keyG) == nil)
    }

    /// A tribe already known (here left) is never recorded again: what the
    /// other device sends there is filed as usual, our leave leaves.
    @Test func aKnownTribeIsNotConfirmedAgain() async throws {
        var known = Tribe(pubkey: keyG)
        known.myAlias = "me"
        let (storage, engine) = try await heard({ [Self.unfiledCopy(1, type: MessageType.groupLeave)] }, tribes: [known])
        #expect(await engine.heldChats.isEmpty)
        let tribe = try #require(try storage.tribes().first)
        #expect(tribe.left && tribe.myAlias == "me")
    }

    @Test func ourPostFromAnotherDeviceInAKnownTribeIsOurs() async throws {
        let (storage, _) = try await heard({ [Self.unfiledCopy(1, type: MessageType.text)] }, tribes: [Tribe(pubkey: keyG)])
        #expect(try storage.message(uuid: uuid(1), in: keyG)?.fromMe == true)
    }

    /// Our own key's copy with no `sentTo` (a contact record) is filed nowhere.
    @Test func ourKeysCopyWithNoChatIsDropped() async throws {
        let other = TempProfile()
        let ours = await (try testEngine(other.storage())).accountKey
        let (storage, engine) = try await heard({ [Self.unfiledCopy(1, type: MessageType.groupJoin, signer: ours)] })
        #expect(await engine.heldChats.isEmpty)
        #expect(try storage.message(uuid: uuid(1), in: ours) == nil)
    }
}

/// Who a message from the core is from, and which chat it goes in. The core
/// recovers a sender from its signature; a live message's topic names the
/// contact too, and only when the two agree does the sender's name and
/// photo count. History from a sender the core does not know is dropped.
struct SenderTests {
    let profile = TempProfile()

    /// A text as the core hands it over, with the sender it claims.
    private func msg(_ n: Int, claims pubkey: String? = nil, alias: String = "Mallory", fromMe: Bool = false,
                     sentTo: String? = nil, type: Int = MessageType.text, body: String = #"{"content":"hi"}"#,
                     tag: String? = nil) -> Msg {
        let sender = pubkey.map { #"{"pubkey":"\#($0)","alias":"\#(alias)","photo_url":"https://img/\#(alias).png"}"# }
        return Msg(
            message: body, type: UInt8(type), uuid: uuid(n), tag: tag, index: String(n), sender: sender, msat: nil,
            timestamp: UInt64(n) * 1_000, sentTo: sentTo, fromMe: fromMe, paymentHash: nil, error: nil
        )
    }

    /// An engine whose core knows `keyG` as a contact.
    private func engine() throws -> (Engine, Storage) {
        let storage = try profile.storage()
        _ = try storage.apply(Storage.Commit(
            state: registeredState.merging(coreContact(keyG, contactKey: key3G)) { $1 }, contacts: [(keyG, true)]
        ))
        return (try testEngine(storage), storage)
    }

    private func stored() throws -> [(chat: String, fromMe: Bool)] {
        try rows(profile, "SELECT chat, fromMe FROM message ORDER BY id").map { ($0["chat"], $0["fromMe"]) }
    }

    private func alias(of pubkey: String) throws -> String? {
        try rows(profile, "SELECT alias FROM contact WHERE pubkey = '\(pubkey)'").first?["alias"]
    }

    /// A live message goes in the chat its topic names; a sender claiming
    /// to be someone else renames no one.
    @Test func aLiveMessageClaimingAnotherSenderRenamesNoOne() async throws {
        let (engine, _) = try engine()
        _ = try await engine.commit(coreResult(msgs: [msg(1, claims: key2G)]), time: "1", expectedSender: keyG)
        #expect(try stored().map(\.chat) == [keyG])
        #expect(try alias(of: keyG) == nil)
        #expect(try alias(of: key2G) == nil)
        // The contact naming itself is believed.
        _ = try await engine.commit(coreResult(msgs: [msg(2, claims: keyG, alias: "Ann")]), time: "2", expectedSender: keyG)
        #expect(try alias(of: keyG) == "Ann")
    }

    /// From history (no topic), the claimed sender must be a contact the
    /// core knows; anyone else's message is dropped, not filed under them.
    @Test func historyFromAStrangerIsDropped() async throws {
        let (engine, _) = try engine()
        _ = try await engine.commit(coreResult(msgs: [msg(1, claims: strangerKey)]), time: "1", expectedSender: nil)
        _ = try await engine.commit(coreResult(msgs: [msg(2)]), time: "2", expectedSender: nil)
        #expect(try stored().isEmpty)
        _ = try await engine.commit(coreResult(msgs: [msg(3, claims: keyG, alias: "Ann")]), time: "3", expectedSender: nil)
        #expect(try stored().map(\.chat) == [keyG])
        #expect(try alias(of: keyG) == "Ann")
    }

    /// Our own copy goes in the chat it was sent to; one signed by another
    /// key, sent to the same chat, is not ours and is dropped.
    @Test func ourOwnCopyGoesWhereItWasSent() async throws {
        let (engine, _) = try engine()
        let ours = await engine.accountKey
        _ = try await engine.commit(coreResult(msgs: [msg(1, claims: strangerKey, fromMe: true, sentTo: keyG)]), time: "1", expectedSender: nil)
        #expect(try stored().isEmpty)
        _ = try await engine.commit(coreResult(msgs: [msg(2, claims: ours, fromMe: true, sentTo: keyG)]), time: "2", expectedSender: nil)
        #expect(try stored().map(\.chat) == [keyG])
        #expect(try stored().map(\.fromMe) == [true])
    }

    /// A tribe forwarding our post proves the server took it: its copy takes
    /// over the row written at send (one row, delivered, the tribe's uuid);
    /// a copy with our tag naming our post in another chat is a member's
    /// replay and is dropped, and the same copy again adds nothing.
    @Test func aTribesCopyOfOurPostTakesOverItsRow() async throws {
        let (club, other) = ("02c1ab", "02c2ab")
        let storage = try profile.storage()
        try storage.save([Tribe(pubkey: club), Tribe(pubkey: other)])
        let sent = { (n: Int, chat: String) in
            Message.fixture(uuid: uuid(n), chat: chat, fromMe: true, content: "hi", tag: "t\(n)",
                            status: Message.Delivery.pending.rawValue)
        }
        _ = try storage.apply(Storage.Commit(messages: [(sent(1, club), false, nil), (sent(2, other), false, nil)]))
        let engine = try testEngine(storage)
        func echo(_ n: Int, of original: Int, in chat: String) -> Msg {
            msg(n, claims: chat, fromMe: true, sentTo: chat, body: #"{"content":"hi","originalUuid":"\#(uuid(original))"}"#,
                tag: "t\(original)")
        }
        _ = try await engine.commit(coreResult(msgs: [echo(11, of: 1, in: club)]), time: "1", expectedSender: nil)
        // Our post in another tribe is not taken over by a copy naming it, nor stored.
        _ = try await engine.commit(coreResult(msgs: [echo(12, of: 2, in: club)]), time: "2", expectedSender: nil)
        _ = try await engine.commit(coreResult(msgs: [echo(11, of: 1, in: club)]), time: "3", expectedSender: nil)
        let rows = try rows(profile, "SELECT uuid, chat, tag, status FROM message ORDER BY id")
        #expect(rows.map { $0["uuid"] as String } == [uuid(11), uuid(2)])
        #expect(rows.map { $0["chat"] as String } == [club, other])
        #expect(rows[0]["tag"] as String? == "t1")
        #expect(rows[0]["status"] as String? == Message.Delivery.delivered.rawValue)
        #expect(rows[1]["status"] as String? == Message.Delivery.pending.rawValue)
    }

    /// A payment request asks for what its invoice says, whatever its JSON claims.
    @Test func aRequestAsksForWhatItsInvoiceSays() async throws {
        let seed = try Sphinxrs.mnemonicToSeed(
            mnemonic: "legal winner thank year wave sausage worth useful legal winner thank yellow"
        )
        let bolt11 = try #require(try Sphinxrs.makeInvoice(
            seed: seed, uniqueTime: String(Date().millisecondsSince1970), state: StateCodec.encode(registeredState),
            amtMsat: 10_000, description: "lunch"
        ).invoice)
        let invoice = try Invoice(bolt11)
        let body = #"{"invoice":"\#(bolt11)","amount":99000000,"paymentHash":"\#(uuid(9))","content":"forged"}"#
        let (engine, storage) = try engine()
        let request = msg(1, claims: keyG, type: MessageType.invoice, body: body)
        _ = try await engine.commit(coreResult(msgs: [request]), time: "1", expectedSender: keyG)
        let id: Int64 = try #require(try rows(profile, "SELECT id FROM message").first?["id"])
        let stored = try #require(try storage.message(id: id))
        #expect(stored.amountMsat == 10_000)
        #expect(stored.paymentHash == invoice.paymentHash)
        #expect(stored.content == "lunch")
    }
}
