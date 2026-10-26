import Foundation

/// A crash as PLCrashReporter's report says it, in plain values: what the
/// redactor reads. Raw: it holds paths and free text, so it is stored only in
/// the private raw folder and nothing outside this module returns it.
struct CrashRecord: Codable, Sendable, Equatable {
    struct Frame: Codable, Sendable, Equatable {
        var pc: UInt64
        var imageName: String?
        var symbol: String?
        var offset: UInt64?
    }

    struct Register: Codable, Sendable, Equatable {
        var name: String
        var value: UInt64
    }

    struct Thread: Codable, Sendable, Equatable {
        var number: Int
        var crashed: Bool
        var frames: [Frame]
        var registers: [Register]
    }

    struct Image: Codable, Sendable, Equatable {
        var name: String
        var uuid: String?
        var base: UInt64
        var size: UInt64
        var arch: String?
    }

    var id: String
    var appIdentifier: String?
    var appVersion: String?
    var osVersion: String?
    var osBuild: String?
    var machineModel: String?
    var timestamp: Date?
    var signal: String?
    var signalCode: String?
    var faultAddress: UInt64?
    var machException: String?
    var exceptionName: String?
    var exceptionReason: String?
    var processName: String?
    var processPath: String?
    var threads: [Thread]
    var images: [Image]
    /// The ring as it stood when the report was found (the crashed run's end).
    var events: [DiagnosticEvent]
    /// The strut's last stderr, already redacted when it was written.
    var strutStderrTail: String?
}

/// A crash record after `Redactor`: what may be shown, copied and handed
/// to the agent (`compact()`). Structure (stacks, image UUIDs, load addresses,
/// registers) is as recorded; every free-text field is scrubbed.
public struct RedactedRecord: Codable, Sendable, Equatable {
    public struct Frame: Codable, Sendable, Equatable {
        public var pc: UInt64
        public var imageName: String?
        public var symbol: String?
        public var offset: UInt64?
    }

    public struct Register: Codable, Sendable, Equatable {
        public var name: String
        public var value: UInt64
    }

    public struct Thread: Codable, Sendable, Equatable {
        public var number: Int
        public var crashed: Bool
        public var frames: [Frame]
        public var registers: [Register]
    }

    public struct Image: Codable, Sendable, Equatable {
        public var name: String
        public var uuid: String?
        public var base: UInt64
        public var size: UInt64
        public var arch: String?
    }

    public var id: String
    public var appIdentifier: String?
    public var appVersion: String?
    public var osVersion: String?
    public var osBuild: String?
    public var machineModel: String?
    public var timestamp: Date?
    public var signal: String?
    public var signalCode: String?
    public var faultAddress: UInt64?
    public var machException: String?
    public var exceptionName: String?
    public var exceptionReason: String?
    public var processName: String?
    public var processPath: String?
    public var threads: [Thread]
    public var images: [Image]
    public var events: [DiagnosticEvent]
    public var strutStderrTail: String?

    /// The record cut to what a device answer (32 KB) holds, for the agent:
    /// the exception's words shortened, the crashed thread's top frames
    /// without its registers, only the images those frames are in, and the
    /// last events.
    public func compact() -> RedactedRecord {
        var copy = self
        let crashed = threads.first(where: \.crashed) ?? threads.first
        copy.threads = crashed.map { [Thread(number: $0.number, crashed: $0.crashed, frames: Array($0.frames.prefix(25)), registers: [])] } ?? []
        let used = Set(copy.threads.flatMap(\.frames).compactMap(\.imageName))
        copy.images = images.filter { used.contains($0.name) }
        copy.events = Array(events.suffix(15))
        copy.exceptionName = exceptionName.map { String($0.prefix(200)) }
        copy.exceptionReason = exceptionReason.map { String($0.prefix(1_000)) }
        return copy
    }

    /// Apple's crash log, roughly: header, exception, threads with their
    /// frames, the crashed thread's registers, binary images, then the
    /// memory and error events leading up to it.
    public func rendered() -> String {
        var out: [String] = []
        func hex(_ value: UInt64) -> String { "0x" + String(value, radix: 16) }
        func line(_ key: String, _ value: String?) {
            if let value, !value.isEmpty { out.append("\(key): \(value)") }
        }
        line("Process", [processName, processPath.map { "[\($0)]" }].compactMap { $0 }.joined(separator: " "))
        line("Identifier", appIdentifier)
        line("Version", appVersion)
        line("Hardware Model", machineModel)
        line("OS Version", [osVersion, osBuild.map { "(\($0))" }].compactMap { $0 }.joined(separator: " "))
        line("Date/Time", timestamp.map { ISO8601DateFormatter().string(from: $0) })
        line("Report ID", id)
        out.append("")
        line("Exception Type", machException)
        line("Signal", [signal, signalCode].compactMap { $0 }.joined(separator: " "))
        line("Fault Address", faultAddress.map(hex))
        line("Exception Name", exceptionName)
        line("Exception Reason", exceptionReason)
        for thread in threads {
            out.append("")
            out.append("Thread \(thread.number)\(thread.crashed ? " Crashed" : ""):")
            for (index, frame) in thread.frames.enumerated() {
                var text = "\(index)  \(frame.imageName ?? "???")  \(hex(frame.pc))"
                if let symbol = frame.symbol {
                    text += " \(symbol)" + (frame.offset.map { " + \($0)" } ?? "")
                }
                out.append(text)
            }
            if thread.crashed, !thread.registers.isEmpty {
                out.append("")
                out.append("Thread \(thread.number) crashed with registers:")
                out.append(thread.registers.map { "\($0.name): \(hex($0.value))" }.joined(separator: "  "))
            }
        }
        if !images.isEmpty {
            out.append("")
            out.append("Binary Images:")
            for image in images {
                out.append("\(hex(image.base)) - \(hex(image.base &+ max(image.size, 1) &- 1)) \(image.name) "
                    + "\(image.arch ?? "") <\(image.uuid ?? "no uuid")>")
            }
        }
        if !events.isEmpty {
            out.append("")
            out.append("Recent events (newest last):")
            for event in events.suffix(40) { out.append(event.line) }
        }
        if let tail = strutStderrTail, !tail.isEmpty {
            out.append("")
            out.append("Strut's last stderr (redacted):")
            out.append(tail)
        }
        return out.joined(separator: "\n") + "\n"
    }
}

extension DiagnosticEvent {
    /// One line for a record: when, what and the numbers, in enum names.
    var line: String {
        var parts = [ISO8601DateFormatter().string(from: timestamp), kind.rawValue]
        if let value = errorKind { parts.append("error=\(value.rawValue)") }
        if let value = lastAction { parts.append("action=\(value.rawValue)") }
        if let value = footprintBytes { parts.append("footprint=\(value / 1_048_576) MiB") }
        if let value = availableBytes { parts.append("available=\(value / 1_048_576) MiB") }
        if let value = pressureLevel { parts.append("pressure=\(value.rawValue)") }
        if let value = previousRun { parts.append("previous=\(value.rawValue)") }
        if let value = exitReason { parts.append("exit=\(value.rawValue)") }
        if let value = exitStatus { parts.append("status=\(value)") }
        if count > 1 { parts.append("x\(count)") }
        return parts.joined(separator: " ")
    }
}

extension DiagnosticsReport {
    /// What the ring holds, as text: for a run that was killed and left no crash report.
    public func rendered() -> String {
        var out = ["Previous run: \(previousRun.rawValue)"]
        if let appVersion { out.append("Version: \(appVersion)") }
        out.append("")
        out.append("Recent events (newest last):")
        out += events.suffix(60).map(\.line)
        return out.joined(separator: "\n") + "\n"
    }
}
