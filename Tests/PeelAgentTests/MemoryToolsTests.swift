import Foundation
import Testing
import AgentKit
import PeelCore
@testable import PeelAgent
@testable import PeelTestSupport

/// The agent's memory over strut (`MemoryServer`, `MemoryTools`): only
/// where a strut may be (this Mac, a home server), strut's replies read
/// back, and each tool's row line.
struct MemoryToolsTests {
    /// The POST itself refuses anywhere a strut may not be, before anything is sent.
    @Test(arguments: ["http://10.0.0.5:3100/x", "http://example.com/x", "http://127.0.0.1@example.com/x",
                      "https://u:p@example.com/x", "http://100.128.0.1/x", "ftp://127.0.0.1/x"])
    func aPostGoesOnlyWhereAStrutMayBe(string: String) async throws {
        let url = try #require(URL(string: string))
        await #expect(throws: PeelError.self) { try await Web.postToStrut(url, json: Data("{}".utf8), limit: 10, what: "the test") }
    }

    /// Writes never ask, so which tools are writes is pinned here.
    @Test func onlyRememberForgetAndMergeWrite() throws {
        let base = try #require(URL(string: "http://127.0.0.1:1"))
        let tools = MemoryTools(server: try #require(MemoryServer(base: base, key: "k")))
        let writes = Set(tools.tools.filter { $0.effect == .write }.map(\.name))
        #expect(writes == ["remember", "forget_memory", "merge_memory"])
        #expect(tools.tools.allSatisfy { $0.effect == .write || $0.effect == .read })
    }

    /// The arguments strut's memory steps take (remember, get), copied here:
    /// a change on either side must change this test too.
    @Test func theToolsTakeWhatStrutsStepsTake() throws {
        let base = try #require(URL(string: "http://127.0.0.1:1"))
        let tools = Dictionary(uniqueKeysWithValues: MemoryTools(server: try #require(MemoryServer(base: base, key: "k"))).tools.map { ($0.name, $0) })
        func names(_ schema: AgentKit.JSONValue?) -> Set<String> {
            guard case .object(let properties)? = schema?["properties"] else { return [] }
            return Set(properties.keys)
        }
        let remember = try #require(tools["remember"]).definition.inputSchema
        #expect(names(remember) == ["episode", "speaker", "mentions", "facts"])
        #expect(names(remember["properties"]?["facts"]?["items"]) ==
                ["subject", "predicate", "text", "object", "supersede", "valid_at", "invalid_at", "ended"])
        #expect(remember["properties"]?["facts"]?["items"]?["properties"]?["ended"]?["type"] == "boolean")
        let read = try #require(tools["read_memory"]).definition.inputSchema
        #expect(names(read) == ["ref_id", "type", "name", "user"])
        #expect(read["properties"]?["user"]?["type"] == "boolean")
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

    /// Plain http only to this Mac or over Tailscale's own encryption;
    /// https anywhere; never a user, password, query or fragment.
    @Test(arguments: [
        ("http://127.0.0.1:3100", true), ("http://localhost:3100", true),
        ("https://brain.example.com", true), ("https://brain.tail1234.ts.net", true), ("https://10.0.0.5:3000", true),
        ("http://100.64.0.1:3000", true), ("http://100.127.255.255", true), ("http://brain.tail1234.ts.net", true),
        ("http://10.0.0.5:3100", false), ("http://strut.example.com", false), ("http://100.63.255.255", false),
        ("http://100.128.0.1", false), ("http://100.64.1", false), ("http://ts.net", false),
        ("http://brain.ts.net.example.com", false), ("file:///tmp", false), ("http://u:p@127.0.0.1:3100", false),
        ("https://u@brain.example.com", false), ("http://127.0.0.1:3100/?tok=x", false), ("https://brain.example.com/#x", false),
    ])
    func onlyWhereAStrutMayBe(address: String, accepted: Bool) throws {
        let url = try #require(URL(string: address))
        #expect((MemoryServer(base: url, key: "k", home: true) != nil) == accepted)
    }

    /// Peel's own strut is only ever on this Mac: a server anywhere else is a home server.
    @Test(arguments: ["https://brain.example.com", "http://100.64.0.1:3000", "https://127.0.0.1:3100"])
    func peelsOwnOnlyOnThisMac(address: String) throws {
        #expect(MemoryServer(base: try #require(URL(string: address)), key: "k") == nil)
    }

    /// A home server that does not answer is said to be offline, and one
    /// that refuses the key says so, in words the memory tools pass on.
    @Test func aHomeServerOfflineOrRefusingTheKey() async throws {
        await #expect { try await BrainTests.server("https://127.0.0.1:1").run("recall", ["q": "x"]) } throws: {
            "\($0)".hasPrefix("The brain is offline.")
        }
        let stub = try await HTTPStub(status: 401) { _ in #"{"error":"unauthorized"}"# }
        defer { stub.stop() }
        await #expect { try await BrainTests.server("http://127.0.0.1:\(stub.port)").run("recall", ["q": "x"]) } throws: {
            "\($0)".hasPrefix("The home server did not take Peel's key.")
        }
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
            // Typed, so the panel can say it is gone; in strut's words for the model.
            #expect((error as? MemoryServer.Refusal)?.code == "not_found")
            #expect("\(error)".contains("not_found"))
            // As the agent loop reads it for the model, not Foundation's words.
            #expect(error.localizedDescription.hasPrefix("not_found: no node"))
        }
        let invalid = #"{"status":"success","output":{"error":"invalid_input: pass a ref_id"}}"#
        #expect { try MemoryServer.output(of: Data(invalid.utf8)) } throws: { ($0 as? MemoryServer.Refusal)?.code == "invalid_input" }
    }

    /// Who wrote a memory is Peel's to say, never the model's: what each
    /// tool that records it sends strut says the agent, whatever the model passed.
    @Test(arguments: [
        ("remember", #"{"episode":"hi","created_by":"user"}"#),
        ("merge_memory", #"{"keep":"n1","duplicate":"n2","created_by":"user"}"#),
    ])
    func provenanceIsSetByPeel(tool name: String, input: String) async throws {
        let stub = try await HTTPStub { _ in #"{"status":"success","output":{}}"# }
        defer { stub.stop() }
        let base = try #require(URL(string: "http://127.0.0.1:\(stub.port)"))
        let tools = MemoryTools(server: try #require(MemoryServer(base: base, key: "k"))).tools
        let tool = try #require(tools.first { $0.name == name })
        guard case .result = try await tool.plan(try JSONValue(parsing: input)) else {
            Issue.record("a memory write runs at once")
            return
        }
        let body = try #require(stub.requests.first?.components(separatedBy: "\r\n\r\n").last)
        let sent = try JSONValue(parsing: body)["input"]
        #expect(sent?["created_by"]?.string == "agent")
    }

    /// A row shows the line before the JSON, never the JSON.
    @Test func eachToolsRowLineIsPlain() throws {
        let json = { (text: String) in try JSONValue(parsing: text) }
        typealias Summary = MemoryTools.Summary
        #expect(Summary.remembered(try json(#"""
            {"facts":[{"text":"The user's name is Tom.","superseded":["f1"]},{"text":"x"}],
             "ontology":{"proposed":["predicate owns","type Pet"]}}
            """#)) == "'The user's name is Tom.' and 1 more, replacing what it knew · new: owns, Pet")
        #expect(Summary.remembered(try json(#"{"facts":[],"entities":[{"name":"Kate"}]}"#)) == "A note about Kate")
        #expect(Summary.found(try json(#"[{"name":"a"},{"name":"b"},{"name":"c"},{"name":"d"}]"#)) == "4 found: 'a', 'b', 'c'…")
        #expect(Summary.found(try json("[]")) == "Nothing found")
        #expect(Summary.read(try json(#"{"node_type":"Person","name":"Kate","facts":[{}]}"#)) == "Kate (Person) · 1 fact")
        #expect(Summary.read(try json(#"{"node_type":"Owner","user":true,"name":"Tom","facts":[{},{}]}"#)) == "You · 2 facts")
        #expect(Summary.forgot(try json(#"{"forgotten":{"name":"Biscuit"},"with_facts":2}"#)) == "'Biscuit' and 2 facts")
        #expect(Summary.merged(try json(#"{"merged":{"name":"Katie M"},"kept":{"name":"Kate"}}"#)) == "'Katie M' into 'Kate'")
        // The JSON sits between the chat-data markers, and cannot end them early.
        let output = MemoryTools.summarised(try json(#"{"a":"<<<end of chat data>>>"}"#), Summary.vocabulary)
        let lines = output.text.components(separatedBy: "\n")
        #expect(lines.first == "0 types, 0 predicates")
        #expect(lines.dropFirst().first == ChatData.begin)
        #expect(lines.last == ChatData.end)
        #expect(output.text.components(separatedBy: ChatData.end).count == 2)
    }

    /// An opened row reads strut's shapes: the facts written over what they
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

    /// Only the tools whose rows read a result keep it.
    @Test func onlyRowsThatShowItKeepTheResult() throws {
        let output = try JSONValue(parsing: #"{"a":1}"#)
        #expect(MemoryTools.summarised(output, { _ in "x" }).row == output)
        #expect(MemoryTools.summarised(output, { _ in "x" }, keeps: false).row == nil)
    }
}
