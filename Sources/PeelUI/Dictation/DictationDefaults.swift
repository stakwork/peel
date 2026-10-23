import Foundation

/// Every default of system-wide dictation in one place (docs/dictation.md).
/// Change a value here, not where it is used.
public enum DictationDefaults {
    /// The key held to dictate: Right Option.
    public static let hotkey = HotkeyConfig.rightOption
    /// A press shorter than this is a tap, passed through untouched.
    public static let holdThreshold: TimeInterval = 0.2
    /// A recording ends and is submitted at this length.
    public static let maxRecording: TimeInterval = 5 * 60
    /// What a recording is stored as: 16 kHz mono PCM16.
    public static let sampleRate: Double = 16_000
    /// How far the HUD sits above the bottom edge of the screen's visible
    /// area: just clear of the Dock, or of the screen's edge when it is hidden.
    public static let hudBottomInset: CGFloat = 10
    /// How long a message shows in the HUD.
    public static let resultDisplay: TimeInterval = 3
    /// How long "Learned X" shows with its Undo.
    public static let learnedDisplay: TimeInterval = 5
    /// How often the state machine is told the time while a key is held or a recording runs.
    public static let tickInterval: TimeInterval = 0.05

    public static let enabledKey = "dictation.enabled"
    public static let offerDismissedKey = "dictation.offerDismissed"
    public static let askedInputMonitoringKey = "dictation.askedInputMonitoring"
    public static let historyKey = "dictation.history"
    /// Set once hands-free has been used: its tip is not shown again.
    public static let usedHandsFreeKey = "dictation.usedHandsFree"
    public static let handsFreeTipsShownKey = "dictation.handsFreeTipsShown"
    /// How long the key is held before the HUD offers hands-free.
    public static let handsFreeTipAfter: TimeInterval = 2
    /// The tip shows this many times at most, for someone who never wants hands-free.
    public static let handsFreeTipLimit = 5
    /// How long Dictation History keeps a dictation.
    public static let historyKeep: TimeInterval = 30 * 24 * 60 * 60
}

/// What the user chose, kept in `UserDefaults`.
public struct DictationSettings {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Nil until the user chooses.
    public var storedEnabled: Bool? {
        get { defaults.object(forKey: DictationDefaults.enabledKey) as? Bool }
        nonmutating set {
            if let newValue { defaults.set(newValue, forKey: DictationDefaults.enabledKey) }
            else { defaults.removeObject(forKey: DictationDefaults.enabledKey) }
        }
    }

    public var offerDismissed: Bool {
        get { defaults.bool(forKey: DictationDefaults.offerDismissedKey) }
        nonmutating set { defaults.set(newValue, forKey: DictationDefaults.offerDismissedKey) }
    }

    /// Hands-free has been used, so its tip is done.
    public var usedHandsFree: Bool {
        get { defaults.bool(forKey: DictationDefaults.usedHandsFreeKey) }
        nonmutating set { defaults.set(newValue, forKey: DictationDefaults.usedHandsFreeKey) }
    }

    /// How many times the hands-free tip has shown.
    public var handsFreeTipsShown: Int {
        get { defaults.integer(forKey: DictationDefaults.handsFreeTipsShownKey) }
        nonmutating set { defaults.set(newValue, forKey: DictationDefaults.handsFreeTipsShownKey) }
    }

    /// The hands-free tip is still worth showing: hands-free unused, and not yet shown its fill.
    public var wantsHandsFreeTip: Bool {
        !usedHandsFree && handsFreeTipsShown < DictationDefaults.handsFreeTipLimit
    }

    /// Dictation History keeps what is dictated; on until turned off.
    public var historyOn: Bool {
        get { defaults.object(forKey: DictationDefaults.historyKey) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: DictationDefaults.historyKey) }
    }

    /// On once chosen so; before that, on only when every permission it needs is granted.
    public static func isEnabled(stored: Bool?, permissionsGranted: Bool) -> Bool {
        stored ?? permissionsGranted
    }
}
