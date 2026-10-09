import Foundation
import Sphinxrs

extension Engine {
    // MARK: - Attachments

    /// Sends a file to a contact or a tribe as the official apps do: encrypted
    /// with a fresh key, uploaded to the memes server, then a type 6 message
    /// with the media token and key (see the phase 3 notes). The row is
    /// written first and the encrypted file kept until the memes server has
    /// it, so a failed upload or send can be retried without the file. Like
    /// `sendText`, a failure is reported through events, not thrown; the
    /// upload reports `.transfer` progress. `stored` is told the row's id as
    /// soon as the row exists, before the upload (an app shows the file from
    /// disk meanwhile). `priceSats` sells it, as the official apps do: the
    /// price goes in the media token and, in a direct message, the key stays
    /// out of the message until a buyer pays (see `answerPurchase`).
    /// Returns the row's id.
    @discardableResult
    public func sendAttachment(
        _ file: URL, text: String = "", to pubkey: String, replyTo: String? = nil, inThread: String? = nil,
        priceSats: UInt64? = nil, stored: (@Sendable (Int64) -> Void)? = nil
    ) async throws -> Int64 {
        if let priceSats, priceSats == 0 || priceSats > Self.maxAttachmentPriceSats {
            throw Failure.invalidPrice
        }
        let tribe = try openTribe(pubkey)
        guard tribe != nil || Self.isPerson(pubkey, in: state) == true else { throw Failure.notAChat }
        _ = try memesServer()
        let links = try links(replyTo: replyTo, inThread: inThread, in: pubkey)
        let limit = Self.attachmentLimit
        let (outgoing, plain, sealed, key) = try await Task.detached {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { throw Failure.notAFile(file.path) }
            guard (values.fileSize ?? 0) <= limit else { throw TooLarge(limit: limit) }
            let plain = try Data(contentsOf: file)
            guard plain.count <= limit else { throw TooLarge(limit: limit) }
            let key = MediaCrypto.newKey()
            return (OutgoingFile(name: file.lastPathComponent, data: plain), plain,
                    try MediaCrypto.encrypt(plain, key: key), key)
        }.value
        let body = try Self.attachmentBody(
            text: text, key: key, mediaType: outgoing.mediaType, token: nil,
            replyTo: links.replyTo, thread: links.thread, draftPrice: priceSats
        )
        let draft = Message(
            type: MessageType.attachment, chat: pubkey, fromMe: true, body: body, content: text,
            msat: tribe.map { Int64(clamping: $0.messageAmountMsat) }, timestamp: Date().millisecondsSince1970,
            status: Message.Delivery.pending.rawValue, replyUUID: links.replyTo, threadUUID: links.thread,
            mediaType: outgoing.mediaType, fileName: outgoing.fileName,
            fileSize: Int64(plain.count), upload: Message.Upload.pending.rawValue
        )
        guard let row = try storage.apply(Storage.Commit(messages: [(draft, false, nil)])).stored.first, let id = row.id else {
            throw PeelError("the attachment was not stored")
        }
        do {
            try await Task.detached { [media] in try media.write(sealed, to: media.outgoing(id)) }.value
        } catch {
            // Without the encrypted file the row could never be sent.
            try? storage.deleteMessage(id: id)
            throw error
        }
        stored?(id)
        emit.yield(.message(row, .live))
        try await uploadAndDeliver(row, file: (plain, sealed))
        return id
    }

    /// Sends several files to one chat, one message each, with `text` as
    /// the last one's caption, all with the same reply and thread links and
    /// price. They go one after another, each once its upload is done, so
    /// they arrive in order. When the file the caption rode on is refused,
    /// the text still goes on its own (best effort). Each file's row id or
    /// why it was refused, and whether the text went (true when there was
    /// none). `stored` is as for `sendAttachment`, with the file.
    public func sendAttachments(
        _ files: [URL], text: String = "", to pubkey: String, replyTo: String? = nil, inThread: String? = nil,
        priceSats: UInt64? = nil, stored: (@Sendable (URL, Int64) -> Void)? = nil
    ) async -> (results: [(file: URL, result: Result<Int64, any Error>)], textSent: Bool) {
        var results: [(file: URL, result: Result<Int64, any Error>)] = []
        var textSent = text.isEmpty
        for (index, file) in files.enumerated() {
            let caption = index == files.count - 1 ? text : ""
            var storedFile: (@Sendable (Int64) -> Void)?
            if let stored { storedFile = { id in stored(file, id) } }
            do {
                let id = try await sendAttachment(
                    file, text: caption, to: pubkey, replyTo: replyTo, inThread: inThread, priceSats: priceSats,
                    stored: storedFile
                )
                results.append((file, .success(id)))
                if !caption.isEmpty { textSent = true }
            } catch {
                results.append((file, .failure(error)))
            }
        }
        if !textSent, (try? await sendText(text, to: pubkey, replyTo: replyTo, inThread: inThread)) != nil {
            textSent = true
        }
        return (results, textSent)
    }

    /// The message JSON of an attachment, as the Mac app's `formatMsg`: the
    /// key twice (the core encrypts `mediaKeyForSelf` to this account, so our
    /// other devices and a restore can read it), the MIME type and, once
    /// uploaded, the media token.
    /// A paid one in a direct message leaves `mediaKey` out (the seller
    /// sends it to each buyer); a tribe keeps it, as the official apps do.
    /// Before the upload the row keeps the price as `price`, which never
    /// goes out: the sent JSON is made again with the token.
    private static func attachmentBody(
        text: String?, key: String, mediaType: String?, token: String?, replyTo: String?, thread: String?,
        withholdKey: Bool = false, draftPrice: UInt64? = nil
    ) throws -> String {
        var fields = ["content": text ?? "", "mediaKeyForSelf": key]
        if !withholdKey { fields["mediaKey"] = key }
        fields["price"] = draftPrice.map(String.init)
        fields["mediaType"] = mediaType
        fields["mediaToken"] = token
        fields["replyUuid"] = replyTo
        fields["threadUuid"] = thread
        return try json(fields)
    }

    /// Uploads an attachment of ours if the memes server does not have it
    /// yet, then sends the message. An upload that fails marks the row failed.
    /// A first send passes the file and its encrypted form; a retry claims
    /// the row's upload (so it runs only once at a time), reads the outbox,
    /// and leaves the cache to fill on the first download.
    @discardableResult
    func uploadAndDeliver(_ message: Message, file: (plain: Data, sealed: Data)? = nil) async throws -> String? {
        guard let id = message.id, var body = message.body, let fields = AttachmentFields.decode(body),
              let key = fields.ownKey else { throw Failure.notRetryable }
        if message.uploadState != .done {
            if file == nil {
                guard try storage.claimUpload(id: id) else { throw Failure.uploadInProgress }
            }
            do {
                let memes = try memesServer()
                let outbox = media.outgoing(id)
                let sealed = if let file { file.sealed } else {
                    try await Task.detached { try Data(contentsOf: outbox) }.value
                }
                let outgoing = OutgoingFile(fileName: message.fileName ?? "file", mediaType: message.mediaType ?? "")
                let progress = transferProgress(id, .upload)
                let muid = try await withMemes(memes) { token in
                    try await memes.upload(sealed, as: outgoing, token: token, progress: progress)
                }
                // A year, as the official apps give their tokens.
                let expiry = UInt32(clamping: Int(Date().timeIntervalSince1970) + 365 * 24 * 3600)
                let price = BodyFields.decode(body)?.price.flatMap { UInt64($0) }
                let (time, coreState) = (clock.next(), try StateCodec.encode(state))
                let token = try price.map {
                    try Sphinxrs.makeMediaTokenWithPrice(
                        seed: seed, uniqueTime: time, state: coreState, host: memes.host, muid: muid, to: message.chat,
                        expiry: expiry, price: $0
                    )
                } ?? Sphinxrs.makeMediaToken(
                    seed: seed, uniqueTime: time, state: coreState, host: memes.host, muid: muid, to: message.chat,
                    expiry: expiry
                )
                body = try Self.attachmentBody(
                    text: message.content, key: key, mediaType: message.mediaType, token: token,
                    replyTo: message.replyUUID, thread: message.threadUUID,
                    withholdKey: price != nil && tribes[message.chat] == nil
                )
                try storage.setUpload(.done, id: id, body: body)
                // Our own copy is in the cache from the start, as in the official apps.
                let plain = file?.plain
                try? await Task.detached { [media] in
                    if let plain { _ = try? media.store(plain, muid: muid, key: key, limit: Self.mediaCacheLimit) }
                    try FileManager.default.removeItem(at: outbox)
                }.value
            } catch {
                try storage.setUpload(.failed, id: id)
                // It has no tag yet, so the row itself says it failed.
                if let row = try storage.message(id: id) { emit.yield(.message(row, .live)) }
                emit.yield(.conversationError(chat: message.chat, message: "Not uploaded: \(PeelError.readable(error))"))
                return nil
            }
        }
        return try await deliver(body: body, to: message.chat, type: MessageType.attachment, replacing: id)
    }

    /// Reports a transfer's progress as an event for that row.
    private func transferProgress(_ id: Int64, _ direction: Event.Direction) -> MemesServer.Progress {
        let emit = emit
        return { bytes, total in emit.yield(.transfer(messageID: id, direction: direction, bytes: bytes, total: total)) }
    }

    /// Downloads and decrypts an attachment into the profile's cache, or
    /// finds it there, reporting `.transfer` progress while it downloads.
    /// Only from this account's memes server; the bytes are checked against
    /// the declared type, and nothing is ever opened. With `upTo`, one not
    /// cached yet that is larger is refused as `largeAttachment` before its
    /// body is read.
    public func downloadAttachment(messageID: Int64, upTo: Int? = nil) async throws -> DownloadedAttachment {
        guard let message = try storage.message(id: messageID), message.type == MessageType.attachment,
              let fields = AttachmentFields.decode(message.body), let mediaToken = fields.mediaToken,
              let token = MediaToken(mediaToken) else { throw Failure.notAnAttachment }
        // A paid one comes without its key: someone else's opens with the key
        // its seller sent once bought; our own keeps it as `mediaKeyForSelf`.
        let carried = message.fromMe ? fields.ownKey : fields.mediaKey
        guard let key = try carried?.nilIfEmpty ?? storage.purchasedKey(for: message) else {
            throw Failure.attachmentWithoutKey
        }
        let memes = try memesServer()
        guard token.host == memes.host else { throw Failure.untrustedMediaHost(token.host) }
        let declared = AttachmentKind(mediaType: fields.mediaType)
        var fileName = message.fileName
        let stored: (file: URL, kind: AttachmentKind, size: Int)
        let cached = media.lookup(muid: token.muid, key: key)
        if let cached {
            stored = try await Task.detached {
                let plain = try Data(contentsOf: cached, options: .mappedIfSafe)
                return (cached, AttachmentKind.verified(plain, declared: declared), plain.count)
            }.value
        } else {
            if let upTo, let size = message.fileSize, size > upTo { throw Failure.largeAttachment(size: size) }
            // Encryption adds a header, padding and a MAC to what was sent.
            let limit = min(upTo ?? .max, Self.attachmentLimit) + 128
            let progress = transferProgress(messageID, .download)
            let (sealed, name): (Data, String?)
            do {
                (sealed, name) = try await withMemes(memes) { auth in
                    try await memes.download(mediaToken: mediaToken, token: auth, limit: limit, progress: progress)
                }
            } catch let error as TooLarge where upTo != nil {
                throw Failure.largeAttachment(size: error.size)
            }
            stored = try await Task.detached { [media] in
                let plain = try MediaCrypto.decrypt(sealed, key: key)
                let file = try media.store(plain, muid: token.muid, key: key, limit: Self.mediaCacheLimit)
                return (file, AttachmentKind.verified(plain, declared: declared), plain.count)
            }.value
            try storage.setFile(id: messageID, name: name, size: Int64(stored.size))
            fileName = fileName ?? name
        }
        // Unnamed by the server: what the Mac app calls it ("video.mov"), if it is what it says.
        if fileName == nil, stored.kind == declared { fileName = AttachmentKind.fallbackName(mediaType: fields.mediaType) }
        return DownloadedAttachment(
            file: stored.file, kind: stored.kind, fileName: fileName, size: stored.size, cached: cached != nil
        )
    }

    // MARK: - Paid attachments

    /// The most an attachment may be sold for: a mistyped price should not
    /// be a fortune.
    public static let maxAttachmentPriceSats: UInt64 = 10_000_000

    /// Buys someone else's paid attachment, as the official apps do: a
    /// purchase (type 7) to the seller carrying the price its media token
    /// names, with that token and the attachment's uuid. The seller's app
    /// answers with the key (type 8), and the attachment then downloads and
    /// decrypts like any other; or with a refund (type 9). Nothing of it is
    /// fetched before. Refused when not for sale, already bought or on its
    /// way, over the balance, or over the confirmation threshold unless
    /// confirmed. Delivery is reported as for `sendText`.
    @discardableResult
    public func buyAttachment(messageID: Int64, confirmedMsat: UInt64? = nil) async throws -> String? {
        guard let message = try storage.message(id: messageID), !message.fromMe, !message.deleted,
              let price = message.attachmentPriceMsat, let uuid = message.uuid, MessageUUID.isValid(uuid),
              let token = AttachmentFields.decode(message.body)?.mediaToken else {
            throw Failure.notAPaidAttachment
        }
        // Only from this account's memes server, like any download.
        guard let host = MediaToken(token)?.host, host == (try memesServer()).host else {
            throw Failure.untrustedMediaHost(MediaToken(token)?.host ?? "")
        }
        switch try storage.purchaseState(of: message) {
        case .processing?: throw Failure.purchaseInProgress
        case .unlocked?: throw Failure.alreadyBought
        case .locked?, .failed?, .denied?, .forSale?, nil: break
        }
        let toTribe = knownTribe(message.chat) != nil
        try checkPayment(price, .threshold(confirmedMsat), reserveMsat: Self.pingMsat(toTribe: toTribe))
        let purchaseKey = "purchase \(token)"
        guard money.sendsInFlight.insert(purchaseKey).inserted else { throw Failure.purchaseInProgress }
        defer { money.sendsInFlight.remove(purchaseKey) }
        let body = try Self.json(["content": "", "mediaToken": token, "replyUuid": uuid])
        return try await deliver(body: body, to: message.chat, type: MessageType.purchase, amountMsat: price, replacing: nil)
    }

    /// The seller's side, as the official apps answer a purchase of one of
    /// their paid attachments in a direct message (in a tribe the tribes
    /// server holds the key and answers): the key when the sats that came
    /// (`msat`, what really arrived) cover the price, give or take the
    /// official apps' 3 sats for routing (never more than a tenth of the
    /// price, so a cheap one is not given away). A purchase is answered
    /// once. One that pays too little is left unanswered: the official apps
    /// refund it automatically, but two of this account's devices online at
    /// once would each refund it (see docs/phases/04-money.md).
    func answerPurchase(_ purchase: Message) async throws {
        guard !purchase.fromMe, tribes[purchase.chat] == nil,
              let token = AttachmentFields.decode(purchase.body)?.mediaToken,
              let attachment = try storage.ownAttachment(token: token, in: purchase.chat),
              let price = attachment.attachmentPriceMsat,
              let fields = AttachmentFields.decode(attachment.body),
              let key = fields.ownKey,
              try !storage.isAnswered(purchase: purchase, token: token) else { return }
        let paid = UInt64(max(purchase.msat ?? 0, 0))
        guard paid > 0, paid + min(3000, price / 10) >= price else {
            emit.yield(.conversationError(
                chat: purchase.chat,
                message: "A purchase of your paid attachment brought \(Sats.format(msat: paid, of: price)), so its key was not sent"
            ))
            return
        }
        var answer = ["content": "", "mediaKey": key, "mediaKeyForSelf": key, "mediaToken": token]
        answer["mediaType"] = fields.mediaType
        try await deliver(body: try Self.json(answer), to: purchase.chat, type: MessageType.purchaseAccept, replacing: nil)
    }

    /// The account's memes server: the one recorded, else the official
    /// apps' own, except on a local test server, which has none unless named.
    func memesServer() throws -> MemesServer {
        guard let host = try configuredHost(.memesHost, default: Self.defaultMemesHost) else { throw Failure.noMemesServer }
        return try MemesServer(host: host)
    }

    /// Runs a memes server call with a bearer token, signing in again once
    /// if the server no longer takes the one kept.
    func withMemes<T>(_ memes: MemesServer, _ call: (MemesServer.Token) async throws -> T) async throws -> T {
        do {
            return try await call(memesSignIn(memes, refresh: false))
        } catch let error as MemesServer.Failure where error.isUnauthorized {
            return try await call(memesSignIn(memes, refresh: true))
        }
    }

    /// The bearer token: kept in memory until shortly before it expires. A
    /// new one is had by signing the server's challenge with the account key.
    private func memesSignIn(_ memes: MemesServer, refresh: Bool) async throws -> MemesServer.Token {
        if !refresh, let kept = memesToken, kept.host == memes.host, kept.token.isFresh { return kept.token }
        let (id, challenge) = try await memes.challenge()
        guard let bytes = MemesServer.challengeBytes(challenge) else {
            throw MemesServer.Failure.unreadableReply("sign-in")
        }
        let signature = try Sphinxrs.signBase64(
            seed: seed, idx: 0, time: clock.next(), network: network, msg: MediaToken.base64URLEncode(bytes)
        )
        let pubkey = try Sphinxrs.pubkeyFromSeed(seed: seed, idx: 0, time: clock.next(), network: network)
        let token = try await memes.verify(id: id, signature: signature, pubkey: pubkey)
        memesToken = (memes.host, token)
        return token
    }
}
