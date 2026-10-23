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
        public var heard: [Heard]
        public var dictationOff: Bool

        public init(refID: String, type: String, name: String, heard: [Heard] = [], dictationOff: Bool = false) {
            self.refID = refID
            self.type = type
            self.name = name
            self.heard = heard
            self.dictationOff = dictationOff
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

    /// The vocabulary's words: what dictation mishears, and what the user
    /// told it to leave alone. One rule for the Vocabulary window's list and
    /// every count of it.
    public var words: [Entry] { entries.filter { !$0.heard.isEmpty || $0.dictationOff } }

    public var wordCount: Int { words.count }

    /// `memory/lexicon`'s output: `{ entities: [...] }`.
    public init(lexicon output: AgentKit.JSONValue) {
        entries = (output["entities"]?.array ?? []).compactMap { entity -> Entry? in
            guard let id = entity["ref_id"]?.string, let name = entity["name"]?.string else { return nil }
            let heard = (entity["heard"]?.array ?? []).compactMap { heard -> Heard? in
                guard let id = heard["ref_id"]?.string, let value = heard["value"]?.string else { return nil }
                return Heard(refID: id, value: value, form: heard["form"]?.string)
            }
            return Entry(
                refID: id, type: entity["type"]?.string ?? "", name: name, heard: heard,
                dictationOff: entity["dictation_off"] == .bool(true)
            )
        }
    }
}

/// What strut's `dictation/correction` learned from an edit: each word as
/// written, and what to pass to `dictation/undo` (empty when strut already had it).
public struct LingoLearned: Equatable, Sendable {
    public var written: String
    public var undo: [String]

    public init(written: String, undo: [String]) {
        self.written = written
        self.undo = undo
    }

    /// `dictation/correction`'s output: `{ learned: [{ heard, written, undo }] }`.
    public static func list(from output: AgentKit.JSONValue) -> [LingoLearned] {
        (output["learned"]?.array ?? []).compactMap { pair in
            guard let written = pair["written"]?.string else { return nil }
            return LingoLearned(written: written, undo: pair["undo"]?.array?.compactMap(\.string) ?? [])
        }
    }
}

/// One of the models dictation runs on Peel's strut, as `dictation/models`,
/// `dictation/use` and `dictation/remove-model` list them: a speech model
/// (what you said, as text) or a fixer (the small model that puts
/// dictation right and learns from your edits). Strut downloads a pick
/// that is not installed and uses it once it is.
public struct DictationModel: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case speech, fixer }
    public enum State: String, Sendable { case available, downloading, installed }

    public var id: String
    public var kind: Kind
    /// Strut's name for it ("Kroko"), and what it does for you in a line.
    public var name: String
    public var summary: String
    /// The download's size.
    public var bytes: Int64
    /// Strut's longer description.
    public var description: String
    public var state: State
    /// 0...1 while downloading, when strut knows.
    public var progress: Double?
    /// How much has come down, while downloading.
    public var downloaded: Int64?
    /// The user's pick for its kind.
    public var selected: Bool
    /// In use now: the pick once it is installed, until then the one before.
    public var active: Bool
    /// Strut's choice for its kind.
    public var recommended: Bool
    /// On this Mac and safe to remove (not in use, not what dictation falls back on).
    public var removable: Bool
    /// Why its last download failed.
    public var error: String?

    public init(id: String, kind: Kind, name: String? = nil, summary: String = "", bytes: Int64, description: String = "",
                state: State, progress: Double? = nil, downloaded: Int64? = nil, selected: Bool = false,
                active: Bool = false, recommended: Bool = false, removable: Bool = false, error: String? = nil) {
        self.id = id
        self.kind = kind
        self.name = name ?? id
        self.summary = summary
        self.bytes = bytes
        self.description = description
        self.state = state
        self.progress = progress
        self.downloaded = downloaded
        self.selected = selected
        self.active = active
        self.recommended = recommended
        self.removable = removable
        self.error = error
    }

    /// The steps' reply: `{ models: [...] }`; a model of a kind or state
    /// Peel does not know is left out.
    public static func list(from output: AgentKit.JSONValue) -> [DictationModel] {
        (output["models"]?.array ?? []).compactMap { model in
            guard let id = model["id"]?.string,
                  let kind = model["kind"]?.string.flatMap(Kind.init(rawValue:)),
                  let state = model["state"]?.string.flatMap(State.init(rawValue:)) else { return nil }
            let description = model["description"]?.string ?? ""
            return DictationModel(
                id: id, kind: kind, name: model["name"]?.string, summary: model["summary"]?.string ?? description,
                bytes: Int64(model["bytes"]?.int ?? 0), description: description, state: state,
                progress: number(model["progress"]).map { min(max($0, 0), 1) },
                downloaded: model["downloaded"]?.int.map(Int64.init), selected: model["selected"] == .bool(true),
                active: model["active"] == .bool(true), recommended: model["recommended"] == .bool(true),
                removable: model["removable"] == .bool(true), error: model["error"]?.string
            )
        }
    }

    private static func number(_ value: AgentKit.JSONValue?) -> Double? {
        if case .number(let number)? = value { number } else { nil }
    }
}
