import Foundation
import Observation
import PeelCore

/// The strut boxes this account is linked to (strut's
/// plans/people-and-hosts.md §2.1; `BoxLink`), one model for the Mac and the
/// iPhone alike (`AppModel.boxes`): a box's `peel://strut/link` waits for
/// the person's yes ("Link Peel to <host> as <name>?"), is signed with the
/// account's key and kept beside Stadeum's pairing (`Profile.boxes`), its
/// token renewed by signing again about daily while the account is open.
/// A box whose member removed the link (`403 not_linked`) is let go and
/// said once. Opening one shows its own strut UI as the member, where its
/// apps are listed and opened (`home(of:)`). A box's own Jamie answers in
/// the tribes the person adds there (`places`, `addJamie`, `removeJamie`;
/// docs/hive-tribes.md, "From a box"). A token the box no longer takes is
/// renewed once before any of these gives up (`asMember`).
@MainActor @Observable
public final class Boxes {
    /// The boxes linked, in the order they were linked.
    public private(set) var links: [BoxLink] = []
    /// A box's link waiting for the person's yes (`take`).
    public private(set) var asking: BoxLinkOffer?
    /// The link being signed and posted, after the person's yes (`accept`).
    public private(set) var linking: BoxLinkOffer?
    /// The last thing that went wrong, in words; nil once something works.
    public var problem: String?
    /// A box let go because its member removed the link there: said once.
    public var notice: String?
    /// What each box last said of Jamie for this person (`readPlaces`), by
    /// its address: absent until read. Never kept on disk.
    public private(set) var places: [URL: BoxPlaces] = [:]
    /// Why the last read of a box's places failed, in words, by its address;
    /// gone once one works.
    public private(set) var placesProblems: [URL: String] = [:]
    @ObservationIgnored private var placesReadAt: [URL: Date] = [:]
    @ObservationIgnored private var placesReading: [URL: Task<Void, Never>] = [:]
    /// Counts this device's adds and removes on each box: a read begun
    /// before one does not overwrite it (`readPlaces`).
    @ObservationIgnored private var placesChanges: [URL: Int] = [:]
    /// The tribes added on each box from this device this session, with the
    /// Jamie key the box answered then (`addJamie`): the only box Jamies
    /// Peel approves unasked (`jamiesAdded`).
    @ObservationIgnored private var added: [URL: [String: String]] = [:]
    /// The renewal under way for each box (`renewOnce`).
    @ObservationIgnored private var renewals: [URL: Task<BoxLink?, any Error>] = [:]
    /// Signs a box's challenge with the open account's key
    /// (`Engine.signBoxLink`); nil while no account is open.
    @ObservationIgnored public var sign: (@Sendable (BoxChallenge) async throws -> VisitorSignature)?
    /// The open account's own name (its alias), sent with a link.
    @ObservationIgnored public var accountName: (@MainActor () -> String?)?

    @ObservationIgnored private var profile: Profile?
    /// What the account kept could not be read: nothing is written over it
    /// (a new link would replace every box kept) until it is read again.
    @ObservationIgnored private var unreadable = false
    @ObservationIgnored private var renewing: Task<Void, Never>?
    /// Counts closes: what was begun before the last one keeps and says nothing.
    @ObservationIgnored private var generation = 0

    public init() {}

    /// Whether an account is open (`open`): linking needs one.
    public var isOpen: Bool { profile != nil }

    /// The account opened: what it kept, renewed whenever due while it stays open.
    public func open(_ profile: Profile) {
        // Why a link opened before the account did was refused, still said.
        let said = self.profile == nil ? problem : nil
        close()
        self.profile = profile
        problem = said
        do {
            links = try BoxLink.read(from: profile.boxes)
        } catch {
            unreadable = true
            problem = PeelError.noted(error, couldNot: String(localized: "read your linked boxes", table: "Shared"))
        }
        keepRenewed()
    }

    /// The account closed: its boxes let go here, read again when it opens.
    /// A link waiting for a yes stays: one opened while Peel was locked waits for it.
    public func close() {
        generation += 1
        renewing?.cancel()
        renewing = nil
        profile = nil
        unreadable = false
        links = []
        renewals = [:]
        forgetPlaces(of: nil)
        linking = nil
        problem = nil
        notice = nil
    }

    // MARK: - Linking

    /// A box's `peel://strut/link?…`: it waits for the person's yes, unless
    /// Peel will not sign it (`BoxLinkOffer.problem`), which is said instead.
    public func take(_ offer: BoxLinkOffer) {
        problem = nil
        notice = nil
        // With no account open yet, whether this machine's address may be linked is asked again at the yes.
        if let refusal = offer.problem(allowsLoopback: profile.map { $0.kind == .development } ?? true) {
            asking = nil
            problem = refusal
            return
        }
        asking = offer
    }

    /// No to the waiting link: nothing is signed.
    public func decline() {
        asking = nil
    }

    /// Yes to the waiting link, taken at once (`asking` is nil from here):
    /// signed with the account's key and posted to the box, and the link it
    /// answers kept. A challenge is good once, so a refused one is not
    /// offered again: the box's Connect makes another. The work, for a
    /// caller that waits for it; nil when there was nothing to link.
    @discardableResult
    public func accept() -> Task<Void, Never>? {
        guard let offer = asking else { return nil }
        asking = nil
        if let busy = linking {
            problem = String(localized: "Peel is still linking to \(busy.host). Open the link from \(offer.host) again once it's done.", table: "Shared")
            return nil
        }
        guard let profile, let sign else {
            problem = String(localized: "Unlock Peel to link it to \(offer.host).", table: "Shared")
            return nil
        }
        guard !unreadable else {
            problem = String(localized: "Peel couldn't read the boxes it keeps, so it won't change them now. Quit and reopen Peel, then link again.", table: "Shared")
            return nil
        }
        if let refusal = offer.problem(allowsLoopback: profile.kind == .development) {
            problem = refusal
            return nil
        }
        let generation = generation
        linking = offer
        problem = nil
        notice = nil
        let name = accountName?()
        return Task {
            defer { if generation == self.generation { linking = nil } }
            do {
                let signed = try await sign(offer.challenge)
                let link = try await BoxClient(box: offer.box).link(offer.challenge, signed: signed, name: name)
                guard generation == self.generation else { return }
                try keep(link)
            } catch {
                guard generation == self.generation else { return }
                problem = PeelError.noted(error, couldNot: String(localized: "link Peel to \(offer.host)", table: "Shared"))
            }
        }
    }

    /// Forget: the box's link and token gone from this device. The box keeps
    /// the link until its member removes it in Connect there.
    public func forget(_ box: BoxLink) {
        guard let profile else { return }
        let kept = links.filter { $0.url != box.url }
        do {
            try BoxLink.write(kept, to: profile.boxes)
            links = kept
            forgetPlaces(of: box.url)
            problem = nil
        } catch {
            problem = PeelError.noted(error, couldNot: String(localized: "forget \(box.host)", table: "Shared"))
        }
    }

    // MARK: - Opening

    /// The box's own strut UI as its member, to open (`BoxLink.home`): its
    /// token checked first (`asMember`). Throws why it does not open.
    public func home(of box: BoxLink) async throws -> OrgPageRequest {
        try await asMember(box) { link in
            guard try await BoxClient(box: link.url).accepts(link) else { throw BoxClient.TokenRefused() }
            return link.home
        }
    }

    /// `call` as `box`'s member with the token kept. One the box no longer
    /// takes (a 401, `BoxClient.TokenRefused`) is renewed once and `call`
    /// made again; a box that no longer links the key is let go (`notice`),
    /// as is one that refuses even a renewed token.
    private func asMember<T>(_ box: BoxLink, _ call: (BoxLink) async throws -> T) async throws -> T {
        guard let kept = links.first(where: { $0.url == box.url }) else {
            throw PeelError(String(localized: "Peel is no longer linked to \(box.host).", table: "Shared"))
        }
        do { return try await call(kept) } catch is BoxClient.TokenRefused {}
        guard let renewed = try await renewOnce(kept) else { throw PeelError(Self.unlinked(kept)) }
        do {
            return try await call(renewed)
        } catch is BoxClient.TokenRefused {
            drop(renewed)
            throw PeelError(Self.unlinked(renewed))
        }
    }

    /// `home(of:)`, or nil with why it does not open in `problem` (or `notice`, a box let go).
    public func page(of box: BoxLink) async -> OrgPageRequest? {
        let generation = generation
        do {
            let page = try await home(of: box)
            // Closed meanwhile: its token is not handed on.
            return generation == self.generation ? page : nil
        } catch {
            guard generation == self.generation, !(error is CancellationError) else { return nil }
            if links.contains(where: { $0.url == box.url }) { problem = PeelError.noted(error, couldNot: String(localized: "open \(box.host)", table: "Shared")) }
            return nil
        }
    }

    /// Whether `page` is a box's this account is linked to: it stays open
    /// while the box does.
    public func shows(_ page: OrgPageRequest) -> Bool {
        links.contains { $0.home.peer == page.peer }
    }

    // MARK: - Jamie in tribes

    /// Reads every box's places (`BoxClient.places`, docs/hive-tribes.md,
    /// "From a box"), each unless read in the last `age` seconds; one read
    /// per box at a time, joined, the boxes side by side. A read that fails
    /// keeps what was read before and says why (`placesProblems`).
    public func readPlaces(ifOlderThan age: TimeInterval = 0) async {
        let reads = links.map { readPlaces(of: $0, ifOlderThan: age) }
        for read in reads { await read.value }
    }

    private func readPlaces(of box: BoxLink, ifOlderThan age: TimeInterval) -> Task<Void, Never> {
        if places[box.url] != nil, let at = placesReadAt[box.url], Date().timeIntervalSince(at) < age { return Task {} }
        if let reading = placesReading[box.url] { return reading }
        let generation = generation
        let changes = placesChanges[box.url]
        let reading = Task {
            defer { if generation == self.generation { placesReading[box.url] = nil } }
            do {
                let read = try await asMember(box) { try await BoxClient(box: $0.url).places($0) }
                // Closed, or the box forgotten, meanwhile: nothing of it is kept.
                guard generation == self.generation, links.contains(where: { $0.url == box.url }) else { return }
                placesProblems[box.url] = nil
                // Added or removed here while it was asked: older than what is kept, so the next read asks again.
                guard changes == placesChanges[box.url] else { return }
                places[box.url] = read
                placesReadAt[box.url] = Date()
            } catch {
                guard generation == self.generation, links.contains(where: { $0.url == box.url }), !(error is CancellationError) else { return }
                placesProblems[box.url] = PeelError.noted(error, couldNot: String(localized: "read which tribes have Jamie on \(box.host)", table: "Shared"))
            }
        }
        placesReading[box.url] = reading
        return reading
    }

    /// Adds `tribe` on `box` (`BoxClient.addPlace`): the box's Jamie joins
    /// it and answers `@jamie` there, as this person. Answers that Jamie's
    /// key. A throw is the box's refusal in words, and changes nothing.
    public func addJamie(to tribe: Tribe, from box: BoxLink) async throws -> String {
        guard let link = tribe.link else {
            throw PeelError(String(localized: "This tribe's server isn't known here, so Jamie can't join it.", table: "Shared"))
        }
        let generation = generation
        let jamie = try await asMember(box) {
            try await BoxClient(box: $0.url).addPlace($0, tribe: tribe.pubkey, link: link, name: tribe.name)
        }
        guard generation == self.generation, links.contains(where: { $0.url == box.url }) else { return jamie }
        var said = places[box.url] ?? BoxPlaces(jamie: jamie, tribes: [])
        said.jamie = jamie
        said.tribes.insert(tribe.pubkey.lowercased())
        places[box.url] = said
        added[box.url, default: [:]][tribe.pubkey.lowercased()] = jamie
        placesChanges[box.url, default: 0] += 1
        placesProblems[box.url] = nil
        return jamie
    }

    /// Removes `tribe` (its key) from this person's places on `box`: its
    /// Jamie leaves. Answers that Jamie's key when the tribe was theirs
    /// there: the member whose mark goes with it. A throw changes nothing.
    @discardableResult
    public func removeJamie(from tribe: String, on box: BoxLink) async throws -> String? {
        let key = tribe.lowercased()
        let jamie = places[box.url].flatMap { $0.tribes.contains(key) ? $0.jamie : nil }
        let generation = generation
        try await asMember(box) { try await BoxClient(box: $0.url).removePlace($0, tribe: key) }
        guard generation == self.generation else { return nil }
        places[box.url]?.tribes.remove(key)
        added[box.url]?[key] = nil
        placesChanges[box.url, default: 0] += 1
        placesProblems[box.url] = nil
        return jamie
    }

    /// The Jamie keys of the boxes `tribe` was added on from this device
    /// this session, while it is still there. A box's own list is its
    /// database, and one Peel is merely linked to could name any tribe and
    /// any key in it: so a box's Jamie is approved unasked only where the
    /// person just added it here, and its request otherwise waits in
    /// Members (docs/hive-tribes.md, "From a box").
    public func jamiesAdded(in tribe: String) -> [String] {
        let key = tribe.lowercased()
        return links.compactMap { box in
            guard places[box.url]?.tribes.contains(key) != false else { return nil }
            return added[box.url]?[key]
        }
    }

    /// What `box`'s places said, and their reads, let go; every box's with nil.
    private func forgetPlaces(of box: URL?) {
        let gone = box.map { [$0] } ?? Array(Set(places.keys).union(placesProblems.keys).union(placesReading.keys).union(added.keys))
        for box in gone {
            placesReading[box]?.cancel()
            places[box] = nil
            placesProblems[box] = nil
            placesReadAt[box] = nil
            placesReading[box] = nil
            placesChanges[box] = nil
            added[box] = nil
        }
    }

    // MARK: - Renewing

    /// Renews each box when due, looking every hour while the account is open.
    private func keepRenewed() {
        renewing?.cancel()
        let generation = generation
        renewing = Task {
            while !Task.isCancelled, generation == self.generation {
                await renewDue()
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    /// Renews every box that is due (`BoxLink.due`). A failure is said and
    /// tried again within the hour: the token lasts a week, and the key,
    /// which renews it, lasts.
    func renewDue(at now: Date = Date()) async {
        let generation = generation
        for box in links where box.due(at: now) {
            do {
                try await renew(box, at: now)
            } catch {
                guard generation == self.generation else { return }
                // Forgotten meanwhile: the others are still renewed.
                if error is CancellationError { continue }
                problem = PeelError.noted(error, couldNot: String(localized: "renew Peel's link to \(box.host)", table: "Shared"))
            }
        }
    }

    /// A new token for `box`, kept; nil when the box no longer links the
    /// key (`403 not_linked`): it is let go and `notice` says so. Throws
    /// `CancellationError` when the account closed or the box was forgotten meanwhile.
    @discardableResult
    func renew(_ box: BoxLink, at now: Date = Date()) async throws -> BoxLink? {
        guard let sign else { throw PeelError(String(localized: "Peel's account is not open.", table: "Shared")) }
        let generation = generation
        let renewal = try await BoxClient(box: box.url).renew(box, now: now, sign: sign)
        guard generation == self.generation, links.contains(where: { $0.url == box.url }) else { throw CancellationError() }
        switch renewal {
        case .renewed(let renewed):
            try keep(renewed)
            return renewed
        case .unlinked:
            drop(box)
            return nil
        }
    }

    /// `renew`, joined while one for the box is under way, and none when the
    /// box's token kept is no longer `box`'s (renewed meanwhile): calls that
    /// meet a refused token at once sign once.
    private func renewOnce(_ box: BoxLink) async throws -> BoxLink? {
        if let current = links.first(where: { $0.url == box.url }), current.token != box.token { return current }
        if let renewal = renewals[box.url] { return try await renewal.value }
        let renewal = Task { try await renew(box) }
        renewals[box.url] = renewal
        defer { if renewals[box.url] == renewal { renewals[box.url] = nil } }
        return try await renewal.value
    }

    /// Keeps `link` (the Keychain first), in place of the box's earlier one.
    private func keep(_ link: BoxLink) throws {
        guard let profile, !unreadable else { return }
        var kept = links
        if let at = kept.firstIndex(where: { $0.url == link.url }) { kept[at] = link } else { kept.append(link) }
        try BoxLink.write(kept, to: profile.boxes)
        links = kept
        problem = nil
    }

    /// Lets `box` go: its member removed the link there.
    private func drop(_ box: BoxLink) {
        guard let profile else { return }
        let kept = links.filter { $0.url != box.url }
        try? BoxLink.write(kept, to: profile.boxes)
        links = kept
        forgetPlaces(of: box.url)
        notice = Self.unlinked(box)
    }

    /// What is said of a box that no longer links the key.
    static func unlinked(_ box: BoxLink) -> String {
        String(localized: "\(box.host) removed Peel's link, so Peel let it go. Link it again from Connect there.", table: "Shared")
    }
}

extension BoxLink {
    /// The box's own strut UI as its member (`OrgPageRequest`): its token as
    /// the first request's bearer and in the page's storage, never in an
    /// address. strut's UI lists the box's apps and opens them in place.
    public var home: OrgPageRequest {
        let folder = URL(string: url.absoluteString + "/") ?? url
        return OrgPageRequest(url: folder, token: token, peer: "box:" + url.absoluteString, workspace: host, title: host)
    }
}

/// A box's link in words, the same on the Mac and the iPhone.
public enum BoxWords {
    /// The question: "Link Peel to <host> as <name>?".
    public static func title(_ offer: BoxLinkOffer) -> String {
        String(localized: "Link Peel to \(offer.host) as \(offer.challenge.person ?? "you")?", table: "Shared")
    }

    /// Under it: what the yes does.
    public static func question(_ offer: BoxLinkOffer) -> String {
        let who = offer.challenge.person ?? String(localized: "you", table: "Shared")
        return String(localized: "\(offer.host) will know your Sphinx account as \(who): your @jamie in its tribes runs as \(who), and Peel opens its apps as \(who). Link only if you just asked for this there.", table: "Shared")
    }

    /// Where a box is linked from, for the rows.
    public static var howToLink: String { String(localized: "To link Peel to a box, choose Link Peel in Connect in its Jamie app.", table: "Shared") }
}
