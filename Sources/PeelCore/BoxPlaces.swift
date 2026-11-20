import Foundation

// Jamie from a box (docs/hive-tribes.md, "From a box"; strut's
// plans/jamie-in-tribes.md §4 and §5.4, specs/API.md §13.4 and §13.6,
// "Places"): a box whose strut has a Sphinx host ready (the box's Sphinx
// daemon) answers `@jamie` in each tribe its people add there as a PLACE.
// Peel adds and removes the person's places with the person token it holds
// for the box (`BoxLink`), as it links a tribe to a Stadeum org through Hive.

/// What a box says of Jamie for this person (`GET /people/places`).
public struct BoxPlaces: Sendable, Equatable {
    /// The host Peel adds places for: the box's Sphinx daemon.
    public static let host = "sphinx"

    /// The box's Jamie: the Sphinx key its host answers as, lower case. Nil
    /// when the box has no Sphinx host ready, or is a strut from before places.
    public var jamie: String?
    /// The tribes this person added there, by key, lower case.
    public var tribes: Set<String>

    public init(jamie: String?, tribes: Set<String>) {
        self.jamie = jamie
        self.tribes = tribes
    }

    /// A Sphinx account as strut spells one, `sphinx:<66 hex>` (or the bare
    /// key), as Peel holds a key: lower case. Nil for anything else.
    static func key(of account: String?) -> String? {
        guard var key = account else { return nil }
        if key.hasPrefix(Self.host + ":") { key.removeFirst(Self.host.count + 1) }
        return key.isPubkey ? key.lowercased() : nil
    }
}

extension BoxClient {
    /// The box no longer takes the token (401): the caller renews it once
    /// and asks again (`Boxes`), never says it as such.
    public struct TokenRefused: Error {
        public init() {}
    }

    /// What the box says of Jamie for `link`'s person: its Sphinx host's
    /// account, when one is ready, and the tribes they added. A strut from
    /// before places (404) has no Jamie to offer.
    public func places(_ link: BoxLink) async throws -> BoxPlaces {
        let (status, data) = try await asPerson("GET", "people/places", link, nil)
        if status == 404 { return BoxPlaces(jamie: nil, tribes: []) }
        guard status == 200 else { throw placesFailure(status, data) }
        guard case .object(let answer)? = JSON.decode(JSONValue.self, from: String(decoding: data, as: UTF8.self)),
              case .array(let hosts)? = answer["hosts"], case .array(let places)? = answer["places"] else {
            throw PeelError(String(localized: "\(host)'s answer about Jamie could not be read.", table: "Shared"))
        }
        let jamie = hosts.lazy.compactMap { host -> String? in
            guard case .object(let host) = host, host["host"]?.string == BoxPlaces.host else { return nil }
            return BoxPlaces.key(of: host["account"]?.string)
        }.first
        // A place Peel could not use (another host's, a key that is not a tribe's) is left out.
        let tribes = places.compactMap { place -> String? in
            guard case .object(let place) = place, place["host"]?.string == BoxPlaces.host,
                  let key = place["key"]?.string, key.isPubkey else { return nil }
            return key.lowercased()
        }
        return BoxPlaces(jamie: jamie, tribes: Set(tribes))
    }

    /// Adds `tribe` (its key) as a place for the box's Sphinx host
    /// (`POST /people/places`), with its `link` to join by and its `name`:
    /// the box's Jamie joins it and answers `@jamie` there, as `link`'s
    /// person. Answers that Jamie's key, which a private tribe's owner
    /// approves. Another person's place, or a box with no Sphinx host
    /// ready, is refused in words.
    public func addPlace(_ person: BoxLink, tribe: String, link: String, name: String?) async throws -> String {
        guard tribe.isPubkey else { throw PeelError(String(localized: "That isn't a tribe's key.", table: "Shared")) }
        var body = ["host": BoxPlaces.host, "key": tribe.lowercased(), "link": link]
        // One line of at most 80 characters, as strut keeps a name.
        if let name = name.map({ TextLine.clean($0, max: 80).trimmingCharacters(in: .whitespaces) })?.nilIfEmpty {
            body["name"] = name
        }
        let (status, data) = try await asPerson("POST", "people/places", person, try JSONEncoder.hive.encode(body))
        guard status == 200 else { throw placesFailure(status, data) }
        guard case .object(let answer)? = JSON.decode(JSONValue.self, from: String(decoding: data, as: UTF8.self)),
              let jamie = BoxPlaces.key(of: answer["account"]?.string),
              case .object(let place)? = answer["place"], place["host"]?.string == BoxPlaces.host,
              place["key"]?.string?.lowercased() == tribe.lowercased() else {
            throw PeelError(String(localized: "\(host)'s answer about Jamie could not be read.", table: "Shared"))
        }
        return jamie
    }

    /// Removes `tribe` from `person`'s places (`DELETE
    /// /people/places/sphinx/<key>`): the box's Jamie leaves it. One that
    /// was not theirs, or is gone already, is removed as far as they go.
    public func removePlace(_ person: BoxLink, tribe: String) async throws {
        guard tribe.isPubkey else { throw PeelError(String(localized: "That isn't a tribe's key.", table: "Shared")) }
        let (status, data) = try await asPerson("DELETE", "people/places/\(BoxPlaces.host)/\(tribe.lowercased())", person, nil)
        guard status == 200 else { throw placesFailure(status, data) }
    }

    /// One request as `person`, their token the bearer; a 401 is `TokenRefused`.
    private func asPerson(_ method: String, _ path: String, _ person: BoxLink, _ body: Data?) async throws -> (Int, Data) {
        let (status, data) = try await Web.requestStrut(method, box.appending(path: path), json: body, bearer: person.token,
                                                        limit: Self.limit, what: host, timeout: 30)
        if status == 401 { throw TokenRefused() }
        return (status, data)
    }

    /// strut's refusal of a place, in words: those a person can act on as
    /// such, the rest in strut's words.
    func placesFailure(_ status: Int, _ data: Data) -> PeelError {
        let said = Self.said(data)
        switch status {
        case 409 where said?.hasPrefix("place_linked:") == true:
            return PeelError(String(localized: "Someone else on \(host) already added Jamie to this tribe.", table: "Shared"))
        case 404 where said?.hasPrefix("no_host:") == true:
            return PeelError(String(localized: "\(host) isn't ready for tribes yet.", table: "Shared"))
        case 429:
            return busy
        default:
            return PeelError("\(host) said: \(said ?? "HTTP \(status)").")
        }
    }
}

/// Where a tribe's Jamie answers from, as its row names it: none, one of
/// the person's Stadeum orgs (Hive's Jamie), or one of the boxes Peel is
/// linked to (that box's own Jamie). Its `id` is what the row's dropdown
/// holds: "", the org's peer id, or `box:<the box's address>`, which no
/// peer id can be (`AgentArtifact.Handle.isPeerID` has no colon).
public enum JamieSource: Hashable, Sendable {
    case noJamie
    /// A `HivePeer.id`.
    case org(String)
    /// A `BoxLink.url`, as its `absoluteString`.
    case box(String)

    static let boxPrefix = "box:"

    public init(id: String) {
        if id.isEmpty {
            self = .noJamie
        } else if id.hasPrefix(Self.boxPrefix) {
            self = .box(String(id.dropFirst(Self.boxPrefix.count)))
        } else {
            self = .org(id)
        }
    }

    public init(_ box: BoxLink) {
        self = .box(box.url.absoluteString)
    }

    public var isBox: Bool {
        if case .box = self { return true }
        return false
    }

    public var id: String {
        switch self {
        case .noJamie: ""
        case .org(let id): id
        case .box(let url): Self.boxPrefix + url
        }
    }
}

/// A tribe's Jamie row's choices (docs/hive-tribes.md): what each source
/// last said, put together. Its sources are Stadeum while it is in use
/// (`orgs`) and each box Peel is linked to. The pick is known once every
/// source has said; a tribe added on more than one is said as such.
public struct JamieChoices: Sendable {
    /// Stadeum's side: the person's orgs in use, and what Hive last said of
    /// their tribes (nil until it has).
    public struct Orgs: Sendable {
        public var live: [HivePeer]
        public var links: JamieLinks?

        public init(live: [HivePeer], links: JamieLinks?) {
            self.live = live
            self.links = links
        }
    }

    /// One choice in the row: its `JamieSource.id` and its name.
    public struct Option: Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// Nil while Stadeum is not a source (not paired, or not in use).
    public var orgs: Orgs?
    /// The boxes Peel is linked to.
    public var boxes: [BoxLink]
    /// What each box last said, by its address; none until it has.
    public var places: [URL: BoxPlaces]
    /// The boxes whose read failed with nothing read before: left out, so
    /// one that is down does not hold up the rest (the row says why).
    public var failed: Set<URL>

    public init(orgs: Orgs?, boxes: [BoxLink] = [], places: [URL: BoxPlaces] = [:], failed: Set<URL> = []) {
        self.orgs = orgs
        self.boxes = boxes
        self.places = places
        self.failed = failed
    }

    public static let noJamie = String(localized: "No Jamie", table: "Shared")

    /// Whether the row has anywhere to offer Jamie from in `tribe`: Stadeum,
    /// or a box that has a Jamie ready, has Jamie there, or has not said yet.
    public func offers(in tribe: String) -> Bool {
        orgs != nil || offersBoxes(in: tribe)
    }

    /// Whether a box offers Jamie in `tribe`, or may once it has said.
    public func offersBoxes(in tribe: String) -> Bool {
        boxes.contains { box in
            guard !failed.contains(box.url) else { return false }
            guard let said = places[box.url] else { return true }
            return said.jamie != nil || said.tribes.contains(tribe.lowercased())
        }
    }

    /// Every source that has Jamie in `tribe` (its key), orgs first; nil
    /// until each source has said (a box whose read failed is left out).
    public func linked(_ tribe: String) -> [JamieSource]? {
        let key = tribe.lowercased()
        var linked: [JamieSource] = []
        if let orgs {
            guard let links = orgs.links else { return nil }
            if let link = links.tribes.first(where: { $0.pubkey == key }) { linked.append(.org(link.workspace)) }
        }
        for box in boxes where !failed.contains(box.url) {
            guard let said = places[box.url] else { return nil }
            if said.tribes.contains(key) { linked.append(JamieSource(box)) }
        }
        return linked
    }

    /// What the row shows picked: the first source that has Jamie in
    /// `tribe`, else none; nil until each source has said.
    public func pick(of tribe: String) -> JamieSource? {
        linked(tribe).map { $0.first ?? .noJamie }
    }

    /// What putting Jamie in `tribe` from `source` takes (`.noJamie` to
    /// take it out): the source to add, when it has not got Jamie there
    /// yet, then every other one that has to remove. Added first, so a
    /// refusal leaves the old one answering. Hive keeps one org per tribe,
    /// so an org put in place of another replaces it, and is no removal.
    /// Nil until each source has said; nothing to add or remove when
    /// `source` is already all there is.
    public func plan(_ source: JamieSource, in tribe: String) -> (add: JamieSource?, remove: [JamieSource])? {
        guard let linked = linked(tribe) else { return nil }
        let add = source == .noJamie || linked.contains(source) ? nil : source
        let remove = linked.filter { old in
            if case .org = old, case .org = source { return false }
            return old != source
        }
        return (add, remove)
    }

    /// What the row offers: each org in use by name, the one `tribe` is
    /// linked to even when it is no longer in use (so the row says what is
    /// true), each box with a Jamie ready (or that has it in `tribe`) by its
    /// host, then No Jamie.
    public func options(for tribe: String) -> [Option] {
        let key = tribe.lowercased()
        var options = orgs?.live.map { Option(id: $0.id, name: $0.name) } ?? []
        if let linked = orgs?.links?.tribes.first(where: { $0.pubkey == key })?.workspace,
           !options.contains(where: { $0.id == linked }) {
            options.append(Option(id: linked, name: "@" + linked))
        }
        for box in boxes {
            guard let said = places[box.url], said.jamie != nil || said.tribes.contains(key) else { continue }
            options.append(Option(id: JamieSource(box).id, name: name(of: box)))
        }
        return options + [Option(id: "", name: Self.noJamie)]
    }

    /// A source as the person reads it: an org's name (`@id` when no longer
    /// in use), a box's (`name(of:)`).
    public func name(of source: JamieSource) -> String {
        switch source {
        case .noJamie: Self.noJamie
        case .org(let id): orgs?.live.first { $0.id == id }?.name ?? "@" + id
        case .box(let url): box(url).map(name(of:)) ?? url
        }
    }

    /// A box as the row names it: its host, and its path when another box
    /// linked here is on the same host.
    func name(of box: BoxLink) -> String {
        let shared = boxes.contains { $0.url != box.url && $0.host == box.host }
        let path = box.url.path
        return shared && !path.isEmpty && path != "/" ? box.host + path : box.host
    }

    /// The Sphinx key of the Jamie `source` brings: Hive's one account for
    /// every org, or the box's own. Nil when it has not said.
    public func jamie(of source: JamieSource) -> String? {
        switch source {
        case .noJamie: nil
        case .org: orgs?.links?.jamie.pubkey
        case .box(let url): box(url).flatMap { places[$0.url]?.jamie }
        }
    }

    /// The box `url` names, while Peel is linked to it.
    public func box(_ url: String) -> BoxLink? {
        boxes.first { $0.url.absoluteString == url }
    }

    /// What the row offers in one tap while `tribe` has no Jamie: the org
    /// its app or second brain is on, as a call there chooses
    /// (`HivePeer.jamie`); else a box with a Jamie ready at the host one of
    /// them is on. Nil once it has one, before every source has said, or
    /// with no such org or box.
    public func suggestion(for tribe: Tribe) -> Option? {
        guard pick(of: tribe.pubkey) == .noJamie else { return nil }
        let pages = [tribe.appURL, tribe.secondBrainURL]
        if let orgs, let org = HivePeer.jamie(picked: nil, pages: pages, in: orgs.live) {
            return Option(id: org.id, name: org.name)
        }
        let hosts = pages.compactMap { $0.flatMap(URL.init(string:)).flatMap(Seller.host(of:)) }
        guard let box = boxes.first(where: { hosts.contains($0.host) && places[$0.url]?.jamie != nil }) else { return nil }
        return Option(id: JamieSource(box).id, name: name(of: box))
    }
}
