import Foundation

/// How a recording was made.
public enum DictationMode: String, Codable, Equatable, Sendable {
    /// The key was held; releasing it submitted.
    case pushToTalk
    /// Space was pressed with the key held; it ran hands-free until accepted.
    case locked
}

/// The hotkey's life: Idle, Pending (down, not yet held long enough),
/// Recording (held: push-to-talk) and Locked (hands-free). Space locks only
/// once the key has been held past the threshold, and any other key before
/// a lock is a shortcut, so the hotkey's own shortcuts keep working. A plain value
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
        /// Return or Enter went down.
        case returnDown
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
        /// The key went down: the mic goes on and audio is kept.
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
            case .hotkeyUp, .otherKeyDown, .escapeDown, .returnDown, .spaceDown:
                // A tap, or a shortcut that uses the key (Option-Space and
                // Command-Space among them): nothing happened, and the key
                // goes on to the app.
                phase = .idle
                out.effects = [.discard]
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
            case .otherKeyDown, .returnDown:
                // A shortcut made while the key is held (Option-arrow, Command-Tab).
                phase = .idle
                out.effects = [.discard]
            default:
                out = ending(input, since: since, now: now, mode: .pushToTalk)
            }

        case .locked(let since):
            switch input {
            case .accept, .hotkeyDown(isRepeat: false):
                phase = .idle
                out.effects = [.submit(.locked)]
            case .returnDown:
                phase = .idle
                out.swallow = true
                out.effects = [.submit(.locked)]
            case .cancel:
                phase = .idle
                out.effects = [.discard]
            default:
                out = ending(input, since: since, now: now, mode: .locked)
            }
        }
        return out
    }

    /// What ends a recording either way: Escape throws it away, and the longest
    /// recording hands it over.
    private mutating func ending(_ input: Input, since: TimeInterval, now: TimeInterval, mode: DictationMode) -> Output {
        var out = Output()
        switch input {
        case .escapeDown:
            phase = .idle
            out.swallow = true
            out.effects = [.discard]
        case .tick where now - since >= maxRecording:
            phase = .idle
            out.effects = [.submit(mode)]
        default: break
        }
        return out
    }
}
