import AgentKit
import Observation
import os
import PeelAgent
import PeelUI

/// The models dictation runs on Peel's strut, for Account › Dictation's
/// picker: a speech model and a fixer, each picked, downloaded and removed
/// by strut (`dictation/models`, `use`, `remove-model`). Read again every
/// second only while one is downloading.
@MainActor @Observable
final class DictationModels {
    private(set) var models: [DictationModel] = []
    /// Why the last call failed; nil once one worked.
    private(set) var problem: String?
    @ObservationIgnored private var server: MemoryServer?
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "dev.peel.mac", category: "dictation")

    private static let every: Duration = .seconds(1)

    /// Peel's strut, from `AppModel.strutChanged`.
    func use(_ new: MemoryServer?) {
        guard new != server else { return }
        server = new
        models = []
        problem = nil
        poll?.cancel()
        poll = nil
        if new != nil { Task { await load() } }
    }

    func load() async {
        await call("dictation/models", [:], failure: "The models couldn't be read from Peel's strut")
    }

    /// Picks `model` for its kind; strut downloads it first if it has to.
    func select(_ model: DictationModel) async {
        await call("dictation/use", [model.kind.rawValue: .string(model.id)], failure: "That model couldn't be chosen")
    }

    /// No fixer: dictation keeps to the vocabulary alone.
    func selectNoFixer() async {
        await call("dictation/use", ["fixer": .null], failure: "That couldn't be changed")
    }

    func remove(_ model: DictationModel) async {
        await call("dictation/remove-model", ["id": .string(model.id)], failure: "That model couldn't be removed")
    }

    /// Each step returns the whole list.
    private func call(_ step: String, _ input: AgentKit.JSONValue, failure: String) async {
        guard let server else {
            problem = "Peel's strut isn't running"
            return
        }
        do {
            let list = DictationModel.list(from: try await server.run(step: step, input))
            // Not if another strut (another account) took this one's place meanwhile.
            guard server == self.server else { return }
            models = list
            problem = nil
            followDownloads()
        } catch {
            guard server == self.server else { return }
            problem = failure
            log.error("\(step, privacy: .public) failed: \(String(describing: error))")
        }
    }

    private var downloading: Bool { models.contains { $0.state == .downloading } }

    /// Reads the list again every second while a model downloads, then stops.
    private func followDownloads() {
        guard downloading, poll == nil else { return }
        poll = Task { [weak self] in
            while true {
                try? await Task.sleep(for: Self.every)
                guard let self, !Task.isCancelled else { return }
                await self.load()
                // `use` cancels and replaces this poll.
                guard !Task.isCancelled else { return }
                if !self.downloading || self.problem != nil { break }
            }
            self?.poll = nil
        }
    }
}
