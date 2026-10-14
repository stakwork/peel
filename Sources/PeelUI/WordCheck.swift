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

/// The twelve boxes the words are typed or pasted into, on the Mac and the
/// iPhone alike.
public enum WordBoxes {
    /// Puts each word of `text` in its own box, starting at `index`. Returns
    /// the words when there was more than one (a paste, spread out); nil
    /// when there was one or none, which the box at `index` takes.
    public static func fill(_ boxes: inout [String], from index: Int, with text: String) -> [String]? {
        let parts = Engine.words(in: text)
        guard parts.count > 1 else {
            boxes[index] = parts.first ?? ""
            return nil
        }
        for (offset, part) in parts.prefix(boxes.count - index).enumerated() {
            boxes[index + offset] = part
        }
        return parts
    }
}
