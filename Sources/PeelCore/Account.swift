import Foundation

/// Opening, creating and restoring accounts: the one place that decides where
/// the mnemonic, the server and the tribes host come from. Connecting is left to the caller, so
/// an app can show a returning account while it is still offline.
public enum Account {
    /// Loads an existing account without connecting it. Development profiles
    /// have no PIN and ignore the argument. A server, tribes host or memes
    /// host given here replaces the recorded one.
    public static func load(
        _ profile: Profile, pin: String = "", server: ServerAddress? = nil, tribeHost: String? = nil,
        memesHost: String? = nil
    ) async throws -> Engine {
        let engine = try Engine(mnemonic: profile.loadMnemonic(pin: pin), storage: Storage(directory: profile.directory))
        if let server { try await engine.setServer(server) }
        if let tribeHost { try await engine.setTribeHost(tribeHost) }
        if let memesHost { try await engine.setMemesHost(memesHost) }
        return engine
    }

    /// A new account, with the words the person must write down.
    public struct Created {
        public let engine: Engine
        public let mnemonic: String
    }

    /// Creates an account from an invite and connects. The profile is removed
    /// again only if no register can have reached the server: the server
    /// redeems the invite as it registers the account, before it answers, so
    /// an answer lost or late may hide an account that holds the invite's
    /// sats. Such an account is returned unconfirmed and disconnected, its
    /// words kept; it registers again as it connects, and either way the
    /// inviter is added once the account is online (`Setting.invite`).
    /// The tribes host comes from the public config when the invite names
    /// the server, unless that server is a loopback one (a local test stack,
    /// which the production config does not describe); if the config cannot
    /// be read, the engine tries again on coming online.
    public static func signup(
        _ profile: Profile, invite: Engine.Invite, alias: String, pin: String, network: String = "bitcoin",
        server: ServerAddress? = nil, tribeHost: String? = nil, memesHost: String? = nil,
        allowUntrustedCertificate: Bool = false
    ) async throws -> Created {
        guard let address = try server ?? invite.server.map(ServerAddress.named) else {
            throw PeelError("the invite does not say which server to use")
        }
        var tribeHost = tribeHost
        if tribeHost == nil, server == nil, !ServerAddress.isLoopback(host: address.host) {
            tribeHost = try? await ServerConfig.fetch(network: network).usableTribeHost
        }
        let created = try await create(
            profile, alias: alias, pin: pin, network: network, server: address, tribeHost: tribeHost,
            memesHost: memesHost
        )
        let engine = created.engine
        do {
            try await engine.storeInvite(invite)
            try await engine.connect(allowUntrustedCertificate: allowUntrustedCertificate)
        } catch {
            let (registered, redeemed) = await (engine.isRegistered, engine.inviteMayBeRedeemed)
            guard registered || redeemed else {
                try? profile.delete()
                throw error
            }
            await engine.disconnect()
        }
        return created
    }

    /// Creates an account that needs no invite, for a local test server.
    public static func create(
        _ profile: Profile, alias: String, pin: String, network: String = "bitcoin", server: ServerAddress,
        tribeHost: String? = nil, memesHost: String? = nil
    ) async throws -> Created {
        if profile.requiresPIN { try PIN.validate(pin) }
        let mnemonic = try Engine.generateMnemonic()
        let engine = try await open(
            profile, mnemonic: mnemonic, pin: pin, alias: alias, network: network, server: server, tribeHost: tribeHost,
            memesHost: memesHost
        )
        return Created(engine: engine, mnemonic: mnemonic)
    }

    /// Brings an account back from its twelve words and marks it for a history
    /// restore on first connect. The server and the tribes host come from the
    /// public config unless given; tribes found in the history are looked up
    /// only on that host.
    public static func restore(
        _ profile: Profile, mnemonic: String, alias: String, pin: String, network: String = "bitcoin",
        server: ServerAddress? = nil, tribeHost: String? = nil, memesHost: String? = nil
    ) async throws -> Engine {
        if profile.requiresPIN { try PIN.validate(pin) }
        let words = try Engine.validate(mnemonic: mnemonic)
        let address: ServerAddress
        var tribeHost = tribeHost
        if let server {
            address = server
        } else {
            let config = try await ServerConfig.fetch(network: network)
            address = try ServerAddress.named(config.defaultLSP)
            tribeHost = tribeHost ?? config.usableTribeHost
        }
        return try await open(
            profile, mnemonic: words, pin: pin, alias: alias, network: network, server: address, tribeHost: tribeHost,
            memesHost: memesHost, needsRestore: true
        )
    }

    /// Sets the account up and saves the words last, so a failure part-way
    /// leaves nothing that would block trying again.
    private static func open(
        _ profile: Profile, mnemonic: String, pin: String, alias: String, network: String, server: ServerAddress,
        tribeHost: String?, memesHost: String?, needsRestore: Bool = false
    ) async throws -> Engine {
        let storage = try Storage(directory: profile.directory)
        try storage.set(network, for: .network)
        if needsRestore { try storage.set("1", for: .needsRestore) }
        let engine = try Engine(mnemonic: mnemonic, storage: storage)
        try await engine.setAlias(alias)
        try await engine.setServer(server)
        if let tribeHost { try await engine.setTribeHost(tribeHost) }
        if let memesHost { try await engine.setMemesHost(memesHost) }
        try profile.secrets.save(mnemonic: mnemonic, pin: pin)
        // Made here, so its preferences file may start here (phase 11,
        // decision 8); written last, so a signup that failed part-way and is
        // then restored into the same profile never keeps it.
        try storage.setPreference(.mayStartPreferences, !needsRestore)
        return engine
    }
}
