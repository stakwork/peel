import Foundation
import Testing
@testable import PeelCore
@testable import PeelTestSupport

/// Payment templates against the official Mac app's format
/// (`SphinxOnionManager.formatMsg` for a type 5, `getPaymentTemplates`).
struct PaymentTemplateTests {
    let profile = TempProfile()

    /// A muid as the memes server issues them: URL-safe base64 of 32 bytes.
    static let muid = MediaToken.base64URLEncode(Data((0..<32).map { UInt8($0 * 7 % 256) }))

    /// A media token in the core's shape (`ldat::start`): host, muid, no
    /// buyer, expiry, no meta, signature; URL-safe base64 with padding.
    static func token(host: String = "memes.sphinx.chat", muid: String = muid) -> String {
        let b64 = MediaToken.base64URLEncode
        return [b64(Data(host.utf8)), muid, "", b64(be64(1_791_000_000).suffix(4)), "", b64(Data(repeating: 9, count: 65))]
            .joined(separator: ".")
    }

    /// The Mac app's type 5 with a template, as `JSONSerialization` writes
    /// it `.prettyPrinted`: no keys (the picture is not encrypted).
    static func officialBody(content: String = "for lunch", token: String = token()) -> String {
        """
        {
          "content" : "\(content)",
          "mediaToken" : "\(token)",
          "mediaType" : "image/png"
        }
        """
    }

    @Test func readsTheOfficialAppsTemplatedPayment() throws {
        let message = Message.fixture(type: MessageType.directPayment, body: Self.officialBody(), content: "for lunch")
        #expect(message.paymentTemplateMUID == Self.muid)
        let token = try #require(PaymentTemplate.token(in: message.body))
        #expect(token.host == "memes.sphinx.chat")
        #expect(token.priceSats == nil)
    }

    @Test func aPaymentWithoutATemplateHasNone() {
        // The Mac app sends `mediaType` with or without a picture.
        let plain = Message.fixture(type: MessageType.directPayment, body: #"{"content":"hi","mediaType":"image/png"}"#)
        #expect(plain.paymentTemplateMUID == nil)
        // Only a direct payment carries one, and not once deleted.
        let attachment = Message.fixture(type: MessageType.attachment, body: Self.officialBody())
        #expect(attachment.paymentTemplateMUID == nil)
        var deleted = Message.fixture(type: MessageType.directPayment, body: Self.officialBody())
        deleted.deleted = true
        #expect(deleted.paymentTemplateMUID == nil)
    }

    @Test(arguments: ["../../etc", "a/b", "muid with spaces", "%2e%2e", ""])
    func aMuidThatCannotStandInAPathIsRefused(_ muid: String) {
        let body = Self.officialBody(token: Self.token(muid: muid))
        #expect(Message.fixture(type: MessageType.directPayment, body: body).paymentTemplateMUID == nil)
    }

    @Test func peelsBodyHasTheOfficialAppsFields() throws {
        let token = Self.token()
        let ours = try PaymentTemplate.paymentBody(text: "for lunch", token: token)
        let official = try JSONSerialization.jsonObject(with: Data(Self.officialBody().utf8)) as? [String: String]
        let peel = try JSONSerialization.jsonObject(with: Data(ours.utf8)) as? [String: String]
        #expect(peel == official)
        // Without a template, the payment's JSON is what it always was.
        #expect(try PaymentTemplate.paymentBody(text: "hi", token: nil) == #"{"content":"hi"}"#)
    }

    @Test func readsTheTemplatesList() throws {
        let reply = Data("""
        [{"muid":"\(Self.muid)","width":512,"height":384},
         {"muid":"\(Self.muid)","width":1,"height":1},
         {"muid":"../x","width":10,"height":10},
         {"muid":"YWJj","width":0},
         {"width":3,"height":3}, 7]
        """.utf8)
        let list = try #require(PaymentTemplate.list(from: reply))
        #expect(list == [
            PaymentTemplate(muid: Self.muid, width: 512, height: 384),
            PaymentTemplate(muid: "YWJj", width: nil, height: nil),
        ])
        #expect(PaymentTemplate.list(from: Data(#"{"muid":"x"}"#.utf8)) == nil)
        #expect(PaymentTemplate.list(from: Data("[]".utf8)) == [])
    }

    @Test func templatePicturesHaveTheirOwnCacheFiles() throws {
        let store = MediaStore(profile: profile.url)
        let template = try store.store(Data("png".utf8), at: store.template(muid: Self.muid), limit: 1_000)
        #expect(template.deletingLastPathComponent().standardizedFileURL == store.cache.standardizedFileURL)
        #expect(store.lookup(store.template(muid: Self.muid)) == template)
        // No attachment's muid and key name the template's file.
        #expect(store.cached(muid: Self.muid, key: "template") != template)
        #expect(store.cached(muid: "template:\(Self.muid)", key: "") != template)
    }

    @Test func theCoresTokenForATemplateReadsBack() async throws {
        let storage = try profile.storage()
        try storage.set(Engine.defaultMemesHost, for: .memesHost)
        let engine = try testEngine(storage)
        let token = try await engine.templateToken(muid: Self.muid, to: keyG)
        let parsed = try #require(MediaToken(token))
        #expect(parsed.host == Engine.defaultMemesHost)
        #expect(parsed.muid == Self.muid)
        #expect(parsed.priceSats == nil)
        let body = try PaymentTemplate.paymentBody(text: "", token: token)
        #expect(Message.fixture(type: MessageType.directPayment, body: body).paymentTemplateMUID == Self.muid)
        await #expect(throws: Engine.Failure.noPaymentTemplate) { try await engine.templateToken(muid: "../x", to: keyG) }
    }

    @Test func aPictureNamedOnAnotherHostIsNeverFetched() async throws {
        let storage = try profile.storage()
        try storage.set(Engine.defaultMemesHost, for: .memesHost)
        let engine = try testEngine(storage)
        let foreign = Message.fixture(
            type: MessageType.directPayment, body: Self.officialBody(token: Self.token(host: "evil.example"))
        )
        let plain = Message.fixture(uuid: "uuid-2", type: MessageType.directPayment, body: #"{"content":"hi"}"#)
        let stored = try storage.apply(Storage.Commit(messages: [(foreign, false, nil), (plain, false, nil)])).stored
        let foreignID = try #require(stored.first?.id), plainID = try #require(stored.last?.id)
        // Even with this server's picture for that muid in the cache.
        let media = MediaStore(profile: storage.directory)
        _ = try media.store(Data("png".utf8), at: media.template(muid: Self.muid), limit: 1_000)
        await #expect(throws: Engine.Failure.untrustedMediaHost("evil.example")) {
            try await engine.templateImage(messageID: foreignID)
        }
        await #expect(throws: Engine.Failure.noPaymentTemplate) { try await engine.templateImage(messageID: plainID) }
        await #expect(throws: Engine.Failure.noPaymentTemplate) { try await engine.templateImage(muid: "../x") }
    }
}
