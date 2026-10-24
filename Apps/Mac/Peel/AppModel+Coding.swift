import Foundation
import PeelAgent
import PeelCore
import PeelUI

/// Account › Connections › Coding agents (docs/local-coding-agents.md): the
/// coding agents this Mac's login shell finds and the folders they may work
/// in, kept beside Peel's own strut (`CodingSetup`) and handed to it at its
/// next start. A home server's own settings decide for it.
@MainActor @Observable
final class CodingState {
    var setup = CodingSetup()
    /// Looking through the login shell now.
    var finding = false
    /// The last thing that went wrong, in words.
    var problem: String?
}

extension AppModel {
    var coding: CodingState { macAgent.coding }

    /// Read when the screen opens; the agents looked for the first time.
    func loadCoding() async {
        guard let strut, grantsConnections else { return }
        coding.setup = strut.coding
        if coding.setup.path == nil { await findCodingAgents() }
    }

    /// Looks again through the login shell, as Terminal starts it: its
    /// `PATH`, and which of Claude Code, Codex and goose it finds.
    func findCodingAgents() async {
        guard !coding.finding else { return }
        coding.finding = true
        defer { coding.finding = false }
        guard let found = await CodingAgents.find() else {
            coding.problem = "Couldn't read your login shell's PATH, so no coding agent was found."
            return
        }
        var setup = coding.setup
        (setup.path, setup.agents) = (found.path, found.agents)
        keepCoding(setup)
    }

    /// A folder chosen in an open panel, under a name of its own.
    func addCodingFolder() {
        guard let folder = platform.files.open(prompt: "Allow", multiple: false, directories: true, types: [])?.first else { return }
        var setup = coding.setup
        guard !setup.folders.values.contains(folder.path) else { return }
        setup.folders[setup.name(for: folder)] = folder.path
        keepCoding(setup)
    }

    func removeCodingFolder(_ name: String) {
        var setup = coding.setup
        setup.folders[name] = nil
        keepCoding(setup)
    }

    /// Kept, then strut started again so its next jobs have it.
    private func keepCoding(_ setup: CodingSetup) {
        guard let strut else { return }
        do {
            if setup != strut.coding { try strut.keep(setup) }
            coding.setup = setup
            coding.problem = nil
            if strut.launchedStale { restartOwnStrut() }
        } catch {
            coding.problem = PeelError.problem(error, couldNot: "keep the coding agents' folders")
        }
    }
}
