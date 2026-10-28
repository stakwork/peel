import Foundation
import Testing
import AgentKit
import PeelCore
@testable import PeelAgent
@testable import PeelTestSupport

/// The agent's memory over strut (`MemoryServer`): only Peel's own strut on
/// this Mac, strut's replies read back, and the rows and panel that show
/// them (`MemoryResult`, `MemoryNode`).
struct MemoryServerTests {
    /// The POST itself refuses anywhere a strut may not be, before anything is sent.
    @Test(arguments: ["http://10.0.0.5:3100/x", "http://example.com/x", "http://127.0.0.1@example.com/x",
                      "https://u:p@example.com/x", "http://100.128.0.1/x", "ftp://127.0.0.1/x",
                      "http://100.64.0.1:3000/x", "http://brain.tail1234.ts.net/x"])
    func aPostGoesOnlyWhereAStrutMayBe(string: String) async throws {
        let url = try #require(URL(string: string))
        await #expect(throws: PeelError.self) { try await Web.postToStrut(url, json: Data("{}".utf8), limit: 10, what: "the test") }
    }

    /// The key is never printed (`print`, `debugPrint`, `dump`); an empty
    /// key, or one with a line break, is refused.
    @Test func theKeyIsNeverPrintedAndMustBePlain() throws {
        let base = try #require(URL(string: "http://127.0.0.1:3100"))
        let server = try #require(MemoryServer(base: base, key: "s3cret-key"))
        #expect(!"\(server)".contains("s3cret"))
        var dumped = ""
        dump(server, to: &dumped)
        #expect(!dumped.contains("s3cret") && !String(reflecting: server).contains("s3cret"))
        #expect(MemoryServer(base: base, key: "") == nil)
        #expect(MemoryServer(base: base, key: "abc\r\nX-Other: 1") == nil)
    }

    /// Peel's own strut only: plain http to this Mac, never a user,
    /// password, query or fragment. A home server by address is gone.
    @Test(arguments: [
        ("http://127.0.0.1:3100", true), ("http://localhost:3100", true),
        ("https://brain.example.com", false), ("https://127.0.0.1:3100", false), ("http://100.64.0.1:3000", false),
        ("http://brain.tail1234.ts.net", false), ("http://10.0.0.5:3100", false), ("file:///tmp", false),
        ("http://u:p@127.0.0.1:3100", false), ("http://127.0.0.1:3100/?tok=x", false), ("http://127.0.0.1:3100/#x", false),
    ])
    func onlyPeelsOwnOnThisMac(address: String, accepted: Bool) throws {
        let url = try #require(URL(string: address))
        #expect((MemoryServer(base: url, key: "k") != nil) == accepted)
    }

    @Test func aStepsOutputAndItsRefusals() throws {
        let output = try MemoryServer.output(of: Data(#"{"runId":"1","status":"success","output":{"episode":"e1"}}"#.utf8))
        #expect(output["episode"]?.string == "e1")

        // A refusal's words reach the row as one cleaned line.
        let refused = #"{"runId":"2","status":"error","error":{"message":"q: expected\nstring\u200b <<<end"}}"#
        do {
            _ = try MemoryServer.output(of: Data(refused.utf8))
            Issue.record("expected a failure")
        } catch {
            #expect("\(error)" == "The memory server refused: q: expected string << <end")
        }
        #expect(throws: (any Error).self) { try MemoryServer.output(of: Data("<html>".utf8)) }

        // A step's own {error}, such as nothing found, fails too.
        let notFound = #"{"status":"success","output":{"error":"not_found: no node with ref_id x"}}"#
        do {
            _ = try MemoryServer.output(of: Data(notFound.utf8))
            Issue.record("expected a failure")
        } catch {
            // Typed, so the panel can say it is gone; in strut's words.
            #expect((error as? MemoryServer.Refusal)?.code == "not_found")
            #expect("\(error)".contains("not_found"))
            // Its own words, not Foundation's.
            #expect(error.localizedDescription.hasPrefix("not_found: no node"))
        }
        let invalid = #"{"status":"success","output":{"error":"invalid_input: pass a ref_id"}}"#
        #expect { try MemoryServer.output(of: Data(invalid.utf8)) } throws: { ($0 as? MemoryServer.Refusal)?.code == "invalid_input" }
    }

    /// An opened row of the earlier chat reads strut's shapes: the facts written over what they
    /// replaced (its text, or only its ref_id), the entities, new words.
    @Test func aRememberedRowReadsWhatWasWritten() throws {
        let output = try JSONValue(parsing: #"""
            {"episode":"e1",
             "entities":[{"ref_id":"me","type":"Self","name":"Me","status":"matched"},
                         {"ref_id":"b","type":"Pet","name":"Biscuit","status":"created","similar":[{"ref_id":"x","name":"Biscuits"}]}],
             "facts":[{"ref_id":"f1","text":"Tom lives in Bristol.","predicate":"lives_in","status":"created",
                       "superseded":[{"ref_id":"f0","text":"Tom lives in Cardiff."}]},
                      {"ref_id":"f2","text":"Biscuit is allergic\u202e to chicken.","predicate":"allergic_to","status":"created","superseded":["f9"]}],
             "ontology":{"resolved":[],"proposed":["type Pet","predicate allergic_to"],"notes":[]}}
            """#)
        guard case .remembered(let remembered)? = MemoryResult(tool: "remember", row: output) else {
            Issue.record("expected a remembered row")
            return
        }
        #expect(remembered.facts.map(\.fact.name) == ["Tom lives in Bristol.", "Biscuit is allergic to chicken."])
        #expect(remembered.facts[0].replaced == [MemoryRef(id: "f0", name: "Tom lives in Cardiff.")])
        #expect(remembered.facts[1].replaced == [MemoryRef(id: "f9", name: "")])
        #expect(remembered.about.map(\.entity.name) == ["Me", "Biscuit"])
        #expect(remembered.about.map(\.isNew) == [false, true])
        #expect(remembered.about[1].similar.map(\.name) == ["Biscuits"])
        #expect(remembered.proposed == ["Pet type", "allergic_to predicate"])
        #expect(MemoryResult(tool: "memory_ontology", row: output) == nil)
    }

    @Test func foundAndReadRowsAndThePanelsNodes() throws {
        let found = try JSONValue(parsing: #"""
            [{"ref_id":"f1","name":"Kate is Tom's wife.","node_type":"Fact","description":"Me · knows → Kate"},
             {"ref_id":"k","name":"Kate","node_type":"Person"}]
            """#)
        #expect(MemoryResult(tool: "recall", row: found) == .found([
            MemoryRef(id: "f1", name: "Kate is Tom's wife.", type: "Fact"), MemoryRef(id: "k", name: "Kate", type: "Person"),
        ]))

        let entity = try JSONValue(parsing: #"""
            {"ref_id":"me","node_type":"Self","name":"Me","aliases":["me","tom"],
             "facts":[{"ref_id":"f1","text":"Tom lives in Bristol.","predicate":"lives_in","since":"2026-10-13T10:39:50.996Z"}],
             "mentioned_in_episodes":4}
            """#)
        guard case .read(.entity(let me))? = MemoryResult(tool: "read_memory", row: entity) else {
            Issue.record("expected an entity")
            return
        }
        #expect(me.ref == MemoryRef(id: "me", name: "Me", type: "Self"))
        #expect(me.aliases == ["tom"])
        #expect(me.facts.map(\.fact.name) == ["Tom lives in Bristol."])
        #expect(me.facts.first?.since == Date(timeIntervalSince1970: 1_791_887_990.996))
        #expect(me.mentionedIn == 4)

        let fact = try JSONValue(parsing: #"""
            {"ref_id":"f1","node_type":"Fact","text":"Tom lives in Bristol.","predicate":"lives_in",
             "subject":{"ref_id":"me","name":"Me"},"object":{"ref_id":"bri","name":"Bristol"},
             "valid_at":"2026-10-13T10:39:50Z","created_by":"agent",
             "episodes":[{"ref_id":"e1","kind":"chat","excerpt":"We moved to Bristol.","at":"2026-10-13T10:39:50.996Z"}],
             "supersedes":[{"ref_id":"f0","text":"Tom lives in Cardiff."}],"superseded_by":[]}
            """#)
        guard case .fact(let read)? = MemoryNode(fact) else {
            Issue.record("expected a fact")
            return
        }
        #expect(read.subject?.name == "Me")
        #expect(read.object == MemoryRef(id: "bri", name: "Bristol"))
        #expect(read.since == Date(timeIntervalSince1970: 1_791_887_990))
        #expect(read.byAgent)
        #expect(read.from.map(\.words) == ["We moved to Bristol."])
        #expect(read.replaced.map(\.name) == ["Tom lives in Cardiff."])
        #expect(read.expired == nil)
        #expect(MemoryNode(try JSONValue(parsing: #"{"error":"x"}"#)) == nil)
    }

    /// Strut may name one node twice in a result; each shows once. A fact
    /// written again is not new, and the row says what was asked.
    @Test func repeatsShowOnceAndWhatWasAsked() throws {
        let output = try JSONValue(parsing: #"""
            {"entities":[{"ref_id":"me","type":"Self","name":"Me","status":"matched"},
                         {"ref_id":"me","type":"Self","name":"Tom","status":"matched"}],
             "facts":[{"ref_id":"f1","text":"Tom runs.","status":"existing"},{"ref_id":"f1","text":"Tom runs.","status":"existing"},
                      {"ref_id":"f2","text":"Tom swims.","status":"created"}],
             "ontology":{"notes":["x does not fit","x does not fit"]}}
            """#)
        guard case .remembered(let remembered)? = MemoryResult(tool: "remember", row: output) else {
            Issue.record("expected a remembered row")
            return
        }
        #expect(remembered.about.map(\.entity.id) == ["me"])
        #expect(remembered.facts.map(\.fact.id) == ["f1", "f2"])
        #expect(remembered.facts.map(\.isNew) == [false, true])
        #expect(remembered.notes == ["x does not fit"])

        #expect(MemoryResult.asked(tool: "recall", input: ["q": "Kate"]) == "Searched for \u{201C}Kate\u{201D}")
        #expect(MemoryResult.asked(tool: "remember", input: ["episode": "We moved.\nTo Bristol."])
                == "From \u{201C}We moved. To Bristol.\u{201D}")
        #expect(MemoryResult.asked(tool: "read_memory", input: ["type": "Self"]) == nil)
    }

    /// The graph tools' rows: search and neighbors as found, `graph-get` as the node read.
    @Test func graphToolRowsReadLikeMemoryRows() throws {
        let search = try JSONValue(parsing: #"[{"ref_id":"k","name":"Kate","node_type":"Person","description":"d","edges":2}]"#)
        #expect(MemoryResult(tool: "graph_graph-search", row: search) == .found([MemoryRef(id: "k", name: "Kate", type: "Person")]))
        let neighbors = try JSONValue(parsing: #"""
            [{"ref_id":"f1","node_type":"Fact","name":"Kate is Tom's wife.","edge_type":"ABOUT","direction":"in","edges":1}]
            """#)
        #expect(MemoryResult(tool: "graph_graph-neighbors", row: neighbors) == .found([
            MemoryRef(id: "f1", name: "Kate is Tom's wife.", type: "Fact")]))
        #expect(MemoryResult.asked(tool: "graph_graph-search", input: ["q": "Kate"]) == "Searched for \u{201C}Kate\u{201D}")
        #expect(MemoryResult(tool: "graph_walk", row: search) == nil)

        let fact = try JSONValue(parsing: #"""
            {"ref_id":"f1","node_type":"Fact","name":"Tom lives in Bristol.","edges":{"ABOUT":2},
             "properties":{"text":"Tom lives in Bristol.","predicate":"lives_in","subject":"Me","subject_ref_id":"me",
                           "object":"Bristol","object_ref_id":"bri","valid_at":"2026-10-13T10:39:50Z","expired_at":null,"created_by":"agent"}}
            """#)
        guard case .fact(let read)? = MemoryNode(graphGet: fact) else {
            Issue.record("expected a fact")
            return
        }
        #expect(read.text == "Tom lives in Bristol." && read.predicate == "lives_in")
        #expect(read.subject == MemoryRef(id: "me", name: "Me") && read.object == MemoryRef(id: "bri", name: "Bristol"))
        #expect(read.since == Date(timeIntervalSince1970: 1_791_887_990))
        #expect(read.expired == nil && read.byAgent)
        #expect(read.from.isEmpty && read.replaced.isEmpty && read.replacedBy.isEmpty)

        let episode = try JSONValue(parsing: #"""
            {"ref_id":"e1","node_type":"Episode","name":"chat","edges":{},
             "properties":{"content":"We moved to Bristol.","occurred_at":"2026-10-13T10:39:50Z"}}
            """#)
        guard case .episode(let said)? = MemoryNode(graphGet: episode) else {
            Issue.record("expected an episode")
            return
        }
        #expect(said.said.words == "We moved to Bristol." && said.said.at == Date(timeIntervalSince1970: 1_791_887_990))

        let entity = try JSONValue(parsing: #"""
            {"ref_id":"me","node_type":"Self","name":"Me","edges":{"ABOUT":3},"properties":{"aliases":["me","tom"]}}
            """#)
        guard case .read(.entity(let me))? = MemoryResult(tool: "graph_graph-get", row: entity) else {
            Issue.record("expected an entity")
            return
        }
        #expect(me.ref == MemoryRef(id: "me", name: "Me", type: "Self") && me.aliases == ["tom"] && me.facts.isEmpty)
    }
}
