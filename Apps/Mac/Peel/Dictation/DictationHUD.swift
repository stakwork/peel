import AppKit
import Observation
import SwiftUI
import PeelUI

/// What the HUD shows.
@MainActor @Observable
final class DictationHUDModel {
    enum Mode: Equatable {
        case hidden
        /// Push-to-talk: a level meter only.
        case recording
        /// Hands-free: the meter, with X and tick.
        case locked
        /// A line of text for a moment (the stub's result, a problem).
        case message(String)
    }

    var mode: Mode = .hidden
    /// 0…1.
    var level: Float = 0
    /// A standing note under the meter, such as secure input being on.
    var note: String?
    var accept: () -> Void = {}
    var cancel: () -> Void = {}
}

struct DictationHUDView: View {
    let model: DictationHUDModel

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 12) {
                switch model.mode {
                case .hidden:
                    EmptyView()
                case .recording:
                    DictationLevelMeter(level: model.level)
                case .locked:
                    Button(action: model.cancel) {
                        Image(systemName: "xmark").frame(width: 28, height: 28)
                    }
                    .accessibilityLabel("Cancel dictation")
                    DictationLevelMeter(level: model.level)
                    Button(action: model.accept) {
                        Image(systemName: "checkmark").frame(width: 28, height: 28)
                    }
                    .accessibilityLabel("Finish dictation")
                case .message(let text):
                    Text(text)
                        .font(Theme.font(13))
                        .foregroundStyle(Theme.text)
                        .lineLimit(2)
                        .frame(maxWidth: 320)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.text)
            if let note = model.note, model.mode != .hidden {
                Text(note).font(Theme.font(11)).foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.black.opacity(0.85), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .padding(8)
        .fixedSize()
    }
}

private struct DictationLevelMeter: View {
    let level: Float
    private static let bars = 12

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<Self.bars, id: \.self) { index in
                let lit = Float(index + 1) / Float(Self.bars) <= level + 0.001
                Capsule()
                    .fill(lit ? Theme.accent : .white.opacity(0.2))
                    .frame(width: 4, height: 6 + CGFloat(index) * 1.5)
            }
        }
        .frame(width: 100, height: 24)
        .animation(.linear(duration: 0.08), value: level)
        .accessibilityHidden(true)
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

    init() {
        host = NSHostingView(rootView: DictationHUDView(model: model))
        super.init(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true
        )
        contentView = host
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        appearance = NSAppearance(named: .darkAqua)
        ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(_ mode: DictationHUDModel.Mode) {
        hideTask?.cancel()
        model.mode = mode
        // Mouse only while there is something to click.
        ignoresMouseEvents = mode != .locked
        place()
        orderFrontRegardless()
        if case .message = mode {
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(DictationDefaults.resultDisplay))
                guard !Task.isCancelled else { return }
                self?.hide()
            }
        }
    }

    func hide() {
        hideTask?.cancel()
        model.mode = .hidden
        ignoresMouseEvents = true
        orderOut(nil)
    }

    /// Bottom centre of the screen the pointer is on.
    func place() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        setContentSize(size)
        setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.minY + DictationDefaults.hudBottomInset))
    }
}
