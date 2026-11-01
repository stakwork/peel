import Foundation
import AgentKit
import PeelAgent
import PeelCore
import PeelUI

/// "What it learned" on the Mac (docs/learned.md): the person's own graph on
/// Peel's own strut, checked when the screen opens (a dry run: nothing is
/// written), and written only when the person approves. The only place the
/// app builds a `LearnedService`, always from the `MemoryServer` of Peel's own
/// strut; nothing here reaches Hive or a workspace.
@MainActor @Observable
final class LearnedModel {
    enum Phase: Equatable {
        case idle, checking, ready
        /// Said in words for the person.
        case unavailable(String)
    }

    private(set) var phase = Phase.idle
    private(set) var report = LearnedReport()
    private(set) var causes: [PersonalCause] = []
    private(set) var concepts: [PersonalConcept] = []
    /// The last answer's failure, in words.
    private(set) var problem: String?
    /// What is being written now, by id.
    private(set) var working: Set<String> = []
    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored private var checking: Task<Void, Never>?

    // MARK: Corrections seen as they happen

    private var log: LearnedSignalLog? {
        model?.profile.map { LearnedSignalLog(url: $0.directory.appending(path: "learned-signals.jsonl")) }
    }

    /// A card in the assistant's DM answered No.
    func noteRejected(request: DeviceRequest, intent: ToolIntent) {
        log?.append(LearnedDetector.rejected(request: request.id, action: intent.action, content: intent.content, at: .now))
    }

    /// Dictated text the person fixed by hand.
    func noteDictation(typed: String, edited: String) {
        log?.append(LearnedDetector.dictated(typed: typed, edited: edited, at: .now))
    }

    // MARK: The screen

    /// The assistant DM's turns, newest 200: the person's side and the assistant's, no other chat.
    private func dmTurns() async -> [DMTurn] {
        guard let model, let storage = model.unlockedStorage, let chat = model.agentChat else { return [] }
        do {
            for try await timeline in storage.timeline(in: chat, limit: 200) {
                return timeline.messages.compactMap { message in
                    guard message.type == MessageType.text, !message.deleted, let uuid = message.uuid,
                          let text = message.content, !text.isEmpty else { return nil }
                    return DMTurn(id: uuid, fromPerson: message.fromMe, text: text, at: message.date)
                }
            }
        } catch {}
        return []
    }

    private func service() -> LearnedService? {
        guard let model, let server = model.memoryServer, let profile = model.profile else { return nil }
        let data = BundledStrut.dataFolder(for: profile)
        let log = log
        return LearnedService(server: server, signals: { [weak self] in
            let turns = await self?.dmTurns() ?? []
            return (log?.all() ?? []) + LearnedDetector.followUps(in: turns)
        }, changed: { line in LearnedInstructions.write(line, in: data) })
    }

    /// The check, run when the screen opens: a dry run, then what is kept.
    func open() {
        checking?.cancel()
        checking = Task { await check() }
    }

    func check() async {
        guard let service = service() else {
            phase = .unavailable("Your assistant is not running on this Mac yet.")
            return
        }
        phase = .checking
        problem = nil
        do {
            // Kept first, so the screen shows it while the check goes on.
            causes = try await service.causes()
            concepts = try await service.concepts()
            report = try await service.check()
            phase = .ready
        } catch is CancellationError {
            return
        } catch {
            phase = .unavailable(PeelError.problem(error, couldNot: "check what it learned"))
        }
    }

    /// One answer: written, then the check again so what is kept and what waits are both current.
    func answer(_ id: String, _ action: @escaping @Sendable (LearnedService) async throws -> Void) {
        guard let service = service(), !working.contains(id) else { return }
        working.insert(id)
        Task {
            do { try await action(service); problem = nil } catch { problem = PeelError.problem(error, couldNot: "save that") }
            working.remove(id)
            await check()
        }
    }

    /// Cards for each theme: the theme, its examples, and the concept that answers it.
    var themes: [Theme] {
        let parents = causes.filter { $0.status == .active && $0.evidence.isEmpty }
        return parents.map { parent in
            Theme(parent: parent, children: causes.filter { $0.parent == parent.id && $0.status == .active },
                  concept: concepts.first { $0.cause == parent.id })
        }
    }

    /// Kept habits under no theme.
    var loose: [PersonalCause] { causes.filter { $0.status == .active && !$0.evidence.isEmpty && $0.parent == nil } }

    struct Theme: Identifiable {
        var parent: PersonalCause
        var children: [PersonalCause]
        var concept: PersonalConcept?
        var id: String { parent.id }
    }
}
