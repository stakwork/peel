import AgentKit
import Foundation
import enum PeelCore.TextLine

/// What a memory step returned, read for people: a memory tool's row when
/// opened (`MemoryResult`) and the panel for one memory (`MemoryNode`).
/// Strut's shapes are read here and nowhere else; words are cleaned as chat
/// data is, since memory holds what people said.

/// A memory tool's result as its row shows it: the facts written, the
/// results found, or the node read. Nil for the tools whose first line says
/// it all (the vocabulary, forget, merge).
public enum MemoryResult: Sendable, Equatable {
    case remembered(Remembered)
    case found([MemoryRef])
    case read(MemoryNode)

    /// What the agent asked, above its row's result: what it searched for,
    /// or what was said that it remembered.
    public static func asked(tool: String, input: JSONValue) -> String? {
        switch tool {
        case "recall", "graph_graph-search": input["q"]?.string.map { "Searched for \u{201C}\(MemoryRef.clean($0))\u{201D}" }
        case "remember": input["episode"]?.string.map { "From \u{201C}\(MemoryRef.clean($0))\u{201D}" }
        default: nil
        }
    }

    /// The tools whose rows read as one.
    public static let tools: Set<String> = ["remember", "recall", "read_memory", "graph_graph-search", "graph_graph-neighbors", "graph_graph-get"]

    public init?(tool: String, row: JSONValue) {
        switch tool {
        case "remember": self = .remembered(Remembered(row))
        // Search rows are recall's shape; neighbors rows add the edge, which the row leaves out.
        case "recall", "graph_graph-search", "graph_graph-neighbors":
            self = .found(MemoryRef.once((row.array ?? []).compactMap { MemoryRef($0, name: "name", type: "node_type") }, \.id))
        case "read_memory":
            guard let node = MemoryNode(row) else { return nil }
            self = .read(node)
        case "graph_graph-get":
            guard let node = MemoryNode(graphGet: row) else { return nil }
            self = .read(node)
        default: return nil
        }
    }

    /// What one `remember` wrote: its facts, each with the facts it
    /// replaced, the entities it was about, and the words it added to the
    /// vocabulary.
    public struct Remembered: Sendable, Equatable {
        public var facts: [Written]
        public var about: [Mention]
        /// "Pet type", "allergic_to predicate": kept as proposed.
        public var proposed: [String]
        /// A fact that did not fit its predicate, in strut's words.
        public var notes: [String]

        init(_ output: JSONValue) {
            facts = MemoryRef.once((output["facts"]?.array ?? []).compactMap { fact in
                guard let ref = MemoryRef(fact, name: "text", type: nil) else { return nil }
                return Written(fact: ref, isNew: fact["status"]?.string != "existing",
                               replaced: MemoryRef.once((fact["superseded"]?.array ?? []).compactMap(MemoryRef.replaced), \.id))
            }, \.fact.id)
            // One entity may come back twice (named two ways in one remember).
            about = MemoryRef.once((output["entities"]?.array ?? []).compactMap { entity in
                guard let ref = MemoryRef(entity, name: "name", type: "type") else { return nil }
                let similar = (entity["similar"]?.array ?? []).compactMap { MemoryRef($0, name: "name", type: nil) }
                return Mention(entity: ref, isNew: entity["status"]?.string == "created", similar: MemoryRef.once(similar, \.id))
            }, \.entity.id)
            // "predicate allergic_to" from strut, said the other way round.
            proposed = (output["ontology"]?["proposed"]?.array ?? []).compactMap { $0.string }.map { label in
                let words = label.split(separator: " ", maxSplits: 1).map(String.init)
                return words.count == 2 ? MemoryRef.clean(words[1]) + " " + words[0] : MemoryRef.clean(label)
            }
            notes = MemoryRef.once((output["ontology"]?["notes"]?.array ?? []).compactMap { $0.string.map(MemoryRef.clean) }, \.self)
        }
    }

    public struct Written: Sendable, Equatable {
        public var fact: MemoryRef
        /// False for a fact memory already held, written again.
        public var isNew = true
        /// The facts it replaced, now expired; the text when strut gave it.
        public var replaced: [MemoryRef]
    }

    public struct Mention: Sendable, Equatable {
        public var entity: MemoryRef
        /// Made by this remember, rather than matched.
        public var isNew: Bool
        /// Existing entities whose names are close: perhaps the same one.
        public var similar: [MemoryRef]
    }
}

/// A node named in a result: its ref_id, its words (a name, or a fact's
/// sentence) and its type when known. `name` is empty for a replaced fact
/// strut gave only the ref_id of.
public struct MemoryRef: Sendable, Equatable, Hashable {
    public var id: String
    public var name: String
    public var type: String?

    public init(id: String, name: String, type: String? = nil) {
        self.id = id
        self.name = name
        self.type = type
    }

    init?(_ value: JSONValue, name: String, type: String?) {
        guard let id = value["ref_id"]?.string else { return nil }
        self.init(id: id, name: Self.clean(value[name]?.string ?? ""), type: type.flatMap { value[$0]?.string })
    }

    /// A replaced fact: `{ref_id, text}`, or a bare ref_id.
    static func replaced(_ value: JSONValue) -> MemoryRef? {
        if let id = value.string { return MemoryRef(id: id, name: "") }
        return MemoryRef(value, name: "text", type: nil)
    }

    /// `items` with each key once, the first kept: strut may repeat a node.
    static func once<Item, Key: Hashable>(_ items: [Item], _ key: KeyPath<Item, Key>) -> [Item] {
        var seen = Set<Key>()
        return items.filter { seen.insert($0[keyPath: key]).inserted }
    }

    /// One line, at most 500 characters, nothing hidden (`TextLine.clean`).
    static func clean(_ text: String) -> String {
        TextLine.clean(text, max: 500)
    }
}

/// One node of memory as `read_memory` (strut's `memory/get`) returns it.
public enum MemoryNode: Sendable, Equatable {
    case entity(Entity)
    case fact(Fact)
    case episode(Episode)

    public init?(_ output: JSONValue) {
        guard let id = output["ref_id"]?.string, let type = output["node_type"]?.string else { return nil }
        let clean = { (key: String) in MemoryRef.clean(output[key]?.string ?? "") }
        switch type {
        case "Fact":
            self = .fact(Fact(
                id: id, text: clean("text"), predicate: clean("predicate"),
                subject: output["subject"].flatMap { MemoryRef($0, name: "name", type: nil) },
                object: output["object"].flatMap { MemoryRef($0, name: "name", type: nil) },
                since: Self.date(output["valid_at"]), expired: Self.date(output["expired_at"]),
                byAgent: output["created_by"]?.string == "agent",
                from: MemoryRef.once((output["episodes"]?.array ?? []).compactMap { episode in
                    guard let id = episode["ref_id"]?.string else { return nil }
                    return Said(id: id, words: Self.words(episode["excerpt"]?.string), at: Self.date(episode["at"]))
                }, \.id),
                replaced: MemoryRef.once((output["supersedes"]?.array ?? []).compactMap(MemoryRef.replaced), \.id),
                replacedBy: MemoryRef.once((output["superseded_by"]?.array ?? []).compactMap(MemoryRef.replaced), \.id)))
        case "Episode":
            self = .episode(Episode(
                said: Said(id: id, words: Self.words(output["content"]?.string), at: Self.date(output["at"])),
                mentions: MemoryRef.once((output["mentions"]?.array ?? []).compactMap { MemoryRef($0, name: "name", type: "type") }, \.id)))
        default:
            self = .entity(Entity(
                ref: MemoryRef(id: id, name: clean("name"), type: type),
                aliases: (output["aliases"]?.array ?? []).compactMap { $0.string.map(MemoryRef.clean) },
                facts: MemoryRef.once((output["facts"]?.array ?? []).compactMap { fact in
                    guard let ref = MemoryRef(fact, name: "text", type: nil) else { return nil }
                    return Entity.Known(fact: ref, since: Self.date(fact["since"]))
                }, \.fact.id),
                mentionedIn: output["mentioned_in_episodes"]?.int ?? 0))
        }
    }

    /// A node as strut's `graph/graph-get` returns it: `{ref_id, node_type,
    /// name, properties, edges}`, `edges` a count per edge type. The facts,
    /// sources and replaced facts are left empty: the panel opened from a row
    /// loads the whole node (`memory/get`).
    public init?(graphGet output: JSONValue) {
        guard let id = output["ref_id"]?.string, let type = output["node_type"]?.string else { return nil }
        let properties = output["properties"]
        let clean = { (value: JSONValue?) in MemoryRef.clean(value?.string ?? "") }
        switch type {
        case "Fact":
            self = .fact(Fact(
                id: id, text: clean(properties?["text"]), predicate: clean(properties?["predicate"]),
                subject: properties?["subject_ref_id"]?.string.map { MemoryRef(id: $0, name: clean(properties?["subject"])) },
                object: properties?["object_ref_id"]?.string.map { MemoryRef(id: $0, name: clean(properties?["object"])) },
                since: Self.date(properties?["valid_at"]), expired: Self.date(properties?["expired_at"]),
                byAgent: properties?["created_by"]?.string == "agent",
                from: [], replaced: [], replacedBy: []))
        case "Episode":
            self = .episode(Episode(
                said: Said(id: id, words: Self.words(properties?["content"]?.string), at: Self.date(properties?["occurred_at"])),
                mentions: []))
        default:
            self = .entity(Entity(
                ref: MemoryRef(id: id, name: clean(output["name"]), type: type),
                aliases: (properties?["aliases"]?.array ?? []).compactMap { $0.string.map(MemoryRef.clean) },
                facts: [], mentionedIn: 0))
        }
    }

    public var ref: MemoryRef {
        switch self {
        case .entity(let entity): entity.ref
        case .fact(let fact): MemoryRef(id: fact.id, name: fact.text, type: "Fact")
        case .episode(let episode): MemoryRef(id: episode.said.id, name: episode.said.words, type: "Episode")
        }
    }

    public struct Entity: Sendable, Equatable {
        public var ref: MemoryRef
        /// Other names it goes by, its own name left out.
        public var aliases: [String]
        /// Its current facts.
        public var facts: [Known]
        public var mentionedIn: Int

        init(ref: MemoryRef, aliases: [String], facts: [Known], mentionedIn: Int) {
            self.ref = ref
            self.aliases = aliases.filter { $0.caseInsensitiveCompare(ref.name) != .orderedSame }
            self.facts = facts
            self.mentionedIn = mentionedIn
        }

        public struct Known: Sendable, Equatable {
            public var fact: MemoryRef
            public var since: Date?
        }
    }

    public struct Fact: Sendable, Equatable {
        public var id: String
        public var text: String
        /// As written: "lives_in".
        public var predicate: String
        public var subject: MemoryRef?
        public var object: MemoryRef?
        public var since: Date?
        /// When it was replaced, if it was.
        public var expired: Date?
        public var byAgent: Bool
        /// What was said that it came from.
        public var from: [Said]
        public var replaced: [MemoryRef]
        public var replacedBy: [MemoryRef]
    }

    public struct Episode: Sendable, Equatable {
        public var said: Said
        public var mentions: [MemoryRef]
    }

    /// What someone said, as memory kept it.
    public struct Said: Sendable, Equatable {
        public var id: String
        public var words: String
        public var at: Date?
    }

    /// Said words keep their paragraphs; only hidden characters go.
    static func words(_ text: String?) -> String {
        (text ?? "").replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: .newlines)
            .map { TextLine.clean($0, max: ChatData.maxCharacters) }.joined(separator: "\n")
    }

    static func date(_ value: JSONValue?) -> Date? {
        guard let text = value?.string else { return nil }
        return (try? withFraction.parse(text)) ?? (try? withoutFraction.parse(text))
    }

    /// Strut's dates, with milliseconds, and any without.
    private static let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let withoutFraction = Date.ISO8601FormatStyle()
}
