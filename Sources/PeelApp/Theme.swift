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
    static let text = Color(light: 0x292C33, dark: 0xFFFFFF)
    static let secondaryText = Color(light: 0x646C73, dark: 0x97A3B4)
    static let divider = Color(light: 0xDCE0E3, dark: 0x2C353D)
    static let hover = Color(light: 0xE8EAED, dark: 0x222E3A)
    static let selection = Color(light: 0xDDE6FF, dark: 0x2D4170)
    static let selectionText = Color(light: 0x1E3D99, dark: 0xFFFFFF)
    static let accent = Color(light: 0x618AFF, dark: 0x618AFF)
    static let button = Color(light: 0x3F68E0, dark: 0x618AFF)
    static let buttonText = Color(light: 0xFFFFFF, dark: 0x0E1620)
    /// PrimaryRed: only for actions that destroy something.
    static let destructive = Color(light: 0xED7474, dark: 0xED7474)
    static let sentBubble = Color(light: 0xDDEDFD, dark: 0x3E6189)
    static let receivedBubble = Color(light: 0xF2F3F5, dark: 0x222E3A)
    static let sentText = Color(light: 0x1E1F25, dark: 0xFFFFFF)
    /// PrimaryGreen: connected, and a message the server confirmed.
    static let confirmed = Color(light: 0x49C998, dark: 0x49C998)
    /// SphinxOrange: not connected. Also the boost bolt, from phase 4.
    static let attention = Color(light: 0xFFBC58, dark: 0xFFBC58)

    /// Roboto when the app bundle carries it, otherwise the system font.
    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let name = switch weight {
        case .bold, .semibold, .heavy, .black: "Roboto-Bold"
        case .medium: "Roboto-Medium"
        default: "Roboto-Regular"
        }
        return Font.custom(name, size: size)
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
