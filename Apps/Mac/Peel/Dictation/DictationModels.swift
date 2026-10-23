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
    /// For each kind, the model a switch replaced, until removed or kept:
    /// offered for removal once the new one is in use.
    private var replaced: [DictationModel.Kind: String] = [:]
    @ObservationIgnored private var server: MemoryServer?
    @ObservationIgnored private let log = Logger(subsystem: "dev.peel.mac", category: "dictation")

    private static let every: Duration = .seconds(1)

    /// Peel's strut, from `AppModel.strutChanged`.
    func use(_ new: MemoryServer?) {
        guard new != server else { return }
        server = new
        models = []
        problem = nil
        replaced = [:]
        if new != nil { Task { await load() } }
    }

    var downloading: Bool { models.contains { $0.state == .downloading } }

    /// What is on this Mac, in use or not.
    var installed: [DictationModel] { models.filter { $0.state == .installed } }

    /// The model a switch of `kind` left behind, to offer removing: once
    /// nothing of that kind is downloading, and only if strut lets it go.
    func leftBehind(_ kind: DictationModel.Kind) -> DictationModel? {
        guard let id = replaced[kind], !models.contains(where: { $0.kind == kind && $0.state == .downloading }) else { return nil }
        return models.first { $0.id == id && $0.state == .installed && $0.removable }
    }

    /// Keep what a switch left behind: not offered again.
    func keep(_ kind: DictationModel.Kind) { replaced[kind] = nil }

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
        noteSwitch(model.kind, to: model.id)
        await call("dictation/use", [model.kind.rawValue: .string(model.id)], couldNot: "choose \(model.name)")
    }

    /// No fixer: dictation keeps to the vocabulary alone.
    func selectNoFixer() async {
        noteSwitch(.fixer, to: nil)
        await call("dictation/use", ["fixer": .null], couldNot: "turn clean-up off")
    }

    func remove(_ model: DictationModel) async {
        if replaced[model.kind] == model.id { replaced[model.kind] = nil }
        await call("dictation/remove-model", ["id": .string(model.id)], couldNot: "remove \(model.name)")
    }

    /// The model in use for `kind` is about to be replaced by `id`.
    private func noteSwitch(_ kind: DictationModel.Kind, to id: String?) {
        guard let current = models.first(where: { $0.kind == kind && $0.active }), current.id != id else { return }
        replaced[kind] = current.id
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
