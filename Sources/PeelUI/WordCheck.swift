import PeelCore

/// Three of the twelve words asked back: their places, chosen at random
/// (`Engine.wordsToCheck`), and what was typed for each. Always one answer
/// per place: a box bound to its answer may still read it as its view
/// closes, so a check is replaced by a new one, never emptied.
public struct WordCheck: Sendable {
    public let positions = Engine.wordsToCheck()
    public var answers: [String]

    public init() {
        answers = positions.map { _ in "" }
    }

    /// Every box has something in it.
    public var isFilled: Bool { answers.allSatisfy { !$0.trimmed.isEmpty } }

    /// The answers by place, for `AppModel.confirmWords`.
    public var byPosition: [Int: String] { Dictionary(uniqueKeysWithValues: zip(positions, answers)) }
}
