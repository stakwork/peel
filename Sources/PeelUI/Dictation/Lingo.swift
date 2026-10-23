import AgentKit
import Foundation

/// The user's vocabulary as strut's `memory/lexicon` reads it, for the
/// Vocabulary window to show. Strut does all the judging (stakwork/strut#301:
/// the rewrite in `/audio/transcribe`, learning in `dictation/correction`);
/// this is only what there is to list.
public struct LingoLexicon: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var refID: String
        public var type: String
        public var name: String
        /// Correct ways to write it, the name first ("Bitcoin", "BTC").
        public var written: [String]
        public var heard: [Heard]
        public var dictationOff: Bool
        /// A word taught to dictation (strut's `lingo_type`), rather than a
        /// person or project that also has mishearings.
        public var isLingo: Bool

        public init(refID: String, type: String, name: String, written: [String], heard: [Heard] = [],
                    dictationOff: Bool = false, isLingo: Bool = false) {
            self.refID = refID
            self.type = type
            self.name = name
            self.written = written
            self.heard = heard
            self.dictationOff = dictationOff
            self.isLingo = isLingo
        }
    }

    /// A mishearing: dictation writes `value` for `form` (nil: the entity's name).
    public struct Heard: Equatable, Sendable {
        public var refID: String
        public var value: String
        public var form: String?

        public init(refID: String, value: String, form: String? = nil) {
            self.refID = refID
            self.value = value
            self.form = form
        }
    }

    public var entries: [Entry]

    public init(entries: [Entry] = []) { self.entries = entries }

    public static let empty = LingoLexicon()

    /// `memory/lexicon`'s output: `{ lingo_type, entities: [...] }`.
    public init(lexicon output: AgentKit.JSONValue) {
        let lingoType = output["lingo_type"]?.string ?? "Lingo"
        entries = (output["entities"]?.array ?? []).compactMap { entity -> Entry? in
            guard let id = entity["ref_id"]?.string, let name = entity["name"]?.string else { return nil }
            let heard = (entity["heard"]?.array ?? []).compactMap { heard -> Heard? in
                guard let id = heard["ref_id"]?.string, let value = heard["value"]?.string else { return nil }
                return Heard(refID: id, value: value, form: heard["form"]?.string)
            }
            let type = entity["type"]?.string ?? ""
            return Entry(
                refID: id, type: type, name: name,
                written: entity["written"]?.array?.compactMap(\.string) ?? [name], heard: heard,
                dictationOff: entity["dictation_off"] == .bool(true), isLingo: type == lingoType
            )
        }
    }
}

/// What strut's `dictation/correction` learned from an edit: each pair, and
/// what to pass to `dictation/undo` (empty when strut already had it).
public struct LingoLearned: Equatable, Sendable {
    public var heard: String
    public var written: String
    public var undo: [String]

    public init(heard: String, written: String, undo: [String]) {
        self.heard = heard
        self.written = written
        self.undo = undo
    }

    /// `dictation/correction`'s output: `{ learned: [{ heard, written, undo }] }`.
    public static func list(from output: AgentKit.JSONValue) -> [LingoLearned] {
        (output["learned"]?.array ?? []).compactMap { pair in
            guard let heard = pair["heard"]?.string, let written = pair["written"]?.string else { return nil }
            return LingoLearned(heard: heard, written: written, undo: pair["undo"]?.array?.compactMap(\.string) ?? [])
        }
    }
}
