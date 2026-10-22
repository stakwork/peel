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
    public static let rightCommand = HotkeyConfig(keyCode: 54, label: "Right Command ⌘")
    public static let rightControl = HotkeyConfig(keyCode: 62, label: "Right Control ⌃")
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

    /// Names of the keys that have no character of their own.
    private static let named: [UInt16: String] = [
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Escape", 57: "Caps Lock",
        96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 103: "F11", 109: "F10", 111: "F12",
        118: "F4", 120: "F2", 122: "F1", 99: "F3", 105: "F13", 107: "F14", 113: "F15",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    /// A hotkey for a key code, named from `character` (what the key types)
    /// when it has no name of its own.
    public static func key(code: UInt16, character: String? = nil) -> HotkeyConfig {
        if let modifier = modifiers[code] { return HotkeyConfig(keyCode: code, label: modifier.name) }
        let label = named[code] ?? character?.uppercased().nilIfEmpty ?? "Key \(code)"
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

    /// Keys that cannot be the hotkey: they are the lock and cancel keys.
    public var isReserved: Bool { keyCode == 49 || keyCode == 53 }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }

    public static func decode(_ data: Data) -> HotkeyConfig? {
        try? JSONDecoder().decode(HotkeyConfig.self, from: data)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
