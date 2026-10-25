import Foundation

/// A small lock around state shared between threads.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}

/// The event ring: a bounded file of `DiagnosticEvent`s, one JSON object per
/// line, oldest first. Appends go to the end of the file; identical
/// consecutive events are counted instead of repeated; over the cap the file
/// is rewritten atomically with the newest half. A line that does not decode
/// (a write cut short, damage) is skipped, never fatal.
public final class DiagnosticsRing: Sendable {
    public static let defaultMaxBytes = 256 * 1024
    public static let defaultMaxEvents = 2000

    private struct State {
        var events: [DiagnosticEvent]
        var bytes: Int
    }

    private let url: URL
    private let maxBytes: Int
    private let maxEvents: Int
    private let state: Locked<State>

    public init(file: URL, maxBytes: Int = defaultMaxBytes, maxEvents: Int = defaultMaxEvents) {
        url = file
        self.maxBytes = maxBytes
        self.maxEvents = maxEvents
        let data = (try? Data(contentsOf: file)) ?? Data()
        state = Locked(State(events: Self.decode(data), bytes: data.count))
    }

    /// Every event in the file, oldest first.
    public func read() -> [DiagnosticEvent] {
        state.withLock { $0.events }
    }

    public func append(_ event: DiagnosticEvent) {
        state.withLock { state in
            if var last = state.events.last, last.repeats(event) {
                last.count += event.count
                last.timestamp = event.timestamp
                state.events[state.events.count - 1] = last
                rewrite(&state)
                return
            }
            state.events.append(event)
            let line = Self.line(event)
            if state.bytes + line.count > maxBytes || state.events.count > maxEvents {
                state.events.removeFirst(state.events.count / 2)
                rewrite(&state)
            } else if write(line, to: &state) == false {
                rewrite(&state)
            }
        }
    }

    /// Empties the ring.
    public func clear() {
        state.withLock { state in
            state.events = []
            rewrite(&state)
        }
    }

    // MARK: Files

    private func write(_ line: Data, to state: inout State) -> Bool {
        do {
            if !FileManager.default.fileExists(atPath: url.path) { return false }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            // A damaged tail may end without a newline: start a fresh line.
            let end = try handle.seekToEnd()
            if end > 0 {
                try handle.seek(toOffset: end - 1)
                if try handle.read(upToCount: 1) != Data("\n".utf8) {
                    try handle.seekToEnd()
                    try handle.write(contentsOf: Data("\n".utf8))
                    state.bytes += 1
                }
            }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            state.bytes += line.count
            return true
        } catch {
            return false
        }
    }

    private func rewrite(_ state: inout State) {
        var data = Data()
        for event in state.events { data.append(Self.line(event)) }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        state.bytes = data.count
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    static func line(_ event: DiagnosticEvent) -> Data {
        var data = (try? encoder().encode(event)) ?? Data()
        data.append(0x0A)
        return data
    }

    static func decode(_ data: Data) -> [DiagnosticEvent] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(DiagnosticEvent.self, from: Data($0)) }
    }
}
