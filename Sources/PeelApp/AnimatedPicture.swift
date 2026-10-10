import AppKit
import QuartzCore
import SwiftUI
import PeelCore

/// An animated GIF in a row: an attachment's or Giphy's. It plays while it
/// is on the screen in Peel's front window; with Reduce Motion it shows its
/// first frame and a play button. Core Animation runs the frames, so a
/// playing GIF neither wakes Peel nor redraws the list around it.
struct AnimatedPicture: View {
    let animation: AnimationFrames

    @Environment(\.playsGIFs) private var plays

    var body: some View {
        AnimationLayer(animation: animation, plays: plays)
    }
}

extension EnvironmentValues {
    /// Whether the `AnimatedPicture`s inside play: false under Reduce Motion
    /// until the tile's play button is clicked (`gifPlayback`).
    @Entry var playsGIFs = true
}

extension View {
    /// The tile holding an animated GIF: with Reduce Motion it stays on its
    /// first frame, with a play button over this view (outside any button
    /// the tile is, so the click is the play button's).
    func gifPlayback(animated: Bool) -> some View {
        modifier(GIFPlayback(animated: animated))
    }
}

private struct GIFPlayback: ViewModifier {
    let animated: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var started = false

    func body(content: Content) -> some View {
        content
            .environment(\.playsGIFs, !reduceMotion || started)
            .overlay(alignment: .bottomLeading) {
                if reduceMotion, animated {
                    Button { started.toggle() } label: {
                        Label("GIF", systemImage: started ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(.peel(.outline, size: .sm))
                    .help(started ? "Pause" : "Play")
                    .accessibilityLabel(started ? "Pause GIF" : "Play GIF")
                    .padding(8)
                }
            }
    }
}

private struct AnimationLayer: NSViewRepresentable {
    let animation: AnimationFrames
    let plays: Bool

    func makeNSView(context: Context) -> AnimationView { AnimationView() }

    func updateNSView(_ view: AnimationView, context: Context) {
        view.show(animation, plays: plays)
    }
}

/// The frames as a keyframe animation of its layer's contents, paused
/// (where it is) when the view leaves the screen: out of its window, scrolled
/// out of sight, the window covered, or Peel in the background.
final class AnimationView: NSView {
    private static let key = "frames"

    private var animation: AnimationFrames?
    private var plays = false
    private var paused = true
    private var observers: [any NSObjectProtocol] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.contentsGravity = .resizeAspectFill
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // The layer's contents are the frames; AppKit never draws over them.
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}

    /// Clicks go to the tile under it (the viewer, the row's menu).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ animation: AnimationFrames, plays: Bool) {
        if animation !== self.animation, let layer {
            self.animation = animation
            layer.removeAnimation(forKey: Self.key)
            layer.speed = 1
            layer.timeOffset = 0
            layer.contents = animation.frames.first
            paused = true
            if animation.isAnimated {
                layer.add(Self.keyframes(animation), forKey: Self.key)
                // Held on its first frame until `update` finds it on the screen.
                paused = false
                pause(layer)
            }
        }
        self.plays = plays
        update()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observe()
        update()
    }

    // Into another scroll view, perhaps, within the same window.
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        observe()
        update()
    }

    // Laid out after it joined the window, or moved by the rows around it.
    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        update()
    }

    override func setFrameOrigin(_ origin: NSPoint) {
        super.setFrameOrigin(origin)
        update()
    }

    /// What can take it off the screen without moving it out of its window.
    private func observe() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let window else { return }
        let on = { [unowned self] (name: Notification.Name, object: AnyObject?) in
            observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            })
        }
        on(NSApplication.didBecomeActiveNotification, nil)
        on(NSApplication.didResignActiveNotification, nil)
        on(NSWindow.didChangeOcclusionStateNotification, window)
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            on(NSView.boundsDidChangeNotification, clip)
        }
    }

    private func update() {
        guard let layer, animation?.isAnimated == true else { return }
        let onScreen = window.map { $0.occlusionState.contains(.visible) && NSApp.isActive } == true
            && !visibleRect.isEmpty
        if plays && onScreen { resume(layer) } else { pause(layer) }
    }

    /// Stopped on the frame it shows (Apple's QA1673).
    private func pause(_ layer: CALayer) {
        guard !paused else { return }
        paused = true
        layer.timeOffset = layer.convertTime(CACurrentMediaTime(), from: nil)
        layer.speed = 0
    }

    private func resume(_ layer: CALayer) {
        guard paused else { return }
        paused = false
        let offset = layer.timeOffset
        layer.speed = 1
        layer.timeOffset = 0
        layer.beginTime = 0
        layer.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - offset
    }

    private static func keyframes(_ animation: AnimationFrames) -> CAKeyframeAnimation {
        let total = animation.delays.reduce(0, +)
        var start = 0.0
        var times: [NSNumber] = []
        for delay in animation.delays {
            times.append(NSNumber(value: start / total))
            start += delay
        }
        let keyframes = CAKeyframeAnimation(keyPath: "contents")
        keyframes.values = animation.frames
        // Discrete: one more time than values, the last 1.
        keyframes.keyTimes = times + [1]
        keyframes.calculationMode = .discrete
        keyframes.duration = total
        keyframes.repeatCount = .infinity
        keyframes.isRemovedOnCompletion = false
        return keyframes
    }

    /// The frame on the screen now.
    private var showing: CGImage? {
        guard let contents = layer?.presentation()?.contents ?? layer?.contents,
              CFGetTypeID(contents as CFTypeRef) == CGImage.typeID else { return nil }
        return (contents as! CGImage)
    }

    /// For `cacheDisplay` (a snapshot of the window), which draws rather
    /// than composites: the frame showing, filled as the layer fills.
    override func draw(_ dirtyRect: NSRect) {
        guard let frame = showing ?? animation?.frames.first, let context = NSGraphicsContext.current?.cgContext else { return }
        let scale = max(bounds.width / CGFloat(frame.width), bounds.height / CGFloat(frame.height))
        let size = CGSize(width: CGFloat(frame.width) * scale, height: CGFloat(frame.height) * scale)
        context.clip(to: bounds)
        context.draw(frame, in: CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                                       width: size.width, height: size.height))
    }
}
