import Foundation
import Sphinxrs

/// The preferences sync's bookkeeping for one engine.
struct PreferencesWork {
    /// The sync running or last run; the next waits for it, so one runs at a time.
    var current: Task<Engine.PreferencesSync, any Error>?
    /// A sync waiting to start (after a change, debounced).
    var scheduled: Task<Void, Never>?
    /// When a sync last fetched the file (or its "not found"): coming to the
    /// front within a minute of that does not sync again. A sync that could
    /// not fetch does not count, so the next return to the front tries.
    var lastFetched: ContinuousClock.Instant?
    /// The last background failure reported, so the same one is said once,
    /// not on every try; cleared by a sync that works.
    var reported: String?
}

extension Engine {
    /// What one sync did.
    public struct PreferencesSync: Sendable, Equatable {
        /// Preferences taken from the file and applied here.
        public let applied: Int
        /// Whether the file was written (only when something here was newer).
        public let uploaded: Bool
    }

    /// The wait after a change before syncing, so a run of changes goes up
    /// once (the official apps wait 2 s).
    static let preferencesDebounce: Duration = .seconds(2)
    /// How often coming to the front syncs at most.
    static let preferencesRefresh: Duration = .seconds(60)

    /// Every change to a user setting goes through here, to the one owner
    /// of them (`Preferences.swift`); one that follows the account is synced
    /// shortly after. Returns false if it was already so.
    @discardableResult
    func set<Value>(_ preference: Preference<Value>, _ value: Value, for identifier: String = Preferences.accountWide) throws -> Bool {
        let changed = try storage.setPreference(preference, value, for: identifier)
        if changed, preference.scope == .account { schedulePreferencesSync(after: Self.preferencesDebounce) }
        return changed
    }

    /// Syncs soon unless one fetched within `preferencesRefresh`: for an
    /// app coming to the front, as the official apps sync on becoming active.
    public func refreshPreferences() {
        if let last = preferencesWork.lastFetched, ContinuousClock.now - last < Self.preferencesRefresh { return }
        schedulePreferencesSync(after: .zero)
    }

    /// A sync after `delay`, replacing one already waiting. Every sync
    /// retries what failed before, so a failure is reported once (as a core
    /// error), and again only once a sync has worked since. A server that
    /// cannot be reached or that this account has none of is not reported.
    func schedulePreferencesSync(after delay: Duration) {
        guard !closed else { return }
        preferencesWork.scheduled?.cancel()
        preferencesWork.scheduled = Self.background { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            do {
                _ = try await self.syncPreferences()
                await self.noteSync(failure: nil)
            } catch Failure.noMemesServer, is URLError, is CancellationError {
            } catch {
                // An account that may not start the file and has never seen
                // one is waiting for another device to start it: not a failure.
                if case Failure.preferencesMissing = error, await !self.hasSeenPreferencesFile() { return }
                await self.noteSync(failure: "syncing preferences: \(PeelError.readable(error))")
            }
        }
    }

    private func hasSeenPreferencesFile() -> Bool {
        (try? storage.preference(.preferencesFileSeen)) != nil
    }

    private func noteSync(failure: String?) {
        defer { preferencesWork.reported = failure }
        guard let failure, failure != preferencesWork.reported, !closed else { return }
        emit.yield(.coreError(failure))
    }

    /// Syncs this account's preferences with the official apps' encrypted
    /// file on the memes server (`docs/phases/11-preferences-sync.md`):
    /// fetch, decrypt with the node key, merge per item by date, apply what
    /// came from the file, and upload only if something here was newer. A
    /// file that cannot be fetched, decrypted or read as the official apps
    /// read it changes nothing and is not written. One at a time.
    @discardableResult
    public func syncPreferences() async throws -> PreferencesSync {
        let previous = preferencesWork.current
        let sync = Task { [weak self] () throws -> PreferencesSync in
            _ = try? await previous?.value
            guard let self else { throw CancellationError() }
            return try await self.runPreferencesSync()
        }
        preferencesWork.current = sync
        return try await sync.value
    }

    /// What a sync would do, changing nothing: the keys and identifiers it
    /// would apply here and upload (never their values), and whether the
    /// file was found (`prefs-sync --dry-run`). Waits for a sync running.
    public func previewPreferences() async throws -> PreferencesPreview {
        _ = try? await preferencesWork.current?.value
        let (merge, found) = try await fetchAndMerge(memesServer(), secret: preferencesKey())
        // A new date alone (a refused value, `merged`) is not applying anything.
        let applied = merge.apply.filter { $0.row.value != $0.expected?.value }
        return PreferencesPreview(
            found: found, applied: applied.map { .init(key: $0.row.key, identifier: $0.row.identifier) }, uploaded: merge.uploads
        )
    }

    public struct PreferencesPreview: Sendable {
        /// False when the server said it has no file and this device has
        /// never seen one, so a sync would start it.
        public let found: Bool
        public let applied: [PreferenceID]
        public let uploaded: [PreferenceID]
    }

    /// Fetches, decrypts and reads the file, and merges it with what is
    /// stored. The memes server says "not found" for any storage error, so
    /// it starts an empty file (bootstrapping) only where `mayStartPreferencesFile`
    /// says; anywhere else it is the server failing.
    private func fetchAndMerge(_ memes: MemesServer, secret: String) async throws -> (PreferencesFile.Merge, found: Bool) {
        let rows = try storage.preferenceRows()
        guard let body = try await withMemes(memes, { try await memes.preferences(token: $0) }) else {
            guard try storage.mayStartPreferencesFile(on: memes.seenName) else { throw Failure.preferencesMissing }
            let since = try storage.preference(.preferencesSince).map(Double.init) ?? .greatestFiniteMagnitude
            return (PreferencesFile().merged(with: rows, bootstrapping: since), false)
        }
        guard let sealed = Data(base64Encoded: body.trimmingCharacters(in: .whitespacesAndNewlines)),
              let plain = try? MediaCrypto.decrypt(sealed, key: secret),
              let text = String(data: plain, encoding: .utf8) else { throw Failure.unreadablePreferences }
        return (try PreferencesFile(text: text).merged(with: rows), true)
    }

    private func runPreferencesSync() async throws -> PreferencesSync {
        let memes = try memesServer()
        let secret = try preferencesKey()
        let (merge, found) = try await fetchAndMerge(memes, secret: secret)
        // Closed while it was fetched: an account being forgotten is not written to.
        guard !closed else { throw CancellationError() }
        preferencesWork.lastFetched = .now
        if found { try set(.preferencesFileSeen, memes.seenName) }
        let applied = try storage.applyPreferences(merge.apply)
        if applied > 0 { emit.yield(.preferencesChanged) }
        guard merge.changed else { return PreferencesSync(applied: applied, uploaded: false) }
        let sealed = try MediaCrypto.encrypt(Data(try merge.file.text.utf8), key: secret).base64EncodedString()
        guard sealed.utf8.count <= MemesServer.preferencesLimit else { throw TooLarge(limit: MemesServer.preferencesLimit) }
        guard let key = Data(hex: try memesPubkey()) else { throw Failure.coreReturnedNothing("the account key") }
        let field = MediaToken.base64URLEncode(key).replacingOccurrences(of: "=", with: "")
        guard !closed else { throw CancellationError() }
        try await withMemes(memes) { try await memes.uploadPreferences(sealed, pubkey: field, token: $0) }
        if !found, !closed { try set(.preferencesFileSeen, memes.seenName) }
        return PreferencesSync(applied: applied, uploaded: true)
    }

    /// The official apps' password for the file (`getPersonalKeys`): the
    /// node secret key as 64 hex characters, always for "bitcoin" (the
    /// network changes nothing in it). Never stored or logged.
    func preferencesKey() throws -> String {
        try Sphinxrs.nodeKeys(net: "bitcoin", seed: seed).secret
    }
}

extension MemesServer {
    /// The server as `device.preferences_file_seen` records it: the host
    /// in lower case, so another spelling of the same one is not a new start.
    var seenName: String { host.lowercased() }
}

extension Storage {
    /// Whether a "not found" from the memes server `host` may start the
    /// account's file here: only on an account signed up or created by a
    /// build that has sync (`Preference.mayStartPreferences`), and only
    /// until a file has been seen on that server. An account restored here,
    /// or made before sync and perhaps restored elsewhere since, has a file
    /// somewhere, and a storage error must never replace it.
    func mayStartPreferencesFile(on host: String) throws -> Bool {
        try preference(.mayStartPreferences) == true && value(for: .needsRestore) == nil
            && preference(.preferencesFileSeen) != host
    }
}
