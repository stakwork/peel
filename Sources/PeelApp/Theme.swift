import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Sphinx's colours and type; see docs/design/README.md. Every colour follows the
/// system's light or dark appearance.
enum Theme {
    static let sidebar = Color(light: 0xF2F3F5, dark: 0x1A242E)
    static let background = Color(light: 0xFFFFFF, dark: 0x151E27)
    static let panel = Color(light: 0xF7F8F9, dark: 0x1A232D)
    static let input = Color(light: 0xF2F3F5, dark: 0x13181D)
    /// Off-white rather than white on navy: easier on long reads.
    static let text = Color(light: 0x292C33, dark: 0xE3E7EC)
    /// A sender's name over their run of messages.
    static let name = Color(light: 0x3A4048, dark: 0xC3CCD6)
    static let secondaryText = Color(light: 0x646C73, dark: 0x97A3B4)
    static let divider = Color(light: 0xDCE0E3, dark: 0x2C353D)
    /// Menus, raised a step above the panels they open over.
    static let menu = Color(light: 0xFFFFFF, dark: 0x202B36)
    /// A raised fill on the conversation: quotes, file cards, the reply bar.
    static let quote = Color(light: 0xF2F3F5, dark: 0x1E2934)
    static let hover = Color(light: 0xE8EAED, dark: 0x222E3A)
    static let selection = Color(light: 0xDDE6FF, dark: 0x2D4170)
    static let selectionText = Color(light: 0x1E3D99, dark: 0xFFFFFF)
    static let accent = Color(light: 0x618AFF, dark: 0x618AFF)
    static let button = Color(light: 0x3F68E0, dark: 0x618AFF)
    static let buttonText = Color(light: 0xFFFFFF, dark: 0x0E1620)
    /// PrimaryRed: only for actions that destroy something.
    static let destructive = Color(light: 0xED7474, dark: 0xED7474)
    /// Links in messages.
    static let link = Color(light: 0x3F68E0, dark: 0x8FB0FF)
    /// An @mention: a soft chip.
    static let mentionFill = Color(light: 0xDDE6FF, dark: 0x2A3A5E)
    static let mentionText = Color(light: 0x1E3D99, dark: 0xB4C8FF)
    /// PrimaryGreen: connected, and a message the server confirmed.
    static let confirmed = Color(light: 0x49C998, dark: 0x49C998)
    /// SphinxOrange: not connected. Also the boost bolt, from phase 4.
    static let attention = Color(light: 0xFFBC58, dark: 0xFFBC58)

    /// The system font (SF Pro), Tom's choice for readability on 2026-10-07.
    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        Font.system(size: size, weight: weight)
    }
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        #if os(macOS)
        self.init(nsColor: NSColor(name: nil) { appearance in
            let (r, g, b) = Self.channels(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
            return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        })
        #else
        self.init(uiColor: UIColor { traits in
            let (r, g, b) = Self.channels(traits.userInterfaceStyle == .dark ? dark : light)
            return UIColor(red: r, green: g, blue: b, alpha: 1)
        })
        #endif
    }

    private static func channels(_ rgb: UInt32) -> (CGFloat, CGFloat, CGFloat) {
        (CGFloat((rgb >> 16) & 0xFF) / 255, CGFloat((rgb >> 8) & 0xFF) / 255, CGFloat(rgb & 0xFF) / 255)
    }
}
