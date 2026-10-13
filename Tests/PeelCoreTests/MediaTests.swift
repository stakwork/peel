import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PeelCore
@testable import PeelTestSupport

/// How many source pixels a still is decoded from (`ImageDecoding.isTooLarge`).
/// ImageIO reports no size for a header that claims more than its bytes
/// hold, so the rule is tested on the sizes, and the reading on real pictures.
struct SourcePixelTests {
    /// A 20 × 10 picture in `type`, as ImageIO writes it.
    static func picture(_ type: UTType) throws -> CGImageSource {
        let context = try #require(CGContext(
            data: nil, width: 20, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return try #require(CGImageSourceCreateWithData(data, nil))
    }

    @Test func photosFromPhoneCamerasAreDecoded() {
        // Samsung's 108 MP and 200 MP, a medium-format 102 MP, a long panorama.
        #expect(!ImageDecoding.isTooLarge(width: 12_000, height: 9_000, type: .jpeg))
        #expect(!ImageDecoding.isTooLarge(width: 16_320, height: 12_240, type: .heic))
        #expect(!ImageDecoding.isTooLarge(width: 11_648, height: 8_736, type: .jpeg))
        #expect(!ImageDecoding.isTooLarge(width: 60_000, height: 6_000, type: .jpeg))
        // Past the scaled formats' limit, even a JPEG is not.
        #expect(ImageDecoding.isTooLarge(width: 30_000, height: 20_000, type: .jpeg))
    }

    @Test func formatsDecodedInFullHaveTheStrictLimit() {
        // 144 MP, which a template or someone's attachment of a few megabytes could claim.
        for type in [UTType.png, .gif, .tiff, .bmp] {
            #expect(ImageDecoding.isTooLarge(width: 12_000, height: 12_000, type: type))
            #expect(!ImageDecoding.isTooLarge(width: 10_000, height: 10_000, type: type))
        }
        #expect(ImageDecoding.isTooLarge(width: 12_000, height: 12_000, type: nil))
        #expect(ImageDecoding.isTooLarge(width: .max, height: 2, type: .jpeg))
    }

    @Test func aPicturesOwnSizeAndFormatAreRead() throws {
        for type in [UTType.png, .jpeg] {
            let source = try Self.picture(type)
            #expect(CGImageSourceGetType(source) as String? == type.identifier)
            #expect(!ImageDecoding.isTooLarge(source))
            #expect(ImageDecoding.thumbnail(source, maxPixels: 64) != nil)
        }
    }
}

/// A 1×1 PNG.
private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!

struct MediaCryptoTests {
    @Test func newKeyIsHexOfThirtyTwoLettersAndDigits() {
        let key = MediaCrypto.newKey()
        #expect(key.count == 64)
        let ascii = String(decoding: hex(key), as: UTF8.self)
        #expect(ascii.count == 32)
        #expect(ascii.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) })
        #expect(MediaCrypto.newKey() != key)
    }

    @Test(arguments: [0, 1, 15, 16, 17, 1000, 70_000])
    func roundTrip(size: Int) throws {
        let plain = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let key = MediaCrypto.newKey()
        let sealed = try MediaCrypto.encrypt(plain, key: key)
        // Header, whole AES blocks, MAC.
        #expect(sealed.count == 34 + (size / 16 + 1) * 16 + 32)
        #expect(sealed.prefix(2) == Data([3, 1]))
        #expect(try MediaCrypto.decrypt(sealed, key: key) == plain)
        // Fresh salts and IV every time.
        #expect(try MediaCrypto.encrypt(plain, key: key) != sealed)
    }

    /// Made by an independent RNCryptor v3 implementation (Python
    /// `cryptography`: PBKDF2-SHA1 ×10,000, AES-256-CBC, HMAC-SHA256) with
    /// fixed salts and IV, so Peel reads what the official apps write.
    @Test func decryptsAnRNCryptorVector() throws {
        let sealed = hex(
            "03010001020304050607010203040506070802030405060708090a0b0c0d0e0f1011824c3d7d729a392faace1f72e6161d"
            + "8886a54b5deb5704ff5f40982db64f6964c4bbbfed851edd0f1c3bab4595d1c8c254a55b7a933d3a9a033624edcc31096b"
        )
        let plain = try MediaCrypto.decrypt(sealed, key: String(repeating: "3a", count: 32))
        #expect(String(decoding: plain, as: UTF8.self) == "peel attachment vector")
    }

    @Test(arguments: [Data(), Data([3, 1]), Data([2, 1] + [UInt8](repeating: 0, count: 100))])
    func malformedIsRefused(sealed: Data) {
        #expect(throws: MediaCrypto.Failure.self) { try MediaCrypto.decrypt(sealed, key: "00") }
    }
}

struct MediaTokenTests {
    private func token(host: String, muid: String, meta: String = "") -> String {
        let b64 = { (data: Data) in MediaToken.base64URLEncode(data) }
        return [b64(Data(host.utf8)), muid, "", b64(Data([0, 0, 1, 0])), b64(Data(meta.utf8)), "c2ln"]
            .joined(separator: ".")
    }

    @Test func readsHostAndMuid() throws {
        let parsed = try #require(MediaToken(token(host: "memes.sphinx.chat", muid: "qFSOa50yWeGSG8oelsMvctLYdejPRD090dsypBSx_xg=")))
        #expect(parsed.host == "memes.sphinx.chat")
        #expect(parsed.muid == "qFSOa50yWeGSG8oelsMvctLYdejPRD090dsypBSx_xg=")
        #expect(MediaToken(token(host: "h", muid: "m", meta: "amt=21"))?.muid == "m")
    }

    @Test(arguments: ["", "bm90IGEgaG9zdA", "!!!.muid", "aGVsbG8=."])
    func unreadableTokensAreRefused(text: String) {
        #expect(MediaToken(text) == nil)
    }

    @Test func challengeIsReadAsTheMacAppReadsIt() {
        let bytes = Data([0xfb, 0xff, 0x00, 0x10, 0x20])
        let urlSafe = MediaToken.base64URLEncode(bytes)
        #expect(urlSafe.contains("-") || urlSafe.contains("_"))
        #expect(MemesServer.challengeBytes(urlSafe) == bytes)
        #expect(MemesServer.challengeBytes(bytes.base64EncodedString()) == bytes)
        // Not a multiple of four: cut, as `nonBase64Data` does.
        #expect(MemesServer.challengeBytes("AAECAw") == Data([0, 1, 2]))
    }

    @Test func bearerTokenExpiryComesFromTheJWT() {
        let payload = MediaToken.base64URLEncode(Data(#"{"exp":4102444800}"#.utf8))
        let token = MemesServer.Token("e30.\(payload).sig")
        #expect(token.expires == Date(timeIntervalSince1970: 4_102_444_800))
        #expect(token.isFresh)
        #expect(!MemesServer.Token("opaque").isFresh)
    }
}

struct AttachmentKindTests {
    /// The Mac app sends `video/mov`, which UTType does not know: it is a video all the same.
    @Test(arguments: [
        ("image/jpg", AttachmentKind.image), ("image/gif", .image), ("", .image), ("video/mov", .video),
        ("video/quicktime", .video), ("video/mp4", .video), ("video", .video), ("audio/wav", .audio),
        ("audio/mpeg", .audio), ("audio/x-m4a", .audio), ("application/pdf", .pdf), ("sphinx/text", .text),
        ("application/zip", .file), ("application/octet-stream", .file),
    ])
    func kindFromMediaType(type: String, kind: AttachmentKind) {
        #expect(AttachmentKind(mediaType: type) == kind)
    }

    @Test func bytesMustMatchTheDeclaredKind() {
        #expect(AttachmentKind.verified(png, declared: .image) == .image)
        #expect(AttachmentKind.verified(Data("<html>".utf8), declared: .image) == .file)
        #expect(AttachmentKind.verified(Data("%PDF-1.7\n".utf8), declared: .pdf) == .pdf)
        #expect(AttachmentKind.verified(png, declared: .pdf) == .file)
        #expect(AttachmentKind.verified(Data([0, 0, 0, 0x18] + Array("ftypmp42".utf8)), declared: .video) == .video)
        #expect(AttachmentKind.verified(Data("#!/bin/sh\n".utf8), declared: .video) == .file)
        #expect(AttachmentKind.verified(Data(Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WAVE".utf8)), declared: .audio) == .audio)
        #expect(AttachmentKind.verified(Data("MZ".utf8), declared: .audio) == .file)
        #expect(AttachmentKind.verified(Data([0xff, 0xfe, 0xfd]), declared: .text) == .file)
    }

    @Test func outgoingFilesAreNamedAsTheMacAppNamesThem() {
        let photo = OutgoingFile(name: "holiday.png", data: png)
        #expect(photo == OutgoingFile(fileName: "image.jpg", mediaType: "image/jpg"))
        #expect(photo.field == "image")
        let pdf = OutgoingFile(name: "report.pdf", data: Data("%PDF-1.7".utf8))
        #expect(pdf == OutgoingFile(fileName: "report.pdf", mediaType: "application/pdf"))
        #expect(pdf.field == "file")
        #expect(OutgoingFile(name: "clip.mov", data: Data()) == OutgoingFile(fileName: "video.mov", mediaType: "video/mov"))
        #expect(OutgoingFile(name: "clip.mp4", data: Data()).mediaType == "video/mov")
        // Other videos go as files, as from the Mac app.
        #expect(OutgoingFile(name: "clip.avi", data: Data()).fileName == "clip.avi")
        #expect(OutgoingFile(name: "a\r\nb.txt", data: Data()).fileName == "a\r\nb.txt")
        #expect(OutgoingFile(name: "notes.zip", data: Data([1])).mediaType == "application/zip")
        #expect(OutgoingFile(name: "README", data: Data([1])).mediaType == "application/octet-stream")
        #expect(OutgoingFile(fileName: "audio.wav", mediaType: "audio/wav").field == "audio")
    }

    @Test func memesHostsAreHTTPSExceptHere() throws {
        #expect(throws: MemesServer.Failure.self) { try MemesServer(host: "evil.com/path") }
        #expect(throws: MemesServer.Failure.self) { try MemesServer(host: "user@evil.com") }
        _ = try MemesServer(host: "memes.sphinx.chat")
        _ = try MemesServer(host: "127.0.0.1:8857")
    }
}

struct MediaStoreTests {
    let profile = TempProfile()

    @Test func cacheIsTrimmedOldestFirst() throws {
        let store = MediaStore(profile: profile.url)
        let old = try store.store(Data(repeating: 1, count: 600), muid: "old", key: "k", limit: 10_000)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -100)], ofItemAtPath: old.path)
        _ = try store.store(Data(repeating: 2, count: 600), muid: "new", key: "k", limit: 1_000)
        #expect(store.lookup(muid: "old", key: "k") == nil)
        #expect(store.lookup(muid: "new", key: "k") != nil)
    }

    @Test func entriesAreKeyedByMuidAndKey() throws {
        let store = MediaStore(profile: profile.url)
        let file = try store.store(Data("x".utf8), muid: "../../escape", key: "k1", limit: 1_000)
        #expect(file.deletingLastPathComponent().standardizedFileURL == store.cache.standardizedFileURL)
        #expect(store.lookup(muid: "../../escape", key: "k2") == nil)
        #expect(store.lookup(muid: "../../escape", key: "k1") == file)
    }
}

struct AttachmentStorageTests {
    let profile = TempProfile()

    private func outgoing() -> Message {
        var message = Message.fixture(
            uuid: nil, type: MessageType.attachment, fromMe: true, body: #"{"content":"","mediaKey":"k"}"#,
            content: "", status: Message.Delivery.pending.rawValue
        )
        message.mediaType = "image/jpg"
        message.fileName = "image.jpg"
        message.fileSize = 70
        message.upload = Message.Upload.pending.rawValue
        return message
    }

    private func store(_ message: Message, in storage: Storage) throws -> Message {
        try #require(try storage.apply(Storage.Commit(messages: [(message, false, nil)])).stored.first)
    }

    @Test func outgoingAttachmentMovesThroughItsUpload() throws {
        let storage = try profile.storage()
        let row = try store(outgoing(), in: storage)
        let id = try #require(row.id)
        #expect(row.uploadState == .pending)
        #expect(row.attachmentKind == .image)
        #expect(row.fileName == "image.jpg")

        try storage.setUpload(.failed, id: id)
        #expect(try storage.message(id: id)?.delivery == .failed)
        #expect(try storage.message(id: id)?.isRetryable() == true)

        // A retry claims the upload once; a second claim waits for it.
        #expect(try storage.claimUpload(id: id))
        #expect(try !storage.claimUpload(id: id))
        #expect(try storage.message(id: id)?.isRetryable() == false)

        try storage.setUpload(.done, id: id, body: #"{"mediaToken":"t"}"#)
        let done = try #require(try storage.message(id: id))
        #expect(done.uploadState == .done)
        #expect(done.body == #"{"mediaToken":"t"}"#)
        #expect(try !storage.claimUpload(id: id))

        // Sending it then takes over the row, as a resend does for text.
        let sent = try storage.apply(Storage.Commit(resend: (id, "02aa", "u9", "tag9", nil, nil, 5_000, false))).stored
        #expect(sent.first?.uuid == "u9")
        #expect(sent.first?.delivery == .pending)
        #expect(sent.first?.uploadState == .done)
    }

    @Test func anUploadInFlightIsNotRetryableAndOneCutOffIs() throws {
        let storage = try profile.storage()
        var row = try store(outgoing(), in: storage)
        row.timestamp = 0
        #expect(!row.isRetryable())
        try storage.failInterruptedUploads()
        let id = try #require(row.id)
        let after = try #require(try storage.message(id: id))
        #expect(after.uploadState == .failed)
        #expect(after.delivery == .failed)
        #expect(after.isRetryable())
    }

    @Test func incomingAttachmentKeepsItsFieldsAcrossCopies() throws {
        let storage = try profile.storage()
        var live = Message.fixture(uuid: "u1", type: MessageType.attachment, content: "look")
        live.mediaType = "application/pdf"
        let id = try #require(try store(live, in: storage).id)
        var history = Message.fixture(uuid: "u1", serverIndex: 5, type: MessageType.attachment, content: "look")
        history.mediaType = "image/jpg"
        let merged = try store(history, in: storage)
        #expect(merged.mediaType == "application/pdf")
        #expect(merged.serverIndex == 5)

        try storage.setFile(id: id, name: "report.pdf", size: 1234)
        let row = try #require(try storage.message(id: id))
        #expect(row.fileName == "report.pdf")
        #expect(row.fileSize == 1234)
    }

    @Test func attachmentsShowInTheChatAndCountAsUnread() async throws {
        let storage = try profile.storage()
        _ = try storage.apply(Storage.Commit(
            contacts: [(pubkey: "02aa", ready: true)],
            messages: [
                (.fixture(uuid: "u1", serverIndex: 1, chat: "02aa", content: "text", timestamp: 1_000), false, nil),
                (.fixture(uuid: "u2", serverIndex: 2, type: MessageType.attachment, chat: "02aa", content: "", timestamp: 2_000), false, nil),
            ]
        ))
        let messages = try #require(try await first(storage.timeline(in: "02aa"))).messages
        #expect(messages.map(\.uuid) == ["u1", "u2"])
        let states = try #require(try await first(storage.readStates()))
        #expect(states["02aa"]?.unread == 2)
        let conversations = try #require(try await first(storage.conversations()))
        #expect(conversations.first?.lastTimestamp == 2_000)
    }
}

struct UserFilesTests {
    @Test func savesUnderAFreeNameAndKeepsItOneFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source")
        try Data("hi".utf8).write(to: source)
        let downloads = directory.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)

        let first = try UserFiles.save(source, named: "notes.txt", in: downloads)
        let second = try UserFiles.save(source, named: "notes.txt", in: downloads)
        #expect(first.lastPathComponent == "notes.txt")
        #expect(second.lastPathComponent == "notes (1).txt")
        #expect(UserFiles.cleanName("../../etc/passwd") == "-..-etc-passwd")
        #expect(UserFiles.cleanName(".hidden") == "hidden")
        #expect(UserFiles.cleanName("") == "file")
        #expect(UserFiles.cleanName(" .zshrc") == "zshrc")
        // Quarantine is the Mac's alone (`UserFiles.quarantine`).
        #if os(macOS)
        #expect(try first.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties != nil)
        #endif
    }
}
