import Foundation

/// One server-sent event: its `event:` name, if any, and its `data:` lines
/// joined with newlines.
struct SSEEvent: Sendable, Hashable {
    var event: String?
    var data: String
}

/// Reads a `text/event-stream` line by line, as the HTML spec describes it:
/// a blank line ends an event, `:` lines are comments (OpenRouter's keep-alive),
/// `id:` and `retry:` are ignored.
struct SSEParser: Sendable {
    private var event: String?
    private var data: [String] = []

    /// Takes one line without its line ending; returns the event it completes.
    mutating func feed(_ line: Substring) -> SSEEvent? {
        if line.isEmpty { return flush() }
        if line.hasPrefix(":") { return nil }
        let colon = line.firstIndex(of: ":")
        var value = colon.map { line[line.index(after: $0)...] } ?? ""
        if value.first == " " { value = value.dropFirst() }
        switch colon.map({ line[..<$0] }) ?? line {
        case "event": event = String(value)
        case "data": data.append(String(value))
        default: break
        }
        return nil
    }

    /// The event left when the stream ends without a final blank line.
    mutating func flush() -> SSEEvent? {
        defer { event = nil; data = [] }
        guard !data.isEmpty else { return nil }
        return SSEEvent(event: event, data: data.joined(separator: "\n"))
    }
}

/// Splits bytes into lines at `\n`, `\r\n` or `\r`, keeping empty lines (which
/// `AsyncBytes.lines` drops, and which end server-sent events).
struct LineSplitter: Sendable {
    /// Longest line kept; past it the stream is treated as malformed.
    static let maxLineBytes = 1 << 20

    private var buffer: [UInt8] = []
    private var lastWasCR = false

    /// The line `byte` completes, if any.
    mutating func feed(_ byte: UInt8) throws -> String? {
        defer { lastWasCR = byte == 0x0D }
        switch byte {
        case 0x0A where lastWasCR:
            return nil
        case 0x0A, 0x0D:
            defer { buffer.removeAll(keepingCapacity: true) }
            return String(decoding: buffer, as: UTF8.self)
        default:
            guard buffer.count < Self.maxLineBytes else { throw ModelError.malformed("a line over 1 MB") }
            buffer.append(byte)
            return nil
        }
    }

    /// The last line, when the stream ends without a line ending.
    mutating func flush() -> String? {
        defer { buffer = [] }
        return buffer.isEmpty ? nil : String(decoding: buffer, as: UTF8.self)
    }
}
