import Foundation
import Testing

/// Integration journeys run only when asked (`PEEL_INTEGRATION=1`), so plain
/// `swift test` stays offline and fast.
let integrationEnabled = ProcessInfo.processInfo.environment["PEEL_INTEGRATION"] == "1"

/// The local stack the journeys run against (`scripts/test-stack.sh`): the
/// one named by `PEEL_STACK_DIR` if set, else one started for this test
/// process and stopped by the script's watcher once the process exits.
actor Stack {
    static let shared = Stack()

    struct Addresses: Sendable {
        let directory: URL
        let broker: String
        /// The broker behind the wire tap, which records every byte.
        let tap: String
        let tribes: String
        let memes: String
    }

    enum MixerMode: String {
        /// `TESTING_ONLY_ADD_TO_SENDER`: senders are never debited.
        case fund
        /// Real balance accounting.
        case real
    }

    private var addresses: Addresses?
    private var mode: MixerMode?

    static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let script = repository.appendingPathComponent("scripts/test-stack.sh").path

    func current() throws -> Addresses {
        if let addresses { return addresses }
        let environment = ProcessInfo.processInfo.environment
        let settings: [String: String]
        if let directory = environment["PEEL_STACK_DIR"] {
            settings = Self.parse(try String(contentsOfFile: "\(directory)/env", encoding: .utf8))
        } else {
            settings = Self.parse(try Self.runScript(["start", "--owner-pid", "\(getpid())"]))
        }
        guard let directory = settings["PEEL_STACK_DIR"], let broker = settings["PEEL_BROKER"],
              let tap = settings["PEEL_BROKER_TAP"], let tribes = settings["PEEL_TRIBES"],
              let memes = settings["PEEL_MEMES"] else {
            throw StackError("the stack's settings are incomplete: \(settings.keys.sorted())")
        }
        let started = Addresses(
            directory: URL(fileURLWithPath: directory), broker: broker, tap: tap, tribes: tribes, memes: memes
        )
        addresses = started
        mode = settings["PEEL_MIXER_MODE"].flatMap(MixerMode.init(rawValue:))
        return started
    }

    /// Restarts the mixer in `mode` unless it already runs so.
    func setMixer(_ mode: MixerMode) throws {
        let addresses = try current()
        guard self.mode != mode else { return }
        _ = try Self.runScript(["mixer", addresses.directory.path, mode.rawValue])
        self.mode = mode
    }

    enum TapAction: String {
        /// Closes the tap's connections and refuses new ones.
        case down
        case up
        /// Stops it in place: connections stay open and carry nothing.
        case freeze
        case thaw
    }

    /// The network between the clients on the wire tap and the broker.
    func tap(_ action: TapAction) throws {
        _ = try Self.runScript(["tap", try current().directory.path, action.rawValue])
    }

    /// Everything the wire tap has carried so far, both ways.
    func wire() throws -> Data {
        try Data(contentsOf: try current().directory.appendingPathComponent("wire.bin"))
    }

    /// The files the memes stub holds, as uploaded.
    func memesUploads() throws -> [Data] {
        let folder = try current().directory.appendingPathComponent("memes/files")
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.isEmpty }
            .map { try Data(contentsOf: $0) }
    }

    private static func parse(_ text: String) -> [String: String] {
        var settings: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { settings[parts[0]] = parts[1] }
        }
        return settings
    }

    private static func runScript(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script] + arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let problem = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw StackError("test-stack.sh \(arguments.first ?? "") failed: \(problem)")
        }
        return text
    }
}

struct StackError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
