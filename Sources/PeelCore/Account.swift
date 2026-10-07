import Foundation

/// Opening, creating and restoring accounts: the one place that decides where
/// the mnemonic and the server come from. Connecting is left to the caller, so
/// an app can show a returning account while it is still offline.
public enum Account {
    /// Loads an existing account without connecting it.
    public static func load(_ profile: Profile, alias: String? = nil, server: ServerAddress? = nil) async throws -> Engine {
        let engine = try Engine(mnemonic: profile.loadMnemonic(), storage: Storage(directory: profile.directory))
        if let alias { try await engine.setAlias(alias) }
        if let server { try await engine.setServer(server) }
        return engine
    }

    /// Creates an account from an invite, connects, and adds the inviter as the
    /// first contact. On any failure short of a registration timeout the
    /// profile is removed again, since the invite was not used.
    public static func signup(
        _ profile: Profile, invite: Engine.Invite, alias: String, network: String = "bitcoin",
        server: ServerAddress? = nil, allowUntrustedCertificate: Bool = false
    ) async throws -> Engine {
        guard let address = server ?? invite.server.flatMap(ServerAddress.init) else {
            throw PeelError("the invite does not say which server to use")
        }
        let engine = try await create(profile, alias: alias, network: network, server: address)
        do {
            try await engine.connect(inviteCode: invite.code, allowUntrustedCertificate: allowUntrustedCertificate)
            if let inviter = invite.inviterContactInfo {
                try await engine.addContact(inviter, alias: invite.inviterAlias, inviteCode: invite.code)
            }
        } catch let failure as Engine.Failure where failure == .registrationTimedOut {
            throw failure
        } catch {
            try? profile.delete()
            throw error
        }
        return engine
    }

    /// Creates an account that needs no invite, for a local test server.
    public static func create(
        _ profile: Profile, alias: String, network: String = "bitcoin", server: ServerAddress
    ) async throws -> Engine {
        try profile.secrets.save(mnemonic: Engine.generateMnemonic())
        return try await open(profile, alias: alias, network: network, server: server)
    }

    /// Brings an account back from its twelve words. The server comes from the
    /// public config unless given. History is not pulled back yet.
    public static func restore(
        _ profile: Profile, mnemonic: String, alias: String, network: String = "bitcoin",
        server: ServerAddress? = nil
    ) async throws -> Engine {
        let words = try Engine.validate(mnemonic: mnemonic)
        let address: ServerAddress
        if let server {
            address = server
        } else {
            let config = try await ServerConfig.fetch(network: network)
            guard let parsed = ServerAddress(config.defaultLSP) else {
                throw PeelError("the server address in the config is unreadable")
            }
            address = parsed
        }
        try profile.secrets.save(mnemonic: words)
        return try await open(profile, alias: alias, network: network, server: address)
    }

    private static func open(_ profile: Profile, alias: String, network: String, server: ServerAddress) async throws -> Engine {
        let storage = try Storage(directory: profile.directory)
        try storage.set(network, for: .network)
        let engine = try Engine(mnemonic: profile.loadMnemonic(), storage: storage)
        try await engine.setAlias(alias)
        try await engine.setServer(server)
        return engine
    }
}
