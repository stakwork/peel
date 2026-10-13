import Foundation

/// Which earlier messages the model sees: the most recent whole turns that
/// fit a token budget. Older ones stay in the conversation, unseen.
///
/// Tokens are estimated, not counted: three UTF-8 bytes to a token, rounded
/// up per block. English runs about four characters a token, so this errs
/// high by a third; code and JSON run nearer three, about right; Chinese or
/// Japanese, a token a character at three bytes each, about right too. A
/// provider's tokenizer would need a network call or a vocabulary file per
/// model; the budget only has to keep the prompt well under the model's
/// window, so the estimate is enough.
public enum ContextWindow {
    static func estimatedTokens(_ text: String) -> Int {
        (text.utf8.count + 2) / 3
    }

    static func estimatedTokens(_ message: ModelMessage) -> Int {
        message.content.reduce(0) { total, block in
            let tokens =
                switch block {
                case .text(let text): estimatedTokens(text)
                case .toolUse(let call): estimatedTokens(call.name) + estimatedTokens(call.input.jsonString)
                case .toolResult(let result): estimatedTokens(result.content)
                case .provider(_, let value): estimatedTokens(value.jsonString)
                }
            return total + tokens
        }
    }

    /// The latest whole turns of `history` whose estimated tokens fit
    /// `budget`. A turn always starts at a message the person typed, so the
    /// window never opens on tool results whose calls were cut off. A single
    /// turn larger than the whole budget is left out and the turns before it
    /// still count; otherwise the window ends at the first turn that does not fit.
    public static func recent(_ history: [ModelMessage], budget: Int) -> [ModelMessage] {
        var kept: [ArraySlice<ModelMessage>] = []
        var used = 0
        var end = history.endIndex
        var turnTokens = 0
        for index in history.indices.reversed() {
            turnTokens += estimatedTokens(history[index])
            guard history[index].startsTurn else { continue }
            defer { end = index; turnTokens = 0 }
            if turnTokens > budget { continue }
            guard used + turnTokens <= budget else { break }
            used += turnTokens
            kept.append(history[index..<end])
        }
        return kept.reversed().flatMap { $0 }
    }
}
