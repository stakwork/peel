import Foundation

/// How a recording was made.
public enum DictationMode: String, Codable, Equatable, Sendable {
    /// The key was held; releasing it submitted.
    case pushToTalk
    /// Space was pressed with the key held; it ran hands-free until accepted.
    case locked
}

/// The hotkey's life: Idle, Pending (down, not yet held long enough),
/// Recording (held: push-to-talk) and Locked (hands-free). A plain value
/// with the time passed in, so it is tested without a keyboard or a clock.
public struct DictationStateMachine: Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        /// The key went down at `since`.
        case pending(since: TimeInterval)
        /// Push-to-talk; the key went down at `since`.
        case recording(since: TimeInterval)
        /// Hands-free; the key went down at `since`.
        case locked(since: TimeInterval)
    }

    public enum Input: Equatable, Sendable {
        case hotkeyDown(isRepeat: Bool)
        case hotkeyUp
        case spaceDown(isRepeat: Bool)
        case spaceUp
        case escapeDown
        /// Any other key went down.
        case otherKeyDown
        /// The tick on the HUD.
        case accept
        /// The X on the HUD.
        case cancel
        /// Time has passed; nothing else.
        case tick
    }

    public enum Effect: Equatable, Sendable {
        /// Start keeping audio (with the pre-roll in front).
        case beginCapture
        /// Held long enough: show the HUD.
        case showHUD
        /// Hands-free: the HUD gets its X and tick.
        case enterLocked
        /// Stop and hand the audio over.
        case submit(DictationMode)
        /// Stop and throw the audio away.
        case discard
    }

    public struct Output: Equatable, Sendable {
        public var effects: [Effect] = []
        /// The event this input came from must not reach other apps.
        public var swallow = false
    }

    public private(set) var phase: Phase = .idle
    public let holdThreshold: TimeInterval
    public let maxRecording: TimeInterval
    /// The Space that locked is swallowed until it is released, repeats included.
    private var swallowingSpace = false

    public init(
        holdThreshold: TimeInterval = DictationDefaults.holdThreshold,
        maxRecording: TimeInterval = DictationDefaults.maxRecording
    ) {
        self.holdThreshold = holdThreshold
        self.maxRecording = maxRecording
    }

    public var isIdle: Bool { phase == .idle }

    public mutating func handle(_ input: Input, at now: TimeInterval) -> Output {
        var out = Output()
        // A Space that locked keeps being swallowed to its release, whatever happened since.
        switch input {
        case .spaceDown where swallowingSpace:
            out.swallow = true
            return out
        case .spaceUp where swallowingSpace:
            swallowingSpace = false
            out.swallow = true
            return out
        default: break
        }

        switch phase {
        case .idle:
            if case .hotkeyDown(isRepeat: false) = input {
                phase = .pending(since: now)
                out.effects = [.beginCapture]
            }

        case .pending(let since):
            switch input {
            case .hotkeyUp, .otherKeyDown:
                // A tap, or a shortcut that uses the key: nothing happened.
                phase = .idle
                out.effects = [.discard]
            case .escapeDown:
                phase = .idle
                out.effects = [.discard]
            case .spaceDown(let isRepeat):
                guard !isRepeat else { break }
                phase = .locked(since: since)
                swallowingSpace = true
                out.swallow = true
                out.effects = [.showHUD, .enterLocked]
            case .tick:
                if now - since >= holdThreshold {
                    phase = .recording(since: since)
                    out.effects = [.showHUD]
                }
            default: break
            }

        case .recording(let since):
            switch input {
            case .hotkeyUp:
                phase = .idle
                out.effects = [.submit(.pushToTalk)]
            case .spaceDown(let isRepeat):
                guard !isRepeat else { break }
                phase = .locked(since: since)
                swallowingSpace = true
                out.swallow = true
                out.effects = [.enterLocked]
            case .escapeDown:
                phase = .idle
                out.swallow = true
                out.effects = [.discard]
            case .tick:
                if now - since >= maxRecording {
                    phase = .idle
                    out.effects = [.submit(.pushToTalk)]
                }
            default: break
            }

        case .locked(let since):
            switch input {
            case .accept, .hotkeyDown(isRepeat: false):
                phase = .idle
                out.effects = [.submit(.locked)]
            case .cancel:
                phase = .idle
                out.effects = [.discard]
            case .escapeDown:
                phase = .idle
                out.swallow = true
                out.effects = [.discard]
            case .tick:
                if now - since >= maxRecording {
                    phase = .idle
                    out.effects = [.submit(.locked)]
                }
            default: break
            }
        }
        return out
    }
}
