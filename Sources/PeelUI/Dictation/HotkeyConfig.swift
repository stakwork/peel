import Foundation

/// The key held to dictate: a modifier on its own (Right Option, Right
/// Command, Right Control, Fn …) or a normal key, by its virtual key code.
public struct HotkeyConfig: Codable, Equatable, Hashable, Sendable {
    public var keyCode: UInt16
    /// What the key is called, as shown in Settings.
    public var label: String

    public init(keyCode: UInt16, label: String) {
        self.keyCode = keyCode
        self.label = label
    }

    public static let rightOption = HotkeyConfig(keyCode: 61, label: "Right Option ⌥")
    public static let fn = HotkeyConfig(keyCode: 63, label: "Fn")

    /// Virtual key codes of the keys that only change the modifier flags, and
    /// the flag bit that says the key is down. The low bits are the
    /// device-dependent ones (IOKit's NX_DEVICE…KEYMASK), which tell left
    /// from right; Fn is `CGEventFlags.maskSecondaryFn`.
    private static let modifiers: [UInt16: (name: String, mask: UInt64)] = [
        54: ("Right Command ⌘", 0x10),
        55: ("Left Command ⌘", 0x08),
        56: ("Left Shift ⇧", 0x02),
        58: ("Left Option ⌥", 0x20),
        59: ("Left Control ⌃", 0x01),
        60: ("Right Shift ⇧", 0x04),
        61: ("Right Option ⌥", 0x40),
        62: ("Right Control ⌃", 0x2000),
        63: ("Fn", 0x80_0000),
    ]

    static let escapeCode: UInt16 = 53
    static let capsLockCode: UInt16 = 57
    static let fnCode: UInt16 = 63
    /// Return, Space and keypad Enter: they steer a recording.
    static let steeringCodes: Set<UInt16> = [36, 49, 76]

    /// The function keys, by number.
    private static let functionKeys: [UInt16: Int] = [
        122: 1, 120: 2, 99: 3, 118: 4, 96: 5, 97: 6, 98: 7, 100: 8, 101: 9, 109: 10,
        103: 11, 111: 12, 105: 13, 107: 14, 113: 15, 106: 16, 64: 17, 79: 18, 80: 19, 90: 20,
    ]

    /// Names of the other keys that have no character of their own.
    private static let named: [UInt16: String] = [
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Escape", 57: "Caps Lock",
        76: "Enter", 114: "Help", 115: "Home", 116: "Page Up", 117: "Forward Delete", 119: "End", 121: "Page Down",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    /// A hotkey for a key code, named from `character` (what the key types)
    /// when it has no name of its own.
    public static func key(code: UInt16, character: String? = nil) -> HotkeyConfig {
        if let modifier = modifiers[code] { return HotkeyConfig(keyCode: code, label: modifier.name) }
        let label = functionKeys[code].map { "F\($0)" } ?? named[code] ?? character?.uppercased().nilIfEmpty ?? "Key \(code)"
        return HotkeyConfig(keyCode: code, label: label)
    }

    /// Whether the key is a modifier, seen in flags-changed events rather
    /// than key-down and key-up.
    public var isModifier: Bool { Self.modifiers[keyCode] != nil }

    /// Whether the key is down according to a flags-changed event's flags
    /// (`CGEventFlags.rawValue`); nil for a key that is not a modifier.
    public func isDown(flags: UInt64) -> Bool? {
        Self.modifiers[keyCode].map { flags & $0.mask != 0 }
    }

    /// A modifier on its own or a function key, keys that type nothing, so holding
    /// one is free to mean dictation. Any other key would type itself in
    /// every app (its key-down is never swallowed), Caps Lock sends no
    /// release, and Space, Return and Escape steer a recording.
    public var canBeHotkey: Bool { isModifier || Self.functionKeys[keyCode] != nil }

    /// Why the key can't be the hotkey, in Settings' words; nil when it can.
    public var refusal: String? {
        if canBeHotkey { return nil }
        let why = if keyCode == Self.capsLockCode { "it sends no release" }
            else if Self.steeringCodes.contains(keyCode) || keyCode == Self.escapeCode { "it steers a recording" }
            else { "it types in every app" }
        return "\(label) can't be the key: \(why)."
    }

    /// What else on the Mac the key does, when that is known; nil when nothing.
    /// `fnKeyUsage` is System Settings › Keyboard › Press 🌐 key
    /// (`com.apple.HIToolbox AppleFnUsageType`; 0 is Do Nothing, nil unset).
    public func conflict(fnKeyUsage: Int?) -> String? {
        if keyCode == Self.fnCode {
            return fnKeyUsage == 0 ? nil
                : "Fn also does what System Settings › Keyboard › Press 🌐 key says: set it to Do Nothing."
        }
        if let number = Self.functionKeys[keyCode] {
            return number > 12 ? nil
                : "On a Mac keyboard F1–F12 are brightness, volume and so on unless Fn is held, "
                + "or System Settings › Keyboard › Use F1, F2, etc. keys as standard function keys is on."
        }
        let name = Self.modifiers[keyCode]?.name ?? ""
        if name.contains("Command") || name.contains("Control") {
            return "Held alone it dictates; with another key it is still a shortcut. "
                + "If macOS Dictation's shortcut uses it (System Settings › Keyboard › Dictation), choose another there."
        }
        if name.contains("Shift") { return "Shift is held for capitals: a slow Shift-letter may start dictating." }
        return nil
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }

    public static func decode(_ data: Data) -> HotkeyConfig? {
        try? JSONDecoder().decode(HotkeyConfig.self, from: data)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
