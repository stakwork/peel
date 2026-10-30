import AppKit
import SwiftUI
import PeelUI

/// A small overlay over every app, like a system HUD: dictation's pill, a
/// screen recording's bar and camera bubble. Never key or main, so the app
/// you are in keeps the keyboard; on every space, over full-screen apps.
@MainActor
class HUDPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        // What it shows draws its own soft shadow.
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The system-overlay look: always dark, whatever the app's appearance, so
/// its own near-black and white hairline rather than `menuBoxed`'s navy.
extension View {
    func hudCapsule() -> some View {
        // The shadow is on the shape alone: the bars move without re-blurring it.
        background {
            Capsule()
                .fill(Color(white: 0.06).opacity(0.94))
                .shadow(color: Theme.menuShadow, radius: 1, y: 0.5)
                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
        }
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
    }
}

/// A 20 pt button: round with a symbol (grey for X, white for the tick),
/// or a capsule with a word (Undo).
struct HUDButton: View {
    enum Content {
        case symbol(String)
        case text(String)
    }

    let content: Content
    let label: String
    let filled: Bool
    let action: () -> Void

    init(_ content: Content, label: String, filled: Bool, action: @escaping () -> Void) {
        self.content = content
        self.label = label
        self.filled = filled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            face
                .foregroundStyle(filled ? Color.black : .white)
                .frame(height: 20)
                .background(filled ? Color.white : Color.white.opacity(0.22), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(HUDPress())
        .accessibilityLabel(label)
    }

    @ViewBuilder private var face: some View {
        switch content {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 9, weight: .bold))
                .frame(width: 20)
        case .text(let text):
            Text(text)
                .font(Theme.font(12, .semibold))
                .padding(.horizontal, Theme.Space.sm)
        }
    }
}

private struct HUDPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.94 : 1)
    }
}

