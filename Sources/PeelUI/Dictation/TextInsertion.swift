import Foundation

/// What Accessibility says about the focused element, read once when the
/// key goes down and again when the text is ready. Plain values, so how
/// to insert is decided (and tested) without an app to type into.
public struct FocusFacts: Equatable, Sendable {
    /// The frontmost app.
    public let pid: Int32
    public let bundleID: String?
    /// The focused element itself, to tell another field in the same app;
    /// nil when Accessibility shows none.
    public let element: AnyHashableSendable?
    /// The focused element's role; nil when the app shows Accessibility no
    /// focused element (many Electron apps), so nothing is known about it.
    public let role: String?
    public let subrole: String?
    /// The element, or one it sits in, says it is editable (web content).
    public let isEditable: Bool
    /// Some app has secure keyboard entry on (a password prompt, a terminal's
    /// Secure Keyboard Entry), wherever the focus is.
    public let secureInput: Bool

    public init(
        pid: Int32, bundleID: String? = nil, element: AnyHashableSendable? = nil, role: String? = nil,
        subrole: String? = nil, isEditable: Bool = false, secureInput: Bool = false
    ) {
        self.pid = pid
        self.bundleID = bundleID
        self.element = element
        self.role = role
        self.subrole = subrole
        self.isEditable = isEditable
        self.secureInput = secureInput
    }

    /// A password field, or secure entry: nothing is recorded, typed or copied.
    public var isSecure: Bool { secureInput || subrole == "AXSecureTextField" }

    private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    /// Controls that never take typing. Anything else that is not plainly a
    /// text field (a group, a web area: how Electron apps and web editors
    /// often look) gets the paste rather than the clipboard.
    private static let nonTextRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXMenuItem", "AXMenuBarItem",
        "AXList", "AXTable", "AXOutline", "AXRow", "AXCell", "AXImage", "AXSlider", "AXTabGroup", "AXToolbar", "AXLink",
    ]

    /// A field that takes text for sure: its value can be checked after.
    public var isTextField: Bool { role.map { isEditable || Self.textRoles.contains($0) } ?? false }

    /// The focus is a control that takes no text.
    public var takesNoText: Bool { role.map { !isEditable && Self.nonTextRoles.contains($0) } ?? false }
}

/// `AnyHashable` that crosses actors: the focused element is compared, never used.
public struct AnyHashableSendable: Hashable, @unchecked Sendable {
    public let value: AnyHashable
    public init(_ value: AnyHashable) { self.value = value }
}

/// How dictated text reaches the app, decided from what was focused when
/// the key went down and what is focused now.
public enum TextInsertionPlan: Equatable, Sendable {
    /// Set the element's selected text through Accessibility (a short list of
    /// native apps where that is known to work, undo included), checked by
    /// its length; pasting if the set itself is refused.
    case accessibility
    /// Paste with the clipboard saved and put back: works nearly everywhere.
    case paste
    /// Leave the text on the clipboard and say so: there is nowhere to type it.
    case copy(CopyReason)
    /// A password field or secure entry: nothing is typed, nothing is copied.
    case blocked

    public enum CopyReason: Equatable, Sendable {
        /// Nothing that takes text has focus.
        case noField
        /// Another app, window or field took the focus while the text was being made.
        case focusMoved
    }

    /// Native apps whose fields take Accessibility's selected text faithfully.
    public static let accessibilityApps: Set<String> = [
        "com.apple.Notes", "com.apple.TextEdit", "com.apple.mail", "com.apple.MobileSMS",
    ]

    public static func plan(from start: FocusFacts, to now: FocusFacts) -> TextInsertionPlan {
        if start.isSecure || now.isSecure { return .blocked }
        if now.pid != start.pid { return .copy(.focusMoved) }
        if let before = start.element, let after = now.element, before != after { return .copy(.focusMoved) }
        if now.takesNoText { return .copy(.noField) }
        if now.isTextField, let id = now.bundleID, accessibilityApps.contains(id) { return .accessibility }
        return .paste
    }
}
