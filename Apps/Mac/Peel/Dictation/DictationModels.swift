import AgentKit
import Observation
import os
import PeelAgent
import PeelCore
import PeelUI

/// The models dictation runs on Peel's strut, for Account › Dictation's
/// picker: a speech model and a fixer, each picked, downloaded and removed
/// by strut (`dictation/models`, `use`, `remove-model`). Strut names and
/// describes them; Peel only shows what it says. Read again every second
/// while one downloads and the picker is on screen (`follow`).
@MainActor @Observable
final class DictationModels {
    private(set) var models: [DictationModel] = []
    /// Why the last call failed; nil once one worked.
    private(set) var problem: String?
    @ObservationIgnored private var server: MemoryServer?
    @ObservationIgnored private let log = Logger(subsystem: "dev.peel.mac", category: "dictation")

    private static let every: Duration = .seconds(1)

    /// Peel's strut, from `AppModel.strutChanged`.
    func use(_ new: MemoryServer?) {
        guard new != server else { return }
        server = new
        models = []
        problem = nil
        if new != nil { Task { await load() } }
    }

    var downloading: Bool { models.contains { $0.state == .downloading } }

    /// A fixer is running: only then does an edit teach dictation anything.
    var hasActiveFixer: Bool { models.contains { $0.kind == .fixer && $0.active } }

    func load() async {
        await call("dictation/models", [:], couldNot: "read the models from Peel's strut")
    }

    /// The picker's: reads the list, then again every second while a model
    /// downloads. Run by the view's `.task`, so it stops when the picker goes.
    func follow() async {
        await load()
        while downloading, problem == nil {
            try? await Task.sleep(for: Self.every)
            guard !Task.isCancelled else { return }
            await load()
        }
    }

    /// Picks `model` for its kind; strut downloads it first if it has to.
    func select(_ model: DictationModel) async {
        await call("dictation/use", [model.kind.rawValue: .string(model.id)], couldNot: "choose \(model.name)")
    }

    /// No fixer: dictation keeps to the vocabulary alone.
    func selectNoFixer() async {
        await call("dictation/use", ["fixer": .null], couldNot: "turn clean-up off")
    }

    func remove(_ model: DictationModel) async {
        await call("dictation/remove-model", ["id": .string(model.id)], couldNot: "remove \(model.name)")
    }

    /// Each step returns the whole list.
    private func call(_ step: String, _ input: AgentKit.JSONValue, couldNot action: String) async {
        guard let server else {
            problem = PeelError.problem("Peel's strut isn't running", couldNot: action)
            return
        }
        do {
            let list = DictationModel.list(from: try await server.run(step: step, input))
            // Not if another strut (another account) took this one's place meanwhile.
            guard server == self.server else { return }
            models = list
            problem = nil
        } catch {
            guard server == self.server else { return }
            problem = PeelError.problem(error, couldNot: action)
            log.error("\(step, privacy: .public) failed: \(String(describing: error))")
        }
    }
}
