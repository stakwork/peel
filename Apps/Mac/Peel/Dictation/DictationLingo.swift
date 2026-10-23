import AgentKit
import AppKit
import Observation
import os
import PeelAgent
import PeelCore
import PeelUI

/// Dictation's vocabulary on the Mac (docs/dictation-lingo.md): the user's
/// words and how dictation mishears them, read from Peel's own strut
/// (`memory/lexicon`, stakwork/strut#297) and kept in memory for the rewrite;
/// learning, Undo and the Vocabulary window write through strut's memory
/// steps. Refreshed when the strut starts or changes, and after each write.
@MainActor @Observable
final class DictationLingo {
    private(set) var lexicon = LingoLexicon.empty
    /// Why the vocabulary could not be read; nil once it has been.
    private(set) var problem: String?
    @ObservationIgnored private var server: MemoryServer?
    @ObservationIgnored private let log = Logger(subsystem: "dev.peel.mac", category: "dictation")

    /// An everyday word: macOS's English spell checker knows it (and the
    /// words the user taught macOS). Never rewritten on its own, never learned.
    nonisolated static let isCommon: IsCommonWord = { word in
        guard word.count > 1 else { return word == "a" || word == "i" }
        return MainActor.assumeIsolated {
            if let known = commonWords[word] { return known }
            // In the user's own spelling language, with what they taught macOS.
            let common = NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0).location == NSNotFound
            commonWords[word] = common
            return common
        }
    }
    /// What the spell checker said, per word; forgotten at each refresh.
    private static var commonWords: [String: Bool] = [:]

    /// Peel's strut, from `AppModel.strutChanged`.
    func use(_ new: MemoryServer?) {
        guard new != server else { return }
        server = new
        lexicon = .empty
        problem = nil
        Task { await refresh() }
    }

    func refresh() async {
        Self.commonWords = [:]
        guard let server else { return }
        do {
            let read = LingoLexicon(lexicon: try await server.run("lexicon", [:]))
            // Not if another strut (another account) took this one's place meanwhile.
            guard server == self.server else { return }
            lexicon = read
            problem = nil
        } catch {
            guard server == self.server else { return }
            // An older strut has no `memory/lexicon`: dictation goes on without it.
            problem = "Your vocabulary couldn't be read from Peel's strut"
            log.error("lexicon not read: \(String(describing: error))")
        }
    }

    /// Dictation's text with known mishearings and casing put right.
    func rewrite(_ text: String) -> String {
        LingoRewriter.rewrite(text, with: lexicon, isCommon: Self.isCommon).text
    }

    /// The lessons in the user's edit of what Peel typed.
    func lessons(typed: String, edited: String) -> [LingoLesson] {
        LingoClassifier.lessons(typed: typed, edited: edited, lexicon: lexicon, isCommon: Self.isCommon)
    }

    /// Writes a mishearing; what to forget on Undo (empty: strut had it).
    func learn(heard: String, written: String) async throws -> [String] {
        LingoWrites.undoIDs(of: try await write("remember", LingoWrites.learn(heard: heard, written: written, in: lexicon)))
    }

    /// Undo of a learn: forgotten with reason `undone`, so it is never learned again.
    func undo(_ ids: [String]) async {
        for id in ids {
            do { _ = try await write("forget", LingoWrites.undo(id)) } catch {
                log.error("lingo undo failed: \(String(describing: error))")
            }
        }
    }

    /// The Vocabulary's Add: dictation writes `heard` where the user means `written`.
    func add(written: String, heard: String) async throws {
        _ = try await learn(heard: heard, written: written)
    }

    /// Removes one mishearing; a Lingo left with none goes with it, so no
    /// hidden word keeps changing what is typed.
    func remove(heard: LingoLexicon.Heard, of entry: LingoLexicon.Entry) async throws {
        let last = entry.type == "Lingo" && entry.heard.count == 1
        _ = try await write("forget", LingoWrites.remove(last ? entry.refID : heard.refID))
    }

    func setDictation(_ entry: LingoLexicon.Entry, on: Bool) async throws {
        _ = try await write("attributes", LingoWrites.dictation(entry.refID, on: on))
    }

    /// One memory step on Peel's strut, then the vocabulary read again.
    private func write(_ step: String, _ input: AgentKit.JSONValue) async throws -> AgentKit.JSONValue {
        guard let server else { throw StrutSpeech.Failure.unreachable }
        let output = try await server.run(step, input)
        await refresh()
        return output
    }
}
