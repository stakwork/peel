import AgentKit
import Observation
import os
import PeelAgent
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
    @ObservationIgnored private var server: MemoryServer?
    @ObservationIgnored private let log = Logger(subsystem: "dev.peel.mac", category: "dictation")

    /// Peel's strut, from `AppModel.strutChanged`.
    func use(_ new: MemoryServer?) {
        guard new != server else { return }
        server = new
        lexicon = .empty
        problem = nil
        Task { await refresh() }
    }

    /// The vocabulary, for the Vocabulary window.
    func refresh() async {
        guard let server else { return }
        do {
            let read = LingoLexicon(lexicon: try await server.run("lexicon", [:]))
            // Not if another strut (another account) took this one's place meanwhile.
            guard server == self.server else { return }
            lexicon = read
            problem = nil
        } catch {
            guard server == self.server else { return }
            problem = "Your vocabulary couldn't be read from Peel's strut"
            log.error("lexicon not read: \(String(describing: error))")
        }
    }

    /// Strut learns what it can from the user's edit of `typed`: once per
    /// edit, when it has settled, as strut runs a model on it.
    func correct(typed: String, edited: String) async throws -> [LingoLearned] {
        let output = try await call("dictation/correction", ["typed": .string(typed), "edited": .string(edited)])
        await refresh()
        return LingoLearned.list(from: output)
    }

    /// Undo of a learn: never learned again.
    func undo(_ ids: [String]) async {
        do { _ = try await call("dictation/undo", ["undo": .array(ids.map(AgentKit.JSONValue.string))]) } catch {
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

    func setDictation(_ entry: LingoLexicon.Entry, on: Bool) async throws {
        _ = try await server?.run("attributes", ["ref_id": .string(entry.refID), "set": ["dictation": on ? .null : "off"]])
        await refresh()
    }

    private func call(_ step: String, _ input: AgentKit.JSONValue) async throws -> AgentKit.JSONValue {
        guard let server else { throw StrutSpeech.Failure.unreachable }
        return try await server.run(step: step, input)
    }
}
