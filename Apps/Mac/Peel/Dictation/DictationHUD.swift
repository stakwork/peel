import AppKit
import Observation
import SwiftUI
import PeelUI

/// What the HUD shows.
@MainActor @Observable
final class DictationHUDModel {
    enum Mode: Equatable {
        case hidden
        /// Push-to-talk: the waveform only.
        case recording
        /// Hands-free: the waveform between X and tick.
        case locked
        /// A line of text for a moment (where the text went, a problem).
        case message(String)
        /// A word learned from the user's edit, with Undo, for a few seconds.
        case learned(String)

        /// It has something to click: the X and tick, or Undo.
        var takesClicks: Bool {
            switch self {
            case .locked, .learned: true
            case .hidden, .recording, .message: false
            }
        }
    }

    private static let silence = [Float](repeating: 0, count: 8)

    var mode: Mode = .hidden
    /// The last few levels (0…1), oldest first: the bars.
    private(set) var levels = silence
    /// A standing note under the pill, such as secure input being on.
    var note: String? {
        didSet { if note != oldValue { resized() } }
    }
    /// A tip above the pill while recording, until hands-free is known
    /// ("Press Space to keep going hands-free").
    var tip: String? {
        didSet { if tip != oldValue { resized() } }
    }
    var accept: () -> Void = {}
    var cancel: () -> Void = {}
    /// Undo of what `.learned` says was learned.
    var undo: () -> Void = {}
    /// The panel's, to fit and recentre itself when the content changes size.
    @ObservationIgnored var resized: () -> Void = {}

    /// The latest level pushes the waveform along.
    func push(_ level: Float) {
        levels.removeFirst()
        levels.append(level)
    }

    func clearLevels() { levels = Self.silence }
}

/// A small dark pill, like a system overlay: the waveform alone while the
/// key is held; X and tick either side of it when hands-free.
struct DictationHUDView: View {
    let model: DictationHUDModel

    var body: some View {
        VStack(spacing: Theme.Space.xs) {
            if let tip = model.tip, model.mode == .recording {
                Text(tip)
                    .font(Theme.font(12))
                    .foregroundStyle(.white)
                    .padding(.horizontal, Theme.Space.md)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
                    .transition(.opacity)
            }
            pill
            if let note = model.note, model.mode != .hidden {
                Text(note)
                    .font(Theme.font(11))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, Theme.Space.sm)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.8), in: Capsule())
            }
        }
        // Room for the shadow, which reaches 6 pt below the pill.
        .padding(Theme.Space.sm)
        .fixedSize()
    }

    @ViewBuilder private var pill: some View {
        switch model.mode {
        case .hidden:
            EmptyView()
        case .recording:
            DictationWaveform(model: model)
                .padding(.horizontal, Theme.Space.md)
                .frame(height: 24)
                .hudCapsule()
        case .locked:
            HStack(spacing: Theme.Space.sm) {
                HUDButton(.symbol("xmark"), label: "Cancel dictation", filled: false, action: model.cancel)
                DictationWaveform(model: model)
                HUDButton(.symbol("checkmark"), label: "Finish dictation", filled: true, action: model.accept)
            }
            .padding(.horizontal, Theme.Space.xs)
            .frame(height: 28)
            .hudCapsule()
        case .message(let text):
            HugUpTo(maxWidth: 300) {
                Text(text)
                    .font(Theme.font(12))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, 6)
            .hudCapsule()
        case .learned(let text):
            HStack(spacing: Theme.Space.sm) {
                Text(text)
                    .font(Theme.font(12))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                HUDButton(.text("Undo"), label: "Undo", filled: true, action: model.undo)
            }
            .padding(.leading, Theme.Space.md)
            .padding(.trailing, Theme.Space.xs)
            .frame(height: 28)
            .hudCapsule()
        }
    }
}

/// The system-overlay look: always dark, whatever the app's appearance, so
/// its own near-black and white hairline rather than `menuBoxed`'s navy.
private extension View {
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

/// Its child at its own width up to `maxWidth`, then wrapped to that width:
/// a short message hugs its words, a long one goes onto a second line.
private struct HugUpTo: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let ideal = child.sizeThatFits(.unspecified)
        return ideal.width <= maxWidth ? ideal : child.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

/// Thin white bars, the newest at the right, each as tall as its moment was
/// loud. Reads the levels itself, so a new one redraws only the bars.
private struct DictationWaveform: View {
    let model: DictationHUDModel
    private static let minHeight: CGFloat = 3
    private static let maxHeight: CGFloat = 14

    var body: some View {
        let levels = model.levels
        HStack(spacing: 2) {
            ForEach(levels.indices, id: \.self) { index in
                Capsule()
                    .fill(.white)
                    .frame(width: 2, height: Self.minHeight + CGFloat(levels[index]) * (Self.maxHeight - Self.minHeight))
            }
        }
        .frame(height: Self.maxHeight)
        .animation(.easeOut(duration: 0.1), value: levels)
        .accessibilityHidden(true)
    }
}

/// A 20 pt button: round with a symbol (grey for X, white for the tick),
/// or a capsule with a word (Undo).
private struct HUDButton: View {
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

/// The HUD's window: a panel that never becomes key or main, so the app you
/// are typing in keeps the keyboard. It takes the mouse only while locked,
/// for the X and the tick.
@MainActor
final class DictationHUDPanel: NSPanel {
    let model = DictationHUDModel()
    private let host: NSHostingView<DictationHUDView>
    private var hideTask: Task<Void, Never>?
    /// Bumped on every show and hide, so a fade that finishes late does not
    /// take away a HUD shown again meanwhile.
    private var generation = 0

    private static let fadeIn: TimeInterval = 0.15
    private static let fadeOut: TimeInterval = 0.11

    init() {
        host = NSHostingView(rootView: DictationHUDView(model: model))
        super.init(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true
        )
        contentView = host
        isOpaque = false
        backgroundColor = .clear
        // The pill draws its own soft shadow.
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        appearance = NSAppearance(named: .darkAqua)
        ignoresMouseEvents = true
        alphaValue = 0
        model.resized = { [weak self] in
            guard let self, self.isVisible else { return }
            self.place()
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(_ mode: DictationHUDModel.Mode) {
        hideTask?.cancel()
        generation += 1
        // A new recording starts from silence, not the last one's bars.
        if mode == .recording, model.mode != .locked { model.clearLevels() }
        model.mode = mode
        // Mouse only while there is something to click.
        ignoresMouseEvents = !mode.takesClicks
        place()
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeIn
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
        let display: TimeInterval? = switch mode {
        case .message: DictationDefaults.resultDisplay
        case .learned: DictationDefaults.learnedDisplay
        default: nil
        }
        if let display {
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(display))
                guard !Task.isCancelled else { return }
                self?.hide()
            }
        }
    }

    func hide() {
        hideTask?.cancel()
        generation += 1
        let fading = generation
        ignoresMouseEvents = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeOut
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == fading else { return }
                // Only now: the pill keeps its content while it fades.
                self.model.mode = .hidden
                self.orderOut(nil)
            }
        }
    }

    /// Bottom centre of the screen the pointer is on.
    func place() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        // Measured from the model as it is now, not as last drawn.
        host.rootView = DictationHUDView(model: model)
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        setContentSize(size)
        setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.minY + DictationDefaults.hudBottomInset))
    }
}
