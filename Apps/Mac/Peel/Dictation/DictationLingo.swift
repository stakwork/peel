import AgentKit
import Observation
import os
import PeelAgent
import PeelCore
import PeelUI

/// Dictation's vocabulary on the Mac: a thin client of Peel's own strut,
/// which does all the judging (stakwork/strut#301; strut's
/// `plans/native-dictation-client.md` §7a). `/audio/transcribe` already
/// returns the corrected text; this sends what the user did to it
/// (`dictation/correction`), undoes a learn (`dictation/undo`), and reads
/// and edits the vocabulary for the Vocabulary window.
@MainActor @Observable
final class DictationLingo {
    private(set) var lexicon = LingoLexicon.empty
    /// Why the vocabulary could not be read; nil once it has been.
    private(set) var problem: String?
    /// Peel's strut. The edit watch takes it as it starts, so a learn and
    /// its Undo go to the strut that was there when the text was typed.
    @ObservationIgnored private(set) var server: MemoryServer?
    /// Whether the account is unlocked: the vocabulary is neither read nor
    /// kept while it is locked (`DictationController` gives it).
    @ObservationIgnored var isUnlocked: () -> Bool = { false }
    @ObservationIgnored private let log = Logger(subsystem: "dev.peel.mac", category: "dictation")

    /// Peel's strut, from `AppModel.strutChanged`.
    func use(_ new: MemoryServer?) {
        guard new != server else { return }
        server = new
        lexicon = .empty
        problem = nil
        Task { await refresh() }
    }

    /// The account locked: what was read of the vocabulary goes with it.
    func lock() {
        lexicon = .empty
        problem = nil
    }

    /// The vocabulary, for the Vocabulary window and the counts in Settings.
    func refresh() async {
        guard let server, isUnlocked() else { return }
        do {
            let read = LingoLexicon(lexicon: try await server.run("lexicon", [:]))
            // Not if another strut (another account) took this one's place, or the account locked, meanwhile.
            guard server == self.server, isUnlocked() else { return }
            lexicon = read
            problem = nil
        } catch {
            guard server == self.server, isUnlocked() else { return }
            problem = PeelError.problem(error, couldNot: "read your vocabulary from Peel's strut")
            log.error("lexicon not read: \(String(describing: error))")
        }
    }

    /// Strut learns what it can from the user's edit of `typed`, on the
    /// strut `server` the text was typed with: once per edit, when it has
    /// settled, as strut runs a model on it. Returns as soon as strut
    /// answers; the vocabulary is read again after, and only when it grew.
    func correct(typed: String, edited: String, on server: MemoryServer) async throws -> [LingoLearned] {
        let output = try await server.run(step: "dictation/correction", ["typed": .string(typed), "edited": .string(edited)])
        let learned = LingoLearned.list(from: output)
        if learned.contains(where: { !$0.undo.isEmpty }) { Task { await refresh() } }
        return learned
    }

    /// Undo of a learn, on the strut that learned it: never learned again.
    func undo(_ ids: [String], on server: MemoryServer) async {
        do { _ = try await server.run(step: "dictation/undo", ["undo": .array(ids.map(AgentKit.JSONValue.string))]) } catch {
            log.error("lingo undo failed: \(String(describing: error))")
        }
        await refresh()
    }

    /// The Vocabulary's Add: dictation writes `heard` where the user means `written`.
    func add(written: String, heard: String) async throws {
        _ = try await call("dictation/add", ["written": .string(written), "heard": .string(heard)])
        await refresh()
    }

    /// A mishearing, or a taught word (with what is known of it).
    func remove(_ refID: String) async throws {
        _ = try await call("dictation/remove", ["ref_id": .string(refID)])
        await refresh()
    }

    /// Whether dictation puts this word right or leaves it alone.
    func setDictation(_ entry: LingoLexicon.Entry, on: Bool) async throws {
        _ = try await call("dictation/enable", ["ref_id": .string(entry.refID), "on": .bool(on)])
        await refresh()
    }

    private func call(_ step: String, _ input: AgentKit.JSONValue) async throws -> AgentKit.JSONValue {
        guard let server else { throw StrutSpeech.Failure.unreachable }
        return try await server.run(step: step, input)
    }
}
