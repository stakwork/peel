import Foundation

/// Text that came from outside the UI (the Action button's intent) and waits
/// for the account to be open: oldest first, trimmed, empty ones refused, the
/// oldest dropped past `limit`. Memory only, never persisted.
public struct PendingTexts: Equatable, Sendable {
    public static let limit = 5
    public private(set) var texts: [String] = []

    public init() {}

    public var isEmpty: Bool { texts.isEmpty }
    public var count: Int { texts.count }

    /// Returns whether anything was queued.
    @discardableResult
    public mutating func add(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        texts.append(text)
        if texts.count > Self.limit { texts.removeFirst(texts.count - Self.limit) }
        return true
    }

    /// The oldest, removed.
    public mutating func next() -> String? {
        texts.isEmpty ? nil : texts.removeFirst()
    }
}
