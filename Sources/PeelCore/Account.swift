import Foundation

/// Opening, creating and restoring accounts: the one place that decides where
/// the mnemonic, the server and the tribes host come from. Connecting is left to the caller, so
/// an app can show a returning account while it is still offline.
public enum Account {
    /// Loads an existing account without connecting it. Development profiles
    /// have no PIN and ignore the argument. A server or tribes host given here
    /// replaces the recorded one.
    public static func load(
        _ profile: Profile, pin: String = "", server: ServerAddress? = nil, tribeHost: String? = nil
    ) async throws -> Engine {
        let engine = try Engine(mnemonic: profile.loadMnemonic(pin: pin), storage: Storage(directory: profile.directory))
        if let server { try await engine.setServer(server) }
        if let tribeHost { try await engine.setTribeHost(tribeHost) }
        return engine
    }

    /// A new account, with the words the person must write down.
    public struct Created {
        public let engine: Engine
        public let mnemonic: String
    }

    /// Creates an account from an invite and connects. The profile is removed
    /// again only if the server never registered the account, since a
    /// registered one has used the invite. Adding the inviter as the first
    /// contact comes last; if that fails the account still exists. The tribes
    /// host comes from the public config when the invite names the server;
    /// if the config cannot be read, the engine tries again on coming online.
    public static func signup(
        _ profile: Profile, invite: Engine.Invite, alias: String, pin: String, network: String = "bitcoin",
        server: ServerAddress? = nil, tribeHost: String? = nil, allowUntrustedCertificate: Bool = false
    ) async throws -> Created {
        guard let address = server ?? invite.server.flatMap(ServerAddress.init) else {
            throw PeelError("the invite does not say which server to use")
        }
        var tribeHost = tribeHost
        if tribeHost == nil, server == nil {
            tribeHost = try? await ServerConfig.fetch(network: network).usableTribeHost
        }
        let created = try await create(
            profile, alias: alias, pin: pin, network: network, server: address, tribeHost: tribeHost
        )
        let engine = created.engine
        do {
            try await engine.connect(inviteCode: invite.code, allowUntrustedCertificate: allowUntrustedCertificate)
        } catch {
            if await !engine.isRegistered {
                try? profile.delete()
            }
            throw error
        }
        if let inviter = invite.inviterContactInfo {
            try await engine.addContact(inviter, alias: invite.inviterAlias, inviteCode: invite.code)
        }
        return created
    }

    /// Creates an account that needs no invite, for a local test server.
    public static func create(
        _ profile: Profile, alias: String, pin: String, network: String = "bitcoin", server: ServerAddress,
        tribeHost: String? = nil
    ) async throws -> Created {
        if profile.requiresPIN { try PIN.validate(pin) }
        let mnemonic = try Engine.generateMnemonic()
        let engine = try await open(
            profile, mnemonic: mnemonic, pin: pin, alias: alias, network: network, server: server, tribeHost: tribeHost
        )
        return Created(engine: engine, mnemonic: mnemonic)
    }

    /// Brings an account back from its twelve words and marks it for a history
    /// restore on first connect. The server and the tribes host come from the
    /// public config unless given; tribes found in the history are looked up
    /// only on that host.
    public static func restore(
        _ profile: Profile, mnemonic: String, alias: String, pin: String, network: String = "bitcoin",
        server: ServerAddress? = nil, tribeHost: String? = nil
    ) async throws -> Engine {
        if profile.requiresPIN { try PIN.validate(pin) }
        let words = try Engine.validate(mnemonic: mnemonic)
        let address: ServerAddress
        var tribeHost = tribeHost
        if let server {
            address = server
        } else {
            let config = try await ServerConfig.fetch(network: network)
            guard let parsed = ServerAddress(config.defaultLSP) else {
                throw PeelError("the server address in the config is unreadable")
            }
            address = parsed
            tribeHost = tribeHost ?? config.usableTribeHost
        }
        return try await open(
            profile, mnemonic: words, pin: pin, alias: alias, network: network, server: address, tribeHost: tribeHost,
            needsRestore: true
        )
    }

    /// Sets the account up and saves the words last, so a failure part-way
    /// leaves nothing that would block trying again.
    private static func open(
        _ profile: Profile, mnemonic: String, pin: String, alias: String, network: String, server: ServerAddress,
        tribeHost: String?, needsRestore: Bool = false
    ) async throws -> Engine {
        let storage = try Storage(directory: profile.directory)
        try storage.set(network, for: .network)
        if needsRestore { try storage.set("1", for: .needsRestore) }
        let engine = try Engine(mnemonic: mnemonic, storage: storage)
        try await engine.setAlias(alias)
        try await engine.setServer(server)
        if let tribeHost { try await engine.setTribeHost(tribeHost) }
        try profile.secrets.save(mnemonic: mnemonic, pin: pin)
        return engine
    }
}
