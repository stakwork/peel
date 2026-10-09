import Foundation
import Sphinxrs

extension Engine {
    // MARK: - Pure helpers

    public static func generateMnemonic() throws -> String {
        let entropy = (0..<16).map { _ in UInt8.random(in: .min ... .max) }
        return try Sphinxrs.mnemonicFromEntropy(entropy: entropy.hex)
    }

    /// Checks twelve words and returns them in canonical form.
    public static func validate(mnemonic: String) throws -> String {
        let words = normalise(mnemonic: mnemonic)
        _ = try Sphinxrs.mnemonicToSeed(mnemonic: words)
        return words
    }

    /// The words in whatever someone typed or pasted: any case, separated by
    /// whitespace or commas.
    public static func words(in text: String) -> [String] {
        text.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
    }

    static func normalise(mnemonic: String) -> String {
        words(in: mnemonic).joined(separator: " ")
    }

    public static func parseInvite(_ text: String) throws -> Invite {
        let parsed = try Sphinxrs.parseInvite(inviteQr: text.trimmingCharacters(in: .whitespacesAndNewlines))
        return Invite(
            code: parsed.code,
            server: parsed.lspHost,
            inviterContactInfo: parsed.inviterContactInfo,
            inviterAlias: parsed.inviterAlias
        )
    }

    /// The contacts an account holds, without deriving its seed.
    public static func contacts(in storage: Storage) throws -> [Contact] {
        try contacts(in: storage.loadCoreState())
    }

    static func index(_ contacts: [Contact]) -> [UInt64: String] {
        Dictionary(contacts.map { ($0.childIndex, $0.pubkey) }, uniquingKeysWith: { $1 })
    }

    static func contacts(in state: [String: Data]) throws -> [Contact] {
        let json = try Sphinxrs.listContacts(state: StateCodec.encode(state))
        return try JSONDecoder().decode([Contact].self, from: Data(json.utf8))
    }

    static func isRegistered(_ state: [String: Data]) -> Bool {
        state["my_scid"] != nil && state["server_pubkey"] != nil
    }

    // MARK: - Account

    public var isRegistered: Bool { Self.isRegistered(state) }

    /// The name and photo this account sends with its messages.
    public var myAlias: String { alias }
    public var myPhotoURL: String? { photoURL.httpsOnly }
    /// The aliases each tribe echoed back on this account's own messages,
    /// by tribe; with the name, what a mention of it looks like there
    /// (`ownMentionAliases`). Changes arrive as `.echoedAliases`.
    public var echoedOwnAliases: [String: Set<String>] { echoedAliases }

    /// The name others see. Names are not core state and the server keeps no
    /// profile: it travels with each message sent from now on (and with a
    /// tribe join), and a contact's app takes the newest one it sees, as with
    /// the official apps. Nothing is announced and sent messages keep the old one.
    public func setAlias(_ alias: String) throws {
        let alias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !alias.isEmpty else { throw Failure.emptyName }
        try storage.set(alias, for: .alias)
        self.alias = alias
        emit.yield(.profile(alias: alias, photoURL: myPhotoURL))
        checkMentionsIfNeeded()
    }

    /// Re-checks stored tribe messages for mentions of this account whenever
    /// the aliases that name it have changed since the last check (or were
    /// never checked: history stored before mentions were flagged), only in
    /// the tribes affected unless the account's alias changed. Runs in the
    /// background, off this actor, once at a time; a change meanwhile starts
    /// another when it ends. Not during a restore, which flags what it stores
    /// and checks at its end. Called on rename, when an echo brings a new
    /// alias, and at the end of each history sync.
    func checkMentionsIfNeeded() {
        guard mentionScan == nil, !restoring, !alias.isEmpty else { return }
        let own = tribes.values.filter { !$0.left && $0.myAlias != nil }.map { ($0.pubkey, $0.sentAlias(account: alias)) }
        let mark = MentionScan(sent: tribeAlias(alias), echoed: echoedAliases, own: Dictionary(own) { $1 })
        let last = (try? storage.value(for: .mentionScan)).flatMap(MentionScan.init(stored:))
        guard mark != last, let stored = mark.stored else { return }
        let chats = mark.chats(changedSince: last)
        let storage = storage
        mentionScan = Task.detached { [weak self] in
            let result = Result {
                try storage.rescanMentions(sent: mark.sent, echoed: mark.echoed, own: mark.own ?? [:], in: chats)
                try storage.set(stored, for: .mentionScan)
            }
            await self?.mentionScanEnded(result)
        }
    }

    /// The aliases may have changed while the scan ran; a failed one waits
    /// for the next trigger.
    private func mentionScanEnded(_ result: Result<Void, any Error>) {
        mentionScan = nil
        switch result {
        case .success: checkMentionsIfNeeded()
        case .failure(let error): emit.yield(.coreError("checking mentions: \(PeelError.readable(error))"))
        }
    }

    /// The photo others see beside this account's messages: an https URL, or
    /// empty for none. It travels like the name. `uploadPhoto` puts a picture
    /// from this Mac on the memes server and passes its link here.
    public func setPhotoURL(_ url: String) throws {
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard url.isEmpty || url.httpsOnly != nil else { throw Failure.photoNotHTTPS }
        try storage.set(url, for: .photoURL)
        photoURL = url
        emit.yield(.profile(alias: alias, photoURL: myPhotoURL))
    }

    /// Makes a picture this account's photo, as the Mac app's profile screen
    /// does (`uploadPicture`). Returns the link.
    @discardableResult
    public func uploadPhoto(_ file: URL) async throws -> String {
        let url = try await uploadPicture(file)
        try setPhotoURL(url)
        return url
    }

    /// Puts a picture on the memes server as the Mac app's
    /// `uploadPublicImage` does, for a profile photo or a tribe's image: a
    /// JPEG at quality 0.5 (here also at most 1024 px on its long side)
    /// uploaded in the clear to the `/public` route. Returns its public link.
    public func uploadPicture(_ file: URL) async throws -> String {
        let memes = try memesServer()
        let limit = Self.attachmentLimit
        let jpeg = try await Task.detached { try ProfilePhoto.jpeg(from: file, limit: limit) }.value
        let muid = try await withMemes(memes) { token in
            try await memes.upload(
                jpeg, as: OutgoingFile(fileName: "image.jpg", mediaType: "image/jpg"), token: token, route: "public"
            )
        }
        return memes.publicURL(muid).absoluteString
    }

    /// Hours after which an app asks for the PIN again; 0 means only at
    /// launch, nil that this account has never set it.
    public func pinTimeoutHours() throws -> Int? {
        try storage.value(for: .pinTimeoutHours).flatMap { Int($0) }
    }

    public func setPINTimeout(hours: Int) throws {
        try storage.set(String(max(0, hours)), for: .pinTimeoutHours)
    }

    /// Whether an app's notifications may show what a message says; on
    /// unless turned off.
    public func notificationShowsText() throws -> Bool {
        try storage.value(for: .notificationText) != "0"
    }

    public func setNotificationShowsText(_ shows: Bool) throws {
        try storage.set(shows ? "1" : "0", for: .notificationText)
    }

    /// What an app shows of the account when it opens, read in one call off
    /// its actor. A setting that cannot be read is nil, as each getter's
    /// failure would be.
    public struct Settings: Sendable {
        public let alias: String
        public let photoURL: String?
        public let echoedAliases: [String: Set<String>]
        public let contactInfo: String?
        /// The server this account talks to, as `host:port`.
        public let server: String?
        public let callServer: String?
        public let pinTimeoutHours: Int?
        public let balanceMsat: UInt64?
        public let paymentConfirmationMsat: UInt64?
        public let boostAmountMsat: UInt64?
        public let notificationShowsText: Bool?
        public let connection: ConnectionState
    }

    public func settings() -> Settings {
        Settings(
            alias: myAlias, photoURL: myPhotoURL, echoedAliases: echoedOwnAliases,
            contactInfo: try? storage.value(for: .contactInfo), server: try? storage.value(for: .server),
            callServer: try? callServer(), pinTimeoutHours: try? pinTimeoutHours(),
            balanceMsat: try? storage.balanceMsat(),
            paymentConfirmationMsat: try? paymentConfirmationMsat(), boostAmountMsat: try? boostAmountMsat(),
            notificationShowsText: try? notificationShowsText(), connection: connection
        )
    }

    /// A server's `host[:port]`: the setting if recorded, else `fallback`,
    /// except on a local test server, which has none unless named.
    func configuredHost(_ setting: Setting, default fallback: String) throws -> String? {
        if let host = try storage.value(for: setting) { return host }
        guard let server, !ServerAddress.isLoopback(host: server.host) else { return nil }
        return fallback
    }

    public func setServer(_ server: ServerAddress) throws {
        try storage.set(server.description, for: .server)
        self.server = server
    }

    /// The tribes server this account's own tribes are listed on, as `host[:port]`.
    public func setTribeHost(_ host: String) throws {
        guard TribeLink.isPlainHost(host) else { throw Failure.unreadableTribeHost(host) }
        try storage.set(host, for: .tribeHost)
    }

    /// The memes server attachments go to and come from, as `host[:port]`.
    public func setMemesHost(_ host: String) throws {
        _ = try MemesServer(host: host)
        try storage.set(host, for: .memesHost)
    }

    /// The call server calls are started on, as `host[:port]`.
    public func setCallServer(_ host: String) throws {
        let host = host.lowercased()
        guard TribeLink.baseURL(host) != nil else { throw Failure.unreadableCallServer(host) }
        try storage.set(host, for: .callServer)
        // Its socket would otherwise stay open to the old server.
        if let old = calls, old.host != host {
            calls = nil
            Task { await old.close() }
        }
    }

    public func contacts() throws -> [Contact] {
        try Self.contacts(in: state)
    }
}
