import Foundation
import PeelCore

/// Account › Connections › Coding agents (docs/local-coding-agents.md): the
/// folders a local coding agent may work in, by a short name, and what this
/// Mac's login shell found, kept beside strut's data and read into the host
/// delta at each start (`job.folders`, `job.path`, Peel's section). A job
/// names a folder, never a path, and works in a worktree of it on a branch of
/// its own (strut's `job/start { agent, mode, folder }`).
public struct CodingSetup: Codable, Sendable, Equatable {
    /// Name → absolute path.
    public var folders: [String: String] = [:]
    /// The login shell's `PATH`, where `npx` and the agents live: a GUI
    /// app's strut has none of them. Nil until looked for.
    public var path: String?
    /// The agents found there, by strut's preset name (`claude`, `codex`, `goose`).
    public var agents: [String] = []

    public init(folders: [String: String] = [:], path: String? = nil, agents: [String] = []) {
        (self.folders, self.path, self.agents) = (folders, path, agents)
    }

    /// Folders to work in and an agent to work in them: what the agent is told of.
    public var usable: Bool { !folders.isEmpty && !agents.isEmpty }

    /// A name for `folder` no other folder has: its last component, as strut
    /// takes names (letters, digits, `.`, `_`, `-`), numbered when taken.
    public func name(for folder: URL) -> String {
        let base = String(folder.lastPathComponent.lowercased()
            .map { $0.isLetter || $0.isNumber || "._-".contains($0) ? $0 : "-" })
            .trimmingCharacters(in: CharacterSet(charactersIn: "-._"))
        let stem = base.isEmpty ? "folder" : String(base.prefix(48))
        var name = stem, n = 2
        while folders[name] != nil && folders[name] != folder.path { name = "\(stem)-\(n)"; n += 1 }
        return name
    }

    static func read(in folder: URL) -> CodingSetup {
        (try? Data(contentsOf: folder.appending(path: file))).flatMap { try? JSONDecoder().decode(CodingSetup.self, from: $0) } ?? CodingSetup()
    }

    func write(in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: folder.appending(path: Self.file), options: .atomic)
    }

    static let file = "coding.json"
}

/// The coding agents Peel offers, by strut's preset name, and what each
/// needs on the login shell's `PATH`.
public enum CodingAgents {
    public struct Agent: Sendable, Equatable, Identifiable {
        public let id: String
        public let title: String
        /// Commands that must be found: the ACP adapter's launcher, and the
        /// agent itself (signed in through it).
        let needs: [String]
    }

    public static let all = [
        Agent(id: "claude", title: "Claude Code", needs: ["npx", "claude"]),
        Agent(id: "codex", title: "Codex", needs: ["npx", "codex"]),
        Agent(id: "goose", title: "goose", needs: ["goose"]),
    ]

    public static func title(_ id: String) -> String { all.first { $0.id == id }?.title ?? id }

    /// The login shell's `PATH` and the agents whose commands it finds. The
    /// person's own shell (`SHELL`, else zsh) as Terminal starts it, so its
    /// profile sets the `PATH`; nothing else of it is kept. Nil when the
    /// shell does not answer within 15 seconds.
    public static func find() async -> (path: String, agents: [String])? {
        let commands = Set(all.flatMap(\.needs)).sorted()
        let script = #"printf 'PATH=%s\n' "$PATH"; for c in "$@"; do command -v "$c" >/dev/null 2>&1 && printf 'HAS=%s\n' "$c"; done"#
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/bin/zsh"
        guard let output = await run(shell, ["-l", "-c", script, "peel"] + commands, seconds: 15) else { return nil }
        return parse(output)
    }

    /// The script's answer: its last `PATH=` line (a profile may print
    /// before it), absolute folders only, and the agents all of whose
    /// commands it found (`HAS=` lines).
    static func parse(_ output: String) -> (path: String, agents: [String])? {
        let lines = output.split(separator: "\n").map(String.init)
        guard let path = lines.last(where: { $0.hasPrefix("PATH=") }).map({ String($0.dropFirst(5)) }), !path.isEmpty,
              path.split(separator: ":").allSatisfy({ $0.hasPrefix("/") }) else { return nil }
        let found = Set(lines.filter { $0.hasPrefix("HAS=") }.map { String($0.dropFirst(4)) })
        return (path, all.filter { $0.needs.allSatisfy(found.contains) }.map(\.id))
    }

    /// Its standard output, off the main actor; nil when it fails or outlasts `seconds` (as `BundledStrut.render`).
    private static func run(_ executable: String, _ arguments: [String], seconds: Double) async -> String? {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(filePath: executable)
            process.arguments = arguments
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: timer)
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            timer.cancel()
            return process.terminationStatus == 0 ? text : nil
        }.value
    }
}
