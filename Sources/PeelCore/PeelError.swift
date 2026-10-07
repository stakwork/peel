/// A failure with a message meant for the person using Peel.
public struct PeelError: Error, CustomStringConvertible, Sendable {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }
}
