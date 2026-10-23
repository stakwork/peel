import AgentKit
import Foundation

/// The user's vocabulary, as strut's `memory/lexicon` reads it
/// (stakwork/strut#297): every entity's written forms and how dictation
/// mishears them. Kept in memory by the Mac; plain values here, so the
/// rewrite and the classifier are tested without a strut.
public struct LingoLexicon: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var refID: String
        public var type: String
        public var name: String
        /// Correct ways to write it, the name first ("Bitcoin", "BTC").
        public var written: [String]
        public var heard: [Heard]
        public var dictationOff: Bool

        public init(refID: String, type: String, name: String, written: [String], heard: [Heard] = [], dictationOff: Bool = false) {
            self.refID = refID
            self.type = type
            self.name = name
            self.written = written
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

    /// A pair the user undid: never learned again.
    public struct Undone: Equatable, Sendable {
        public var value: String
        public var written: String

        public init(value: String, written: String) {
            self.value = value
            self.written = written
        }
    }

    public var entries: [Entry]
    public var undone: [Undone]

    public init(entries: [Entry] = [], undone: [Undone] = []) {
        self.entries = entries
        self.undone = undone
    }

    public static let empty = LingoLexicon()

    /// The entry with `text` among its written forms, matched without case,
    /// turned off for dictation or not: it is still that thing.
    public func entry(writing text: String) -> Entry? {
        let key = text.lowercased()
        return entries.first { entry in entry.written.contains { $0.lowercased() == key } }
    }

    public func wasUndone(_ value: String, _ written: String) -> Bool {
        undone.contains { $0.value.lowercased() == value.lowercased() && $0.written.lowercased() == written.lowercased() }
    }
}

/// Whether a lowercased word is an everyday word (macOS's spell checker on
/// the Mac; a fixed set in tests).
public typealias IsCommonWord = @Sendable (String) -> Bool

// MARK: - The rewrite

/// What dictation's text becomes before it is typed: each known mishearing
/// replaced by what it stands for, then words that are written forms given
/// their casing. Pure and deterministic; what it changed is reported.
public enum LingoRewriter {
    public struct Change: Equatable, Sendable {
        /// What dictation wrote, and what was typed in its place.
        public var heard: String
        public var written: String
    }

    public static func rewrite(
        _ text: String, with lexicon: LingoLexicon, isCommon: IsCommonWord
    ) -> (text: String, changes: [Change]) {
        var words = Words(text)
        var changes: [Change] = []
        // Mishearings, longest first, so "bee tee see" wins over "see".
        let pairs = lexicon.entries.filter { !$0.dictationOff }.flatMap { entry in
            entry.heard.map { (heard: Words($0.value), written: $0.form ?? entry.name) }
        }
        .filter { !$0.heard.tokens.isEmpty }
        // One common word is never rewritten on its own ("fix" for Sphinx):
        // that would be worse than the mistake.
        .filter { !($0.heard.tokens.count == 1 && isCommon($0.heard.keys[0])) }
        .sorted { $0.heard.tokens.count > $1.heard.tokens.count }
        var index = 0
        while index < words.tokens.count {
            if let pair = pairs.first(where: { words.matches($0.heard, at: index) }) {
                let heard = words.text(index, pair.heard.tokens.count)
                words.replace(index, pair.heard.tokens.count, with: pair.written)
                changes.append(Change(heard: heard, written: pair.written))
                index += 1
            } else {
                index += 1
            }
        }
        fuzzy(&words, &changes, lexicon: lexicon, isCommon: isCommon)
        // Casing: a single-word written form that is not an everyday word
        // takes its own casing ("stakwork" → "Stakwork"; "peel" stays).
        // Only words taught to dictation (a Lingo, or anything with a
        // mishearing): a name the agent stored in its own casing ("github")
        // must not undo how the user says it.
        let cased = Dictionary(
            lexicon.entries.filter { !$0.dictationOff && ($0.type == "Lingo" || !$0.heard.isEmpty) }.flatMap(\.written)
                .filter { !$0.contains(" ") }.map { ($0.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for i in words.tokens.indices {
            let key = words.keys[i]
            guard let form = cased[key], !isCommon(key), words.core(i) != form else { continue }
            changes.append(Change(heard: words.core(i), written: form))
            words.replace(i, 1, with: form)
        }
        return (words.joined, changes)
    }

    /// Dictation spells a name a new way each time ("Stockwork", "stackwork",
    /// "stock work"): one word, or two, put right when its letters, spaces
    /// and case aside, are a known form's, or for a long word nearly so (a
    /// quarter of its letters off at most). Only words taught to dictation,
    /// and never an everyday word on its own.
    private static func fuzzy(_ words: inout Words, _ changes: inout [Change], lexicon: LingoLexicon, isCommon: IsCommonWord) {
        let taught = lexicon.entries.filter { !$0.dictationOff && ($0.type == "Lingo" || !$0.heard.isEmpty) }
        // Each form's letters, and the word it stands for.
        var exact: [String: String] = [:]
        var near: [(letters: String, written: String)] = []
        for entry in taught {
            for written in entry.written {
                let letters = LingoClassifier.letters(written)
                exact[letters] = exact[letters] ?? written
                if letters.count >= 6 { near.append((letters, written)) }
            }
            for heard in entry.heard {
                let letters = LingoClassifier.letters(heard.value)
                exact[letters] = exact[letters] ?? (heard.form ?? entry.name)
            }
        }
        guard !exact.isEmpty else { return }
        var index = 0
        while index < words.tokens.count {
            for count in [2, 1] where index + count <= words.tokens.count {
                // Not across punctuation: "a stack. Work" stays.
                guard words.contiguous(index, count) else { continue }
                let keys = Array(words.keys[index..<index + count])
                if count == 1, isCommon(keys[0]) { continue }
                let letters = keys.joined()
                // Two words only as a known form exactly ("stock work"); one
                // long word also when nearly so ("Stockwork").
                let written = exact[letters] ?? (count == 1 && letters.count >= 6
                    ? near.first { LingoClassifier.distance(letters, $0.letters) * 4 <= max(letters.count, $0.letters.count) }?.written
                    : nil)
                guard let written, words.text(index, count) != written else { continue }
                changes.append(Change(heard: words.text(index, count), written: written))
                words.replace(index, count, with: written)
                break
            }
            index += 1
        }
    }
}

// MARK: - Learning from an edit

/// What one edit of the text Peel typed means (docs/dictation-lingo.md,
/// "Classifying"): a mishearing to learn, or something to leave alone.
public enum LingoLesson: Equatable, Sendable {
    /// Dictation wrote `heard` for `written`, which the user would never
    /// write themselves: learn it.
    case misheard(heard: String, written: String)
    /// An everyday swap, a style change, an alias swap, a changed mind, a
    /// cut: nothing to learn.
    case nothing
}

public enum LingoClassifier {
    /// More than this many words on either side is a rewrite, not a correction.
    static let maxHunk = 4

    /// The lessons in turning `typed` into `edited`; empty when the edit is
    /// a rewrite rather than corrections.
    public static func lessons(
        typed: String, edited: String, lexicon: LingoLexicon, isCommon: @escaping IsCommonWord
    ) -> [LingoLesson] {
        let a = Words(typed), b = Words(edited)
        // Compared as written, so a casing fix ("stakwork" → "Stakwork") is a change.
        let hunks = diff(a.tokens.indices.map(a.core), b.tokens.indices.map(b.core))
        // Each run counts by its shorter side: "k p i" → "KPI" is one change, not three.
        let changed = hunks.reduce(0) { $0 + min(max($1.a.count, 1), max($1.b.count, 1)) }
        // A short dictation may change by half or more ("stakwork" → "Stakwork").
        guard !hunks.isEmpty, changed * 2 <= a.keys.count || a.keys.count <= 3,
              hunks.allSatisfy({ $0.a.count <= maxHunk && $0.b.count <= maxHunk }) else { return [] }
        return hunks.map { hunk in
            let from = hunk.a.map { a.core($0) }.joined(separator: " ")
            let to = hunk.b.map { b.core($0) }.joined(separator: " ")
            return lesson(from: from, to: to, lexicon: lexicon, isCommon: isCommon)
        }
    }

    /// One hunk: dictation's `from`, the user's `to`.
    static func lesson(from: String, to: String, lexicon: LingoLexicon, isCommon: IsCommonWord) -> LingoLesson {
        // A cut or an addition teaches nothing.
        guard !from.isEmpty, !to.isEmpty else { return .nothing }
        let fromWords = Words(from), toWords = Words(to)
        // Both everyday words: "their" → "there".
        if fromWords.keys.allSatisfy(isCommon) && toWords.keys.allSatisfy(isCommon) && from.lowercased() != to.lowercased() {
            return .nothing
        }
        // Two correct ways to write one thing: "BTC" → "Bitcoin".
        if let entry = lexicon.entry(writing: from), entry == lexicon.entry(writing: to) { return .nothing }
        // A word the user turned off for dictation is left alone.
        if lexicon.entry(writing: to)?.dictationOff == true { return .nothing }
        guard lingoShaped(to, lexicon: lexicon, isCommon: isCommon) else { return .nothing }
        // Same letters, other casing: "stakwork" → "Stakwork". Not an everyday
        // word or a letter capitalised ("i" → "I", "so" → "So", "apple" → "Apple").
        let sameLetters = letters(from) == letters(to)
        if sameLetters, fromWords.tokens.count == toWords.tokens.count,
           fromWords.keys.allSatisfy({ isCommon($0) || $0.count == 1 }) { return .nothing }
        guard sameLetters || soundsLike(from, to) else { return .nothing }
        // Dictation wrote something the user could mean: never rewrite it.
        // Dictation wrote something the user could mean ("PH" for P8):
        // learning it would rewrite real uses of it.
        if !sameLetters, plausible(from, lexicon: lexicon, isCommon: isCommon) { return .nothing }
        if lexicon.wasUndone(from, to) { return .nothing }
        return .misheard(heard: from, written: to)
    }

    /// Something the user might write on purpose: one everyday word, an
    /// acronym or other word-like token ("PH", "2FA", "iOS"), or a word
    /// already in the vocabulary.
    static func plausible(_ text: String, lexicon: LingoLexicon, isCommon: IsCommonWord) -> Bool {
        let words = Words(text)
        if lexicon.entry(writing: text) != nil { return true }
        guard words.tokens.count == 1 else { return false }
        let word = words.core(0)
        return isCommon(words.keys[0]) || wordLike(word)
    }

    /// Looks like a name or a term: not an everyday word, or cased, or
    /// carrying digits; or already in the vocabulary.
    static func lingoShaped(_ text: String, lexicon: LingoLexicon, isCommon: IsCommonWord) -> Bool {
        if lexicon.entry(writing: text) != nil { return true }
        let words = Words(text)
        return words.keys.contains { !isCommon($0) }
            || text.contains(where: \.isUppercase) || text.contains(where: \.isNumber)
    }

    /// An acronym, a mixed-case word or letters with digits: two or more
    /// characters, all capitals, a capital inside, or a digit.
    static func wordLike(_ word: String) -> Bool {
        let core = word.filter { $0.isLetter || $0.isNumber }
        guard core.count >= 2 else { return false }
        let hasDigit = core.contains(where: \.isNumber)
        let capitals = core.filter(\.isUppercase).count
        return hasDigit || capitals >= 2 || core.dropFirst().contains(where: \.isUppercase)
    }

    // MARK: Sounding alike

    /// Whether `a` and `b` say the same thing: one word split into several or
    /// several run into one, near enough letter for letter ("stack work" /
    /// "Stakwork", "l sat" / "LSAT"); a long word misspelt ("Stackwork" /
    /// "Stakwork"); or the same sounds spelled out ("p eight" / "P8"). Not a
    /// short word swapped for one like it ("Jon" / "Jen", "Sarah" / "Sara"):
    /// that is the user choosing a different name.
    static func soundsLike(_ a: String, _ b: String) -> Bool {
        let la = letters(a), lb = letters(b)
        guard !la.isEmpty, !lb.isEmpty else { return false }
        let longest = max(la.count, lb.count)
        let splitOrJoined = Words(a).tokens.count != Words(b).tokens.count
        if splitOrJoined, distance(la, lb) * 3 <= longest { return true }
        if longest >= 6, distance(la, lb) * 4 <= longest { return true }
        let sa = spoken(a), sb = spoken(b)
        return !sa.isEmpty && sa == sb
    }

    /// Letters and digits only, lowercased.
    static func letters(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    private static let letterNames: [Character: String] = [
        "a": "ay", "b": "bee", "c": "see", "d": "dee", "e": "ee", "f": "eff", "g": "gee", "h": "aitch",
        "i": "eye", "j": "jay", "k": "kay", "l": "el", "m": "em", "n": "en", "o": "oh", "p": "pee",
        "q": "cue", "r": "ar", "s": "ess", "t": "tee", "u": "you", "v": "vee", "w": "double you",
        "x": "ex", "y": "why", "z": "zed",
    ]
    private static let digitNames: [Character: String] = [
        "0": "zero", "1": "one", "2": "two", "3": "three", "4": "four", "5": "five", "6": "six", "7": "seven",
        "8": "eight", "9": "nine",
    ]
    private static let spokenWords: [String: String] = [
        "to": "two", "too": "two", "for": "four", "won": "one", "ate": "eight", "oh": "zero",
    ]

    /// How it is said, sound by sound: digits and lone letters by name,
    /// a short all-capital or letter-and-digit token letter by letter.
    static func spoken(_ text: String) -> [String] {
        Words(text).tokens.flatMap { token -> [String] in
            let core = token.filter { $0.isLetter || $0.isNumber }
            guard !core.isEmpty else { return [] }
            let spellOut = core.count == 1 || core.contains(where: \.isNumber)
                || (core.count <= 5 && core.allSatisfy { $0.isUppercase || $0.isNumber })
            if spellOut {
                return core.lowercased().map { digitNames[$0] ?? letterNames[$0] ?? String($0) }
            }
            let word = core.lowercased()
            return [spokenWords[word] ?? word]
        }
    }

    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var row = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var previous = row[0]
            row[0] = i
            for j in stride(from: 1, through: b.count, by: 1) {
                let current = row[j]
                row[j] = a[i - 1] == b[j - 1] ? previous : min(previous, row[j], row[j - 1]) + 1
                previous = current
            }
        }
        return a.isEmpty ? b.count : row[b.count]
    }

    // MARK: Diffing

    struct Hunk: Equatable {
        var a: [Int]
        var b: [Int]
    }

    /// Word-level differences, as runs of replaced, cut or added words.
    static func diff(_ a: [String], _ b: [String]) -> [Hunk] {
        var lcs = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var hunks: [Hunk] = []
        var current = Hunk(a: [], b: [])
        var i = 0, j = 0
        func close() {
            if !current.a.isEmpty || !current.b.isEmpty { hunks.append(current) }
            current = Hunk(a: [], b: [])
        }
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] {
                close()
                i += 1
                j += 1
            } else if j < b.count, i == a.count || lcs[i][j + 1] >= lcs[i + 1][j] {
                current.b.append(j)
                j += 1
            } else {
                current.a.append(i)
                i += 1
            }
        }
        close()
        return hunks
    }
}

/// Text as words: each token with what surrounds it kept, so a rewrite
/// leaves the punctuation and spacing as they were.
struct Words {
    /// Whitespace-separated tokens, punctuation attached.
    private(set) var tokens: [String]
    private var separators: [String]
    /// Each token's core, lowercased: what is compared. Kept with `tokens`.
    private(set) var keys: [String] = []

    init(_ text: String) {
        var tokens: [String] = []
        var separators: [String] = [""]
        var token = ""
        for character in text {
            if character.isWhitespace {
                if !token.isEmpty {
                    tokens.append(token)
                    token = ""
                    separators.append("")
                }
                separators[separators.count - 1].append(character)
            } else {
                token.append(character)
            }
        }
        if !token.isEmpty {
            tokens.append(token)
            separators.append("")
        }
        self.tokens = tokens
        self.separators = separators
        keys = tokens.map { Self.split($0).core.lowercased() }
    }

    /// A token without the punctuation around it.
    func core(_ i: Int) -> String {
        Self.split(tokens[i]).core
    }

    /// Each token's core, lowercased: what is compared.

    var joined: String {
        var out = separators[0]
        for (i, token) in tokens.enumerated() { out += token + separators[i + 1] }
        return out
    }

    func text(_ start: Int, _ count: Int) -> String {
        (start..<start + count).map(core).joined(separator: " ")
    }

    /// Whether `count` tokens from `start` run on without punctuation between them.
    func contiguous(_ start: Int, _ count: Int) -> Bool {
        let end = start + count - 1
        return (start..<end).allSatisfy { Self.split(tokens[$0]).trail.isEmpty }
            && (start..<end).allSatisfy { Self.split(tokens[$0 + 1]).lead.isEmpty }
    }

    /// `other`'s words at `start`, not across a sentence's or a clause's
    /// punctuation ("a stack. Work" is not "stack work").
    func matches(_ other: Words, at start: Int) -> Bool {
        let theirs = other.keys
        guard start + theirs.count <= keys.count else { return false }
        return Array(keys[start..<start + theirs.count]) == theirs && contiguous(start, theirs.count)
    }

    /// Replaces `count` tokens from `start` with `text`, keeping the first
    /// token's leading and the last token's trailing punctuation.
    mutating func replace(_ start: Int, _ count: Int, with text: String) {
        let lead = Self.split(tokens[start]).lead
        let trail = Self.split(tokens[start + count - 1]).trail
        tokens.replaceSubrange(start..<start + count, with: [lead + text + trail])
        separators.removeSubrange(start + 1..<start + count)
        keys.replaceSubrange(start..<start + count, with: [Self.split(text).core.lowercased()])
    }

    private static func split(_ token: String) -> (lead: String, core: String, trail: String) {
        let isPart: (Character) -> Bool = { $0.isLetter || $0.isNumber }
        guard let first = token.firstIndex(where: isPart), let last = token.lastIndex(where: isPart) else {
            return (token, "", "")
        }
        return (String(token[..<first]), String(token[first...last]), String(token[token.index(after: last)...]))
    }
}

// MARK: - Strut's memory steps (stakwork/strut#297)

extension LingoLexicon {
    /// `memory/lexicon`'s output: `{ entities: [...], undone: [...] }`.
    public init(lexicon output: AgentKit.JSONValue) {
        let entries = (output["entities"]?.array ?? []).compactMap { entity -> Entry? in
            guard let id = entity["ref_id"]?.string, let name = entity["name"]?.string else { return nil }
            let heard = (entity["heard"]?.array ?? []).compactMap { heard -> Heard? in
                guard let id = heard["ref_id"]?.string, let value = heard["value"]?.string else { return nil }
                return Heard(refID: id, value: value, form: heard["form"]?.string)
            }
            return Entry(
                refID: id, type: entity["type"]?.string ?? "", name: name,
                written: entity["written"]?.array?.compactMap(\.string) ?? [name], heard: heard,
                dictationOff: entity["dictation_off"] == .bool(true)
            )
        }
        let undone = (output["undone"]?.array ?? []).compactMap { pair -> Undone? in
            guard let value = pair["value"]?.string else { return nil }
            guard let written = pair["form"]?.string ?? pair["entity"]?["name"]?.string else { return nil }
            return Undone(value: value, written: written)
        }
        self.init(entries: entries, undone: undone)
    }
}

/// The memory steps' inputs for dictation's writes, and what a learn wrote
/// (for its Undo).
public enum LingoWrites {
    /// `memory/remember`: `heard` is how dictation mishears `written`, on the
    /// entity that writes it, or on a new `Lingo` when none does. Only the
    /// pair is said, never the sentence it was in.
    /// Whether `heard` alone would ever be applied: one everyday word is not.
    public static func applies(heard: String, isCommon: IsCommonWord) -> Bool {
        let words = Words(heard)
        return !words.keys.isEmpty && !(words.keys.count == 1 && isCommon(words.keys[0]))
    }

    public static func learn(heard: String, written: String, in lexicon: LingoLexicon) -> AgentKit.JSONValue {
        var subject: [String: AgentKit.JSONValue] = ["type": "Lingo", "name": .string(written)]
        var form: String?
        if let entry = lexicon.entry(writing: written) {
            subject = ["ref_id": .string(entry.refID), "type": .string(entry.type), "name": .string(entry.name)]
            if entry.name != written { form = written }
        }
        var fact: [String: AgentKit.JSONValue] = [
            "subject": .object(subject),
            "predicate": "heard_as",
            "text": .string("Dictation hears \(written) as “\(heard)”."),
            "value": .string(heard),
        ]
        if let form { fact["form"] = .string(form) }
        return [
            "episode": .string("Dictation: corrected “\(heard)” to “\(written)”."),
            "kind": "note",
            "created_by": "dictation",
            "facts": [.object(fact)],
        ]
    }

    /// What a learn wrote, to forget on Undo: the new entity when one was
    /// made (its facts go with it), else the new fact; nothing when strut
    /// already had it.
    public static func undoIDs(of output: AgentKit.JSONValue) -> [String] {
        let created = (output["entities"]?.array ?? []).filter { $0["status"]?.string == "created" }.compactMap { $0["ref_id"]?.string }
        if !created.isEmpty { return created }
        return (output["facts"]?.array ?? []).filter { $0["status"]?.string == "created" }.compactMap { $0["ref_id"]?.string }
    }

    /// `memory/forget` of what a learn wrote, so it is never learned again.
    public static func undo(_ refID: String) -> AgentKit.JSONValue {
        ["ref_id": .string(refID), "reason": "undone"]
    }

    /// `memory/forget` of a mishearing removed in the Vocabulary.
    public static func remove(_ refID: String) -> AgentKit.JSONValue {
        ["ref_id": .string(refID), "reason": "removed"]
    }

    /// `memory/attributes`: dictation off for an entity, or back on.
    public static func dictation(_ refID: String, on: Bool) -> AgentKit.JSONValue {
        ["ref_id": .string(refID), "set": ["dictation": on ? .null : "off"]]
    }
}
