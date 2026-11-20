import Foundation
import Testing
@testable import PeelCore
@testable import PeelTestSupport

/// Jamie from a box (docs/hive-tribes.md, "From a box"; strut's
/// specs/API.md §13.4 and §13.6, "Places"): strut's three place routes as
/// the person, on a stand-in, and a tribe's Jamie row put together from
/// Stadeum's orgs and the boxes (`JamieChoices`): what it offers, what it
/// shows picked, what a pick adds and removes, and its one-tap suggestion.
struct BoxPlacesTests {
    static let tribe = String(repeating: "ab", count: 33)
    static let boxJamie = String(repeating: "0c", count: 33)
    static let hiveJamie = String(repeating: "0d", count: 33)

    /// A stand-in strut answering `respond` under the mount path `/lab`, and the box kept for it.
    private static func box(_ respond: @escaping @Sendable (String) -> (Int, String)) async throws -> (HTTPStub, BoxLink) {
        let stub = try await HTTPStub(respond: { _, request in respond(request) })
        return (stub, BoxFixture.box("http://127.0.0.1:\(stub.port)/lab"))
    }

    // MARK: strut's routes, on a stand-in

    /// Reading asks as the person (their token the bearer, under the box's
    /// mount path) and takes the Sphinx host's account as the box's Jamie,
    /// lower case, and the person's sphinx places by tribe key; anything
    /// else in the list is left out. A strut from before places (404) has
    /// no Jamie; a token it no longer takes (401) is `TokenRefused`.
    @Test func readingPlacesTakesTheBoxsJamieAndThePersonsTribes() async throws {
        let answer = #"{"hosts":[{"host":"slack","account":"slack:T1"},{"host":"sphinx","account":"sphinx:\#(Self.boxJamie.uppercased())"}],"#
            + #""places":[{"host":"sphinx","key":"\#(Self.tribe.uppercased())","link":"l","account":"sphinx:02","at":1},"#
            + #"{"host":"slack","key":"\#(String(repeating: "cd", count: 33))","link":"l","account":"x","at":1},"#
            + #"{"host":"sphinx","key":"not a tribe","link":"l","account":"x","at":1}]}"#
        let (stub, box) = try await Self.box { request in
            if request.contains("Bearer strut-person.gone") { return (401, #"{"error":"unauthorized"}"#) }
            return request.hasPrefix("GET /lab/people/places ") ? (200, answer) : (404, #"{"error":"not found"}"#)
        }
        defer { stub.stop() }
        let places = try await BoxClient(box: box.url).places(box)
        #expect(places == BoxPlaces(jamie: Self.boxJamie, tribes: [Self.tribe]))
        #expect(try #require(stub.requests.first).contains("Authorization: Bearer \(box.token)"))

        let (older, olderBox) = try await Self.box { _ in (404, #"{"error":"not found"}"#) }
        defer { older.stop() }
        #expect(try await BoxClient(box: olderBox.url).places(olderBox) == BoxPlaces(jamie: nil, tribes: []))

        var gone = box
        gone.token = "strut-person.gone"
        await #expect(throws: BoxClient.TokenRefused.self) { _ = try await BoxClient(box: box.url).places(gone) }
    }

    /// Adding posts the sphinx host, the tribe's key in lower case, its link
    /// and its name as one line, and answers the box's Jamie; an answer
    /// about another tribe, or naming no Sphinx key, is not taken.
    @Test func addingAPlacePostsTheTribeAndAnswersTheBoxsJamie() async throws {
        let (stub, box) = try await Self.box { request in
            let key = HTTPStub.jsonBody(of: request)?["key"] ?? ""
            let account = key == Self.tribe ? "sphinx:\(Self.boxJamie)" : "sphinx:nope"
            return (200, #"{"place":{"host":"sphinx","key":"\#(key)","link":"l","account":"sphinx:02ab","at":1},"account":"\#(account)"}"#)
        }
        defer { stub.stop() }
        let jamie = try await BoxClient(box: box.url).addPlace(box, tribe: Self.tribe.uppercased(), link: "sphinx.chat://?action=tribeV2", name: "Build\ners")
        #expect(jamie == Self.boxJamie)
        let request = try #require(stub.requests.first)
        #expect(request.hasPrefix("POST /lab/people/places ") && request.contains("Authorization: Bearer \(box.token)"))
        #expect(HTTPStub.jsonBody(of: request) == ["host": "sphinx", "key": Self.tribe, "link": "sphinx.chat://?action=tribeV2", "name": "Build ers"])

        let error = await #expect(throws: PeelError.self) {
            _ = try await BoxClient(box: box.url).addPlace(box, tribe: String(repeating: "cd", count: 33), link: "l", name: nil)
        }
        #expect(error?.description.contains("could not be read") == true)
    }

    /// strut's refusals of a place, in words the person can act on: another
    /// person's link, a box with no Sphinx host ready, a busy box; the rest
    /// in strut's own words.
    @Test(arguments: [
        (409, #"{"error":"place_linked: sphinx:ab is linked by another person here — they remove it first"}"#, "Someone else on 127.0.0.1 already added Jamie"),
        (404, #"{"error":"no_host: no sphinx host is ready here"}"#, "127.0.0.1 isn't ready for tribes yet"),
        (429, #"{"error":"slow down"}"#, "busy"),
        (400, #"{"error":"name is one line of at most 80 characters"}"#, "127.0.0.1 said: name is one line"),
        (404, #"{"error":"not found"}"#, "127.0.0.1 said: not found"),
    ])
    func aRefusedPlaceIsSaidPlainly(status: Int, body: String, words: String) async throws {
        let (stub, box) = try await Self.box { _ in (status, body) }
        defer { stub.stop() }
        let error = await #expect(throws: PeelError.self) {
            _ = try await BoxClient(box: box.url).addPlace(box, tribe: Self.tribe, link: "l", name: nil)
        }
        #expect(error?.description.contains(words) == true, "\(error?.description ?? "")")
    }

    /// Removing deletes the person's place by the host and the tribe's key;
    /// one that was not theirs (`removed: false`) is gone as far as they go.
    @Test func removingAPlaceDeletesItByKey() async throws {
        let (stub, box) = try await Self.box { request in
            request.hasPrefix("DELETE /lab/people/places/sphinx/\(Self.tribe) ") ? (200, #"{"removed":false}"#) : (500, #"{"error":"boom"}"#)
        }
        defer { stub.stop() }
        try await BoxClient(box: box.url).removePlace(box, tribe: Self.tribe.uppercased())
        #expect(try #require(stub.requests.first).contains("Authorization: Bearer \(box.token)"))
        await #expect(throws: PeelError.self) { try await BoxClient(box: box.url).removePlace(box, tribe: String(repeating: "cd", count: 33)) }
    }

    // MARK: The row's choices

    private static let acme = HivePeer(id: "acme", baseUrl: "https://swarm38.sphinx.chat:3355/lab", token: "t", label: "Acme")
    private static let lab = BoxFixture.box("https://lab.example.com")
    private static let shop = BoxFixture.box("https://shop.example.com/jamie")

    /// Hive's answer with the tribe linked to `workspace`, or to none.
    private static func hive(_ workspace: String?) -> JamieChoices.Orgs {
        let tribes = workspace.map { [JamieLink(pubkey: tribe, host: "h", workspace: $0)] } ?? []
        return .init(live: [acme], links: JamieLinks(jamie: JamieAccount(pubkey: hiveJamie, alias: "Jamie"), tribes: tribes))
    }

    /// The pick waits for every source: Hive while Stadeum is in use, and
    /// each box, but one whose read failed. Then it is the one that has
    /// Jamie in the tribe (an org first, when two have), or none; a tribe
    /// in two is said as both.
    @Test func thePickWaitsForEverySourceThenSaysWhereJamieIs() throws {
        let ready = BoxPlaces(jamie: Self.boxJamie, tribes: [])
        let holding = BoxPlaces(jamie: Self.boxJamie, tribes: [Self.tribe])
        #expect(JamieChoices(orgs: .init(live: [Self.acme], links: nil)).pick(of: Self.tribe) == nil)
        #expect(JamieChoices(orgs: nil, boxes: [Self.lab, Self.shop], places: [Self.lab.url: ready]).pick(of: Self.tribe) == nil)
        #expect(JamieChoices(orgs: nil).pick(of: Self.tribe) == .noJamie)
        #expect(JamieChoices(orgs: Self.hive("acme")).pick(of: Self.tribe.uppercased()) == .org("acme"))

        let onShop = JamieChoices(orgs: Self.hive(nil), boxes: [Self.lab, Self.shop], places: [Self.lab.url: ready, Self.shop.url: holding])
        #expect(onShop.pick(of: Self.tribe) == JamieSource(Self.shop))
        #expect(onShop.jamie(of: JamieSource(Self.shop)) == Self.boxJamie && onShop.jamie(of: .org("acme")) == Self.hiveJamie)
        #expect(onShop.pick(of: String(repeating: "cd", count: 33)) == .noJamie)

        let both = JamieChoices(orgs: Self.hive("acme"), boxes: [Self.shop], places: [Self.shop.url: holding])
        #expect(both.linked(Self.tribe) == [.org("acme"), JamieSource(Self.shop)])

        // A box whose read failed holds up nothing: the orgs are offered, and the box is not.
        let down = JamieChoices(orgs: Self.hive("acme"), boxes: [Self.lab], failed: [Self.lab.url])
        #expect(down.pick(of: Self.tribe) == .org("acme") && down.options(for: Self.tribe).map(\.id) == ["acme", ""])
        #expect(!down.offersBoxes(in: Self.tribe))
    }

    /// The row offers each org in use, an org the tribe is linked to that
    /// is no longer in use, each box with a Jamie ready by its host (one
    /// without only when it has the tribe; two on one host by their paths
    /// too), then No Jamie; each by an id that reads back as its source, a
    /// box's never an org's.
    @Test func theRowOffersOrgsThenBoxesThenNoJamie() throws {
        let unready = BoxFixture.box("https://old.example.com")
        let choices = JamieChoices(orgs: Self.hive("initech"), boxes: [Self.lab, unready, Self.shop], places: [
            Self.lab.url: BoxPlaces(jamie: Self.boxJamie, tribes: []),
            unready.url: BoxPlaces(jamie: nil, tribes: []),
            Self.shop.url: BoxPlaces(jamie: nil, tribes: [Self.tribe]),
        ])
        let options = choices.options(for: Self.tribe)
        #expect(options.map(\.name) == ["Acme", "@initech", "lab.example.com", "shop.example.com", "No Jamie"])
        #expect(options.map { JamieSource(id: $0.id) } == [.org("acme"), .org("initech"), JamieSource(Self.lab), JamieSource(Self.shop), .noJamie])
        #expect(JamieSource(id: JamieSource(Self.shop).id) == .box("https://shop.example.com/jamie"))
        #expect(!AgentArtifact.Handle.isPeerID(JamieSource(Self.lab).id))
        #expect(JamieChoices(orgs: nil, boxes: [unready], places: [unready.url: BoxPlaces(jamie: nil, tribes: [])])
            .options(for: Self.tribe).map(\.id) == [""])
        let a = BoxFixture.box("https://lab.example.com/a"), b = BoxFixture.box("https://lab.example.com/b")
        let ready = BoxPlaces(jamie: Self.boxJamie, tribes: [])
        #expect(JamieChoices(orgs: nil, boxes: [a, b, Self.shop], places: [a.url: ready, b.url: ready, Self.shop.url: ready])
            .options(for: Self.tribe).map(\.name) == ["lab.example.com/a", "lab.example.com/b", "shop.example.com", "No Jamie"])
    }

    /// A pick adds the new source first, then removes every other that has
    /// Jamie in the tribe; an org in place of another is Hive's one link,
    /// no removal. No Jamie removes them all. Nothing to do when the pick
    /// is all there is, and nothing at all before every source has said.
    @Test func aPickAddsTheNewSourceThenRemovesTheOthers() throws {
        let holding = BoxPlaces(jamie: Self.boxJamie, tribes: [Self.tribe])
        let shop = JamieSource(Self.shop), lab = JamieSource(Self.lab)
        let onAcme = JamieChoices(orgs: Self.hive("acme"), boxes: [Self.lab, Self.shop],
                                  places: [Self.lab.url: BoxPlaces(jamie: Self.boxJamie, tribes: []), Self.shop.url: BoxPlaces(jamie: Self.boxJamie, tribes: [])])
        #expect(onAcme.plan(shop, in: Self.tribe)! == (add: shop, remove: [.org("acme")]))
        #expect(onAcme.plan(.org("globex"), in: Self.tribe)! == (add: .org("globex"), remove: []))
        #expect(onAcme.plan(.org("acme"), in: Self.tribe)! == (add: nil, remove: []))
        #expect(onAcme.plan(.noJamie, in: Self.tribe)! == (add: nil, remove: [.org("acme")]))

        let onShop = JamieChoices(orgs: Self.hive(nil), boxes: [Self.lab, Self.shop],
                                  places: [Self.lab.url: BoxPlaces(jamie: Self.boxJamie, tribes: []), Self.shop.url: holding])
        #expect(onShop.plan(lab, in: Self.tribe)! == (add: lab, remove: [shop]))
        #expect(onShop.plan(.org("acme"), in: Self.tribe)! == (add: .org("acme"), remove: [shop]))

        let both = JamieChoices(orgs: Self.hive("acme"), boxes: [Self.shop], places: [Self.shop.url: holding])
        #expect(both.plan(shop, in: Self.tribe)! == (add: nil, remove: [.org("acme")]))
        #expect(both.plan(.noJamie, in: Self.tribe)! == (add: nil, remove: [.org("acme"), shop]))
        #expect(JamieChoices(orgs: .init(live: [Self.acme], links: nil)).plan(.org("acme"), in: Self.tribe) == nil)
    }

    /// With no Jamie yet, the one tap is the org the tribe's app or second
    /// brain is on, as today; with none, a box with a Jamie ready at the
    /// host one of them is on. Never once the tribe has a Jamie, nor a box
    /// with no Jamie ready.
    @Test func aBoxIsSuggestedOnlyWhereTheTribesPagesAreAndNoOrgIs() throws {
        var tribe = Tribe(pubkey: Self.tribe, host: "h", isOwner: true)
        tribe.appURL = "https://LAB.example.com/apps/board"
        let ready = BoxPlaces(jamie: Self.boxJamie, tribes: [])
        let choices = JamieChoices(orgs: Self.hive(nil), boxes: [Self.shop, Self.lab], places: [Self.shop.url: ready, Self.lab.url: ready])
        #expect(choices.suggestion(for: tribe) == .init(id: JamieSource(Self.lab).id, name: "lab.example.com"))

        tribe.secondBrainURL = "https://swarm38.sphinx.chat/brain"
        #expect(choices.suggestion(for: tribe) == .init(id: "acme", name: "Acme"))

        tribe.secondBrainURL = nil
        #expect(JamieChoices(orgs: Self.hive(nil), boxes: [Self.lab], places: [Self.lab.url: BoxPlaces(jamie: nil, tribes: [])])
            .suggestion(for: tribe) == nil)
        #expect(JamieChoices(orgs: Self.hive("acme"), boxes: [Self.lab], places: [Self.lab.url: ready]).suggestion(for: tribe) == nil)
    }
}
