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
/// apps are listed and opened (`home(of:)`).
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
            problem = nil
        } catch {
            problem = PeelError.noted(error, couldNot: String(localized: "forget \(box.host)", table: "Shared"))
        }
    }

    // MARK: - Opening

    /// The box's own strut UI as its member, to open (`BoxLink.home`): its
    /// token checked first. One the box no longer takes (a 401) is renewed
    /// once; a box that no longer links the key is let go (`notice`), as is
    /// one that refuses even a renewed token. Throws why it does not open.
    public func home(of box: BoxLink) async throws -> OrgPageRequest {
        guard let kept = links.first(where: { $0.url == box.url }) else {
            throw PeelError(String(localized: "Peel is no longer linked to \(box.host).", table: "Shared"))
        }
        if try await BoxClient(box: kept.url).accepts(kept) { return kept.home }
        guard let renewed = try await renew(kept) else { throw PeelError(Self.unlinked(kept)) }
        guard try await BoxClient(box: renewed.url).accepts(renewed) else {
            drop(renewed)
            throw PeelError(Self.unlinked(renewed))
        }
        return renewed.home
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
