import Foundation

/// Choosing the dictation key: what each key event means while Settings
/// waits for one. The hotkey tap feeds it (it already sees every key,
/// modifiers on their own included), so nothing depends on Peel's window
/// having the keyboard. A modifier counts once it is let go with nothing
/// else pressed meanwhile, so Fn held for F5 chooses F5, and Command-Tab
/// chooses nothing.
public struct HotkeyRecording: Sendable {
    public enum Outcome: Equatable, Sendable {
        /// Not a press (a release): let it go on.
        case pass
        /// Swallowed with nothing to say: a modifier going down, a repeat.
        case swallow
        /// Escape: stop choosing, the key unchanged.
        case cancel
        case chosen(HotkeyConfig)
        /// Pressed, but it can't be the key (`HotkeyConfig.refusal`).
        case refused(reason: String)
    }

    /// Modifiers seen going down while choosing, still held.
    private var held: Set<UInt16> = []
    /// Something else was pressed while they were held: no modifier counts.
    private var combined = false

    public init() {}

    /// A flags-changed event: a modifier went down or up.
    public mutating func flagsChanged(code: UInt16, flags: UInt64) -> Outcome {
        let key = HotkeyConfig.key(code: code)
        // Caps Lock sends flags-changed too, but is no modifier of ours.
        guard let down = key.isDown(flags: flags) else { return Self.outcome(for: key) }
        if down {
            if !held.isEmpty { combined = true }
            held.insert(code)
            return .swallow
        }
        // Held since before choosing began: not ours to judge.
        guard held.remove(code) != nil else { return .pass }
        let alone = !combined
        if held.isEmpty { combined = false }
        return alone ? .chosen(key) : .swallow
    }

    /// A key-down event; `character` is what the key types, for its name.
    public mutating func keyDown(code: UInt16, character: String?, isRepeat: Bool) -> Outcome {
        if !held.isEmpty { combined = true }
        if isRepeat { return .swallow }
        if code == HotkeyConfig.escapeCode { return .cancel }
        return Self.outcome(for: HotkeyConfig.key(code: code, character: character))
    }

    private static func outcome(for key: HotkeyConfig) -> Outcome {
        key.refusal.map { .refused(reason: $0) } ?? .chosen(key)
    }
}
